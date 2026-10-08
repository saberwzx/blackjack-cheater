-- ============================================================
-- Blackjack — 21 点核心规则模块
-- 重构自原 main.lua 中的 calculateHand, dealerAI, endGame 等
-- ============================================================

local Blackjack = {}

-- ============================================================
-- 点数计算（支持特殊牌组：小数 / 负数 / 倍率牌）
-- ============================================================

-- 获取单张牌的 Blackjack 点数（A 默认 11）
local function cardValue11(card)
    if card.value ~= nil then return card.value end  -- 特殊牌直接用 value
    local v = card.rank
    if v == "J" or v == "Q" or v == "K" then return 10 end
    if v == "A" then return 11 end
    return tonumber(v) or 0
end

-- 获取单张牌的 Blackjack 点数（A 当 1）
local function cardValue1(card)
    if card.value ~= nil then return card.value end
    local v = card.rank
    if v == "J" or v == "Q" or v == "K" then return 10 end
    if v == "A" then return 1 end
    return tonumber(v) or 0
end

-- 公开：单张牌点数（A 当 1，保守值，用于 Saber 去掉最低牌等场景）
function Blackjack.cardValue(card)
    return cardValue1(card)
end

-- ============================================================
-- 骰子牌（六面 / 二十面）：面数与「结算前统一掷骰」
--
-- 锁定项（不得放宽）：
--   * 未掷骰的骰子牌 value 必须为 nil —— 只能通过 cardValue11 / cardValue1 的
--     「card.value ~= nil」分支被读到，因此回合中天然不贡献任何点数。
--   * 掷骰只在结算入口发生一次；同一小局内重复调用本函数不得改变已有结果（冻结）。
--   * 掷骰范围闭区间整数：六面 [1,6] / 二十面 [1,20]；随机源只用 love.math.random。
-- 冻结口径（回合令牌）：
--   骰子牌上记录本小局的令牌 dice_token；令牌与当前小局一致 = 已掷且冻结。
--   新小局令牌变化 -> 自动重掷，无需枚举牌堆 / 弃牌堆 / 手牌 / 模板去逐个清零。
-- 禁区：本函数绝不改写 calculateHand / calculateHandRaw 的签名与语义；
--       绝不在绘制、读取点数的热路径上调用（只由结算入口调用）。
-- ============================================================

-- 骰子面数：非骰子牌返回 nil（唯一判定口径，渲染层复用同一函数避免两处硬编码）
function Blackjack.diceSides(card)
    if type(card) ~= "table" then return nil end
    if card.kind == "dice6"  then return 6 end
    if card.kind == "dice20" then return 20 end
    return nil
end

-- 结算前统一掷骰：把一手牌里所有「令牌不是本小局」的骰子牌各掷一次并写入 value
-- 返回本次实际掷出的张数（0 = 全部已冻结 / 没有骰子牌）
function Blackjack.rollDice(hand, token)
    if type(hand) ~= "table" then return 0 end
    token = token or ""            -- 令牌缺失时退化为固定空串：仍然只掷一次并冻结
    local rolled = 0
    for _, card in ipairs(hand) do
        local sides = Blackjack.diceSides(card)
        if sides and card.dice_token ~= token then
            card.dice_token = token
            card.value      = love.math.random(1, sides)   -- 锁定项：value 只能来自掷骰结果
            rolled = rolled + 1
        end
    end
    return rolled
end

-- 计算一手牌的总点数（含 A 的动态调整 + 负数/小数支持）
function Blackjack.calculateHand(hand)
    if not hand then return 0 end
    local total = 0
    local aceCount = 0

    for _, card in ipairs(hand) do
        local isStandardAce = (card.value == nil and card.rank == "A")
        if isStandardAce then
            total = total + 11
            aceCount = aceCount + 1
        else
            total = total + cardValue11(card)
        end
    end

    -- A 动态降级：爆了就把 A 从 11 降到 1（每次 -10）
    -- 有负数牌时可能把 total 拉回来，不爆就不用降
    while total > 21 and aceCount > 0 do
        total = total - 10
        aceCount = aceCount - 1
    end

    return total
end

-- 计算一手牌的点数（不调整 A，用于判断软 17 + 原始值显示）
function Blackjack.calculateHandRaw(hand)
    if not hand then return 0 end
    local total = 0
    for _, card in ipairs(hand) do
        total = total + cardValue11(card)
    end
    return total
end

-- 收集手牌里所有倍率牌的附加倍率（用于结算）
function Blackjack.collectMultBonuses(hand)
    if not hand then return 0 end
    local total = 0
    for _, card in ipairs(hand) do
        if card.mult_bonus and card.mult_bonus > 0 then
            total = total + card.mult_bonus
        end
    end
    return total
end

-- 判断一手牌是否是 Blackjack（自然 21）
function Blackjack.isBlackjack(hand)
    if #hand ~= 2 then return false end
    local total = Blackjack.calculateHand(hand)
    if total ~= 21 then return false end
    -- 必须包含一张 A 和一张 10/面牌
    local hasAce = false
    local hasTen = false
    for _, card in ipairs(hand) do
        if card.rank == 'A' then hasAce = true end
        if card.rank == 10 or card.rank == 'J' or card.rank == 'Q' or card.rank == 'K' then
            hasTen = true
        end
    end
    return hasAce and hasTen
end

-- 判断是否爆牌
function Blackjack.isBust(hand)
    return Blackjack.calculateHand(hand) > 21
end

-- ============================================================
-- 牌型识别（用于遗物条件触发的手牌型判定）
-- ============================================================

function Blackjack.hasRank(hand, rank)
    for _, card in ipairs(hand) do
        if card.rank == rank then return true end
    end
    return false
end

function Blackjack.countRank(hand, rank)
    local count = 0
    for _, card in ipairs(hand) do
        if card.rank == rank then count = count + 1 end
    end
    return count
end

function Blackjack.countSuit(hand, suit)
    local count = 0
    for _, card in ipairs(hand) do
        if card.suit == suit then count = count + 1 end
    end
    return count
end

-- 手牌中有多少张 A
function Blackjack.countAces(hand)
    return Blackjack.countRank(hand, 'A')
end

-- 是否同花色（至少指定张数）
function Blackjack.isFlush(hand, minCount)
    minCount = minCount or 5
    if #hand < minCount then return false end
    local suit = hand[1].suit
    local count = 0
    for _, card in ipairs(hand) do
        if card.suit == suit then count = count + 1 end
    end
    return count >= minCount
end

-- 是否对子（两张相同点数的牌）
function Blackjack.hasPair(hand)
    for i = 1, #hand do
        for j = i + 1, #hand do
            local v1 = hand[i].rank
            local v2 = hand[j].rank
            -- A 特殊处理
            if v1 == v2 or
               (v1 == 10 and (v2 == 'J' or v2 == 'Q' or v2 == 'K' or v2 == 10)) or
               (v2 == 10 and (v1 == 'J' or v1 == 'Q' or v1 == 'K' or v1 == 10)) then
                return true
            end
        end
    end
    return false
end

-- 手牌最大连续点数（用于顺子判断）
function Blackjack.hasStraight(hand)
    if #hand < 3 then return false end
    local nums = {}
    for _, card in ipairs(hand) do
        local v = card.rank
        if v == 'A' then table.insert(nums, 1) table.insert(nums, 14)
        elseif v == 'J' then table.insert(nums, 11)
        elseif v == 'Q' then table.insert(nums, 12)
        elseif v == 'K' then table.insert(nums, 13)
        else table.insert(nums, tonumber(v))
        end
    end
    table.sort(nums)
    -- 检查连续 3 个
    for i = 1, #nums - 2 do
        if nums[i+1] == nums[i] + 1 and nums[i+2] == nums[i] + 2 then
            return true
        end
    end
    return false
end

-- ============================================================
-- 庄家 AI
-- 返回 true 表示要继续要牌
-- difficulty: 1=正常(经典), 2=激进, 3=作弊(看玩家牌)
-- playerTotal: 玩家明牌点数（阶段 3 庄家能看到）
-- ============================================================

function Blackjack.dealerShouldHit(dealerHand, difficulty, playerTotal, dealerClass)
    difficulty = difficulty or 1
    local total = Blackjack.calculateHand(dealerHand)
    local isBerserker = dealerClass and dealerClass.id == "berserker"
    local isArcher    = dealerClass and dealerClass.id == "archer"
    local isAssassin  = dealerClass and dealerClass.id == "assassin"

    -- 阶段 1: 胆小庄家（硬 15 就停，软 16 也停 — 新手友好）
    if difficulty == 1 then
        -- Archer 庄家: 即使阶段 1 也能看到玩家点数（像阶段 3 AI）
        if isArcher and playerTotal then
            if playerTotal >= 18 and total >= 15 then return false end
            if total < playerTotal and total < 21 then return true end
            return total < 15
        end
        -- Berserker 庄家: 爆牌放宽到 25，AI 敢到 25
        local stopAt = isBerserker and 25 or 15
        if total < stopAt then return true end
        -- 软 16/17 也停（胆小到底 — 只有 A+5 这种不自然的软值才会继续）
        if total == 16 or total == 17 then
            for _, card in ipairs(dealerHand) do
                if card.rank == 'A' then
                    local rawTotal = Blackjack.calculateHandRaw(dealerHand)
                    if rawTotal <= 26 then return true end  -- 只有软 16(A+5) 才继续
                end
            end
        end
        return false
    end

    -- 阶段 2: 激进（18 以下都要牌，软 18 也继续）
    if difficulty == 2 then
        local stopAt = isBerserker and 25 or 18
        if total < stopAt then return true end
        if total == 18 then
            for _, card in ipairs(dealerHand) do
                if card.rank == 'A' then
                    local rawTotal = Blackjack.calculateHandRaw(dealerHand)
                    if rawTotal <= 28 then return true end
                end
            end
        end
        return false
    end

    -- 阶段 3: 作弊 AI（看玩家明牌决定）
    if difficulty == 3 then
        -- Assassin 庄家: 看不到玩家牌 → 退化成阶段 2 激进 AI
        if isAssassin then
            local stopAt = isBerserker and 25 or 18
            return total < stopAt
        end

        if not playerTotal then
            local stopAt = isBerserker and 25 or 18
            if total < stopAt then return true end
            return false
        end

        -- Berserker 庄家: 爆牌放宽到 25，敢追到 25
        if isBerserker and playerTotal > total and playerTotal <= 25 and total < 25 then
            return true
        end

        -- 玩家点数低（<=17）: 庄家要到 > 玩家点数
        if playerTotal <= 17 then
            if total < playerTotal then return true end  -- 关键：< 不是 <=
            if total == playerTotal and total < 19 then return true end  -- 同点时再赌一把
            return false
        end

        -- 玩家点数高（>=18）: 庄家爆牌概率大，保守停（>=17 就停）
        if playerTotal >= 18 and total >= 17 then
            return false
        end

        -- 默认: 激进（Berserker 到 25 才停）
        local stopAt = isBerserker and 25 or 18
        if total < stopAt then return true end
        return false
    end

    return total < 17
end

-- ============================================================
-- 胜负判定
-- 返回: "player" / "dealer" / "push"
-- ============================================================

function Blackjack.determineWinner(playerHand, dealerHand)
    local pTotal = Blackjack.calculateHand(playerHand)
    local dTotal = Blackjack.calculateHand(dealerHand)
    local pBust = Blackjack.isBust(playerHand)
    local dBust = Blackjack.isBust(dealerHand)

    if pBust and dBust then return "dealer" end  -- 经典规则：都爆算庄家赢
    if pBust then return "dealer" end
    if dBust then return "player" end
    if pTotal > dTotal then return "player" end
    if dTotal > pTotal then return "dealer" end
    return "push"
end

return Blackjack
