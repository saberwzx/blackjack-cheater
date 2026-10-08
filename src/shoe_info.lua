-- ============================================================
-- ShoeInfo — 牌靴情报（纯函数模块，无头可测）
--
-- 信息层 v1（BlackJacky「赌信息」轴心的计算核心）:
--   · rankComposition — 抽牌堆成分计数（标准点数分桶 + 不定值牌单列）
--   · bustOdds        — 下一张爆率（按已知值牌多重集精确枚举）
--   · dealerBustOdds  — 庄家爆率（按庄家要牌规则精确递归 + 记忆化）
--   · visibleSlots    — 顺序带槽位显隐（peek 数 → 前 N 张明牌）
--
-- 确定性: 全部枚举按固定顺序（RANK_ORDER → 自定义值字典序）累加，
--          不消耗 love.math 随机数 —— 同种子两次运行浮点结果逐位一致。
-- 性能: dealerBustOdds 由 UI 层缓存（按 牌靴洗牌计数/张数/手牌 变更戳），
--          不在每帧重算；模块本身无副作用。
-- ============================================================

local ShoeInfo = {}
local Blackjack = require("src.blackjack")

-- 标准点数的展示/枚举顺序（A 2 3 .. 10 J Q K）
ShoeInfo.RANK_ORDER = { 'A', '2', '3', '4', '5', '6', '7', '8', '9', '10', 'J', 'Q', 'K' }

local STANDARD_KEYS = {}
for _, k in ipairs(ShoeInfo.RANK_ORDER) do STANDARD_KEYS[k] = true end

-- 单张牌的"值桶"：返回桶键（字符串）+ 数值；不定值牌（骰子/RPS 等）返回 nil
--   · 标准牌按 rank 分桶（J/Q/K 并入 '10' 桶，与 21 点同值）
--   · 特殊牌里 value 为数字的按 value 折算（value 11 → 'A' 桶）
local function valueBucket(c)
    if c.value ~= nil then
        local v = tonumber(c.value)
        if not v then return nil end
        if v == 11 then return 'A', 11 end
        return tostring(v), v
    end
    local r = c.rank
    if r == 'A' then return 'A', 11 end
    if r == 'J' or r == 'Q' or r == 'K' or r == 10 then return '10', 10 end
    if type(r) == 'number' and r >= 2 and r <= 9 then return tostring(r), r end
    return nil
end

-- 生成枚举桶数组（固定顺序：标准 RANK_ORDER → 自定义值字典序）
-- 每桶 { key = 桶键, n = 张数, v = 点数值 }
local function buildBuckets(deck)
    local byRank = ShoeInfo.rankComposition(deck).byRank
    local buckets = {}
    for _, rk in ipairs(ShoeInfo.RANK_ORDER) do
        local n = byRank[rk] or 0
        if n > 0 then
            local v = (rk == 'A') and 11 or (rk == '10') and 10 or tonumber(rk)
            buckets[#buckets + 1] = { key = rk, n = n, v = v }
        end
    end
    local customs = {}
    for k, n in pairs(byRank) do
        if not STANDARD_KEYS[k] then customs[#customs + 1] = { key = k, n = n } end
    end
    table.sort(customs, function(a, b) return a.key < b.key end)
    for _, b in ipairs(customs) do
        b.v = tonumber(b.key)
        buckets[#buckets + 1] = b
    end
    return buckets
end

-- 桶键 → 探测牌（复用 blackjack.calculateHand 的原生点数逻辑）
local function probeCard(key)
    if key == 'A' then return { rank = 'A', suit = '♠', faceUp = true } end
    if key == '10' then return { rank = 10, suit = '♠', faceUp = true } end
    local num = tonumber(key)
    if num and num >= 2 and num <= 9 then
        return { rank = num, suit = '♠', faceUp = true }
    end
    -- 自定义值桶（小数/负数等）：value 显式给出，rank 只是摆设
    return { rank = 10, value = tonumber(key), suit = '♠', faceUp = true }
end

-- ============================================================
-- 成分计数：byRank（桶键 → 张数）+ unknown（不定值牌数）+ standard（标准桶张数）
-- ============================================================
function ShoeInfo.rankComposition(deck)
    local byRank, unknown, total, standard = {}, 0, 0, 0
    for _, c in ipairs(deck.cards) do
        total = total + 1
        local key = valueBucket(c)
        if key then
            byRank[key] = (byRank[key] or 0) + 1
            if STANDARD_KEYS[key] then standard = standard + 1 end
        else
            unknown = unknown + 1
        end
    end
    return { byRank = byRank, unknown = unknown, total = total, standard = standard }
end

-- ============================================================
-- 下一张爆率：P(再抽一张 → 手牌 > 21)
-- 只统计已知值牌；手牌为空 / 无已知值牌时返回 nil（UI 显示 "--"）
-- ============================================================
function ShoeInfo.bustOdds(hand, deck)
    if not hand or #hand == 0 then return nil end
    local buckets = buildBuckets(deck)
    local known = 0
    for _, b in ipairs(buckets) do known = known + b.n end
    if known == 0 then return nil end

    local bust = 0
    local trial = {}
    for i, c in ipairs(hand) do trial[i] = c end
    for _, b in ipairs(buckets) do
        trial[#hand + 1] = probeCard(b.key)
        if Blackjack.calculateHand(trial) > 21 then bust = bust + b.n end
        trial[#hand + 1] = nil
    end
    return bust / known
end

-- ============================================================
-- 庄家爆率：P(庄家按规则要牌最终爆)
-- 要牌判定直接调 Blackjack.dealerShouldHit（与实战庄家 AI 同源）；
-- playerTotal 传 nil（盲打规则）—— 信息模式里庄家是规则机器。
--
-- 性能护栏（v2，修复"打开情报面板未响应/崩溃"）：
--   根因：小数/负值特殊牌（酒吧牌堆、商店购入的特殊牌组）会让庄家
--   "永远到不了停牌线"，枚举状态空间指数爆炸 → 卡死 + memo 吃爆内存。
--   护栏：只枚举标准点数桶（A/2..9/10）；自定义值牌不参与（UI 提示覆盖缺口）；
--   递归深度 ≤10、节点预算 150k，超限放弃并返回 nil（UI 显示 "--"）。
-- ============================================================
function ShoeInfo.dealerBustOdds(dealerHand, deck, difficulty)
    difficulty = difficulty or 1
    if not dealerHand or #dealerHand == 0 then return nil end
    local comp = ShoeInfo.rankComposition(deck)
    local buckets = {}
    local known = 0
    for _, rk in ipairs(ShoeInfo.RANK_ORDER) do
        local n = comp.byRank[rk] or 0
        if n > 0 then
            local v = (rk == 'A') and 11 or (rk == '10') and 10 or tonumber(rk)
            buckets[#buckets + 1] = { key = rk, n = n, v = v }
            known = known + n
        end
    end
    if known == 0 then return nil end

    local DEPTH_MAX = 10
    local aborted = false
    local NODE_BUDGET = 150000

    local memo = {}
    local hand = {}
    for i, c in ipairs(dealerHand) do hand[i] = c end   -- 庄家初始点数必须计入

    -- 手牌值签名（多重集，编码软硬）——同签名即同点数/软硬/要牌决策
    local function handSig()
        local sigs = {}
        for _, c in ipairs(hand) do
            local k = valueBucket(c)
            sigs[#sigs + 1] = k or "?"
        end
        table.sort(sigs)
        return table.concat(sigs, "|")
    end
    local baseSig = handSig()

    local function keyOf()
        local parts = { baseSig }
        for _, b in ipairs(buckets) do parts[#parts + 1] = tostring(b.n) end
        for _, c in ipairs(hand) do
            local k = valueBucket(c)
            parts[#parts + 1] = k or "?"
        end
        table.sort(parts)
        return table.concat(parts, ",")
    end

    local function rec(depth)
        if aborted then return 0.0 end
        NODE_BUDGET = NODE_BUDGET - 1
        if NODE_BUDGET <= 0 then aborted = true return 0.0 end
        if depth > DEPTH_MAX then return 0.0 end
        local total = Blackjack.calculateHand(hand)
        if total > 21 then return 1.0 end
        if not Blackjack.dealerShouldHit(hand, difficulty, nil, nil) then return 0.0 end

        local k = keyOf()
        local cached = memo[k]
        if cached then return cached end

        local p = 0.0
        for bi = 1, #buckets do
            local b = buckets[bi]
            if b.n > 0 then
                local w = b.n / known
                b.n = b.n - 1
                hand[#hand + 1] = probeCard(b.key)
                p = p + w * rec(depth + 1)
                hand[#hand] = nil
                b.n = b.n + 1
            end
        end
        memo[k] = p
        return p
    end

    local bust = rec(0)
    if aborted then return nil end
    return bust
end

-- ============================================================
-- 顺序带槽位：从 offset+1 张开始的 k 个真实牌引用 + 显隐标记
-- revealed = 绝对位置 ≤ peekN（窥视遗物点亮数）或命中揭示位置表 revealMap，
--            或这张牌本身已被翻开（显影墨水标记时翻开 → card.faceUp）
-- （揭示遗物 _revealedPos：位置 → true，本小局有效）；其余为牌背 + "?"
-- offset 支持顺序带向后拉（情报面板滚轮/方向键）
-- ============================================================
function ShoeInfo.visibleSlots(deck, k, peekN, offset, revealMap)
    offset = offset or 0
    local out = {}
    for i = 1 + offset, math.min(k + offset, #deck.cards) do
        local c = deck.cards[i]
        local revealed = (i <= (peekN or 0)) or (revealMap and revealMap[i] == true)
                         or (c ~= nil and c.faceUp == true) or false
        out[#out + 1] = { index = i, card = c, revealed = revealed }
    end
    return out
end

return ShoeInfo
