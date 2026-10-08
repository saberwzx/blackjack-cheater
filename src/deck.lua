-- ============================================================
-- Deck — 守恒牌堆（抽牌堆 cards + 弃牌堆 discardPile）
--
-- 「Blackjack Cheater」信息玩法的地基 —— 守恒铁律:
--   · 任何离场牌（清手/出千换牌/斩击/吸收）一律 toDiscard，绝不 GC
--   · 合成牌（出千换上的牌 / 67 生成 / 给牌遗物）计入总量，随弃牌堆循环
--   · 恒等式: 基础牌 + 注入牌 + 合成牌 = 抽牌堆 + 弃牌堆 + 各手牌 + 寄存牌
--   · 抽牌堆(cards)耗尽 → 弃牌堆洗入(shuffleDiscardIn)，shuffleCount +1
--
-- 兼容说明:
--   · self.cards 即抽牌堆本体（顶 = 索引 1），酒吧模式的原地下标操作全部不变
--   · Deck:discard 保留旧语义（酒吧专用: 塞回抽牌堆底部）；守恒代码请用 toDiscard
--   · uid 在入池时打戳（_stamp），跨 Deck 实例也不冲突（模块级计数器）
-- ============================================================

local Deck = {}
Deck.__index = Deck

-- 模块级 uid 计数器：rebuildDeck 等场景换新 Deck 实例时 uid 仍全局唯一
local GLOBAL_UID = 0

local SUITS = {"\u{2660}", "\u{2665}", "\u{2666}", "\u{2663}"}  -- ♠ ♥ ♦ ♣
local RANKS = {'A', 2, 3, 4, 5, 6, 7, 8, 9, 10, 'J', 'Q', 'K'}

function Deck.new(numDecks)
    numDecks = numDecks or 1   -- 基础规模：1 套 52 张（阶段表 stageDeckNum 再按难度加副）
    local self = setmetatable({}, Deck)
    self.numDecks      = numDecks
    self.cards         = {}          -- 抽牌堆（顶 = 索引 1）
    self.discardPile   = {}          -- 弃牌堆（守恒：只进不出，洗入时整体搬回抽牌堆）
    self.addedCollections = {}       -- 记录玩家注入的牌组历史
    self.shuffleCount  = 0           -- 弃牌洗入次数（洗牌事件探测用）
    self.syntheticCount= 0           -- 合成牌计数（toDiscard 收编无 uid 的牌时 +1，审计用）
    self:_build()
    self:shuffle()
    return self
end

-- 给牌打唯一身份戳（已在池中的牌不重复打；合成牌首次回收时收编）
function Deck:_stamp(card)
    if not card.uid then
        GLOBAL_UID = GLOBAL_UID + 1
        card.uid = GLOBAL_UID
        self.syntheticCount = self.syntheticCount + 1
    end
    return card
end

function Deck:_build()
    self.cards = {}
    for _ = 1, self.numDecks do
        for _, suit in ipairs(SUITS) do
            for _, rank in ipairs(RANKS) do
                GLOBAL_UID = GLOBAL_UID + 1
                table.insert(self.cards, {
                    uid    = GLOBAL_UID,
                    suit   = suit,
                    rank   = rank,
                    faceUp = false,
                    value  = nil,     -- nil = 用标准 Blackjack 算分
                    isSpecial = false,
                    is_basic  = true, -- 固有牌堆来源标记（独享至尊 / 闭关 的抽牌过滤依据）
                    kind   = "normal",
                    mult_bonus = 0,
                })
            end
        end
    end
end

-- 注入一批特殊牌（牌组系统用）—— 进入守恒循环，不再需要重建来"找回"
function Deck:addCards(cards, label)
    for _, c in ipairs(cards) do
        c.faceUp = false
        self:_stamp(c)
        table.insert(self.cards, c)
    end
    if label then
        table.insert(self.addedCollections, {
            label = label,
            count = #cards,
            time  = os.time(),
        })
    end
    self:shuffle()
end

function Deck:shuffle()
    for i = #self.cards, 2, -1 do
        local j = love.math.random(i)
        self.cards[i], self.cards[j] = self.cards[j], self.cards[i]
    end
end

-- ============================================================
-- 守恒 API（新代码入口）
-- ============================================================

-- 离场牌回收：进弃牌堆（守恒唯一入口）。合成牌在此收编并获得 uid。
function Deck:toDiscard(card)
    if not card then return end
    card.faceUp = false
    card._tweened = nil
    card.visual = nil
    self:_stamp(card)
    table.insert(self.discardPile, card)
end

-- 整手回收（手牌列表的清空由调用方负责）
function Deck:discardHand(hand)
    if not hand then return 0 end
    local n = 0
    for _, c in ipairs(hand) do
        self:toDiscard(c)
        n = n + 1
    end
    return n
end

-- 弃牌堆洗回抽牌堆。返回洗入张数（0 = 没洗）。
function Deck:shuffleDiscardIn()
    local n = #self.discardPile
    if n == 0 then return 0 end
    for i = 1, n do
        self.cards[#self.cards + 1] = self.discardPile[i]
    end
    self.discardPile = {}
    self:shuffle()
    self.shuffleCount = self.shuffleCount + 1
    return n
end

-- 抽牌堆成分计数（rank → 张数；普通牌 rank 为 A/2..10/J/Q/K）
function Deck:composition()
    local comp = {}
    for _, c in ipairs(self.cards) do
        local key = tostring(c.rank)
        comp[key] = (comp[key] or 0) + 1
    end
    return comp
end

-- 审计：抽牌堆 + 弃牌堆 总数（手牌/寄存牌由调用方累加）
function Deck:auditTotal()
    return #self.cards + #self.discardPile
end

-- ============================================================
-- 抽牌 API（旧签名不变；抽空时洗入弃牌堆而非重建）
-- ============================================================

-- 抽牌过滤入口：basicOnly == true 时只抽「固有牌堆」的牌（is_basic 标记）
-- 抽牌方（玩家/庄家）由调用方区分后传入 basicOnly，Deck 本身保持无状态
-- basicOnly 为 nil/false 时行为与旧版 Deck:draw 完全一致
-- 注意： basicOnly 是暗处偏置，信息玩法模式下应停用（由模式配置控制）
function Deck:drawFor(faceUp, basicOnly)
    if #self.cards == 0 then
        self:shuffleDiscardIn()
    end
    if #self.cards == 0 then
        -- 防御：抽/弃双空（异常状态）才允许重建，正常守恒流程到不了这里
        self:_build()
        self:shuffle()
    end
    local idx = 1
    if basicOnly == true then
        idx = nil
        for i, c in ipairs(self.cards) do
            if c.is_basic then idx = i break end
        end
        if not idx then idx = 1 end   -- 固有牌抽完了 → 退化为普通抽取，绝不卡死
    end
    local card = table.remove(self.cards, idx)
    if card and faceUp ~= nil then
        card.faceUp = faceUp
    end
    return card
end

function Deck:draw(faceUp)
    return self:drawFor(faceUp, nil)
end

-- 按偏好抽牌（"低牌加重" / "高牌加重" 遗物用）
-- mode: "low" → 优先抽 2-6；"high" → 优先抽 10/J/Q/K/A
-- basicOnly == true 时只在固有牌里挑；找不到符合条件的牌时退化为普通抽取
-- 注意： 暗处偏置，信息玩法模式下应停用（由模式配置控制）
function Deck:drawPreferred(faceUp, mode, basicOnly)
    if #self.cards == 0 then
        self:shuffleDiscardIn()
    end
    local idx = nil
    for i, c in ipairs(self.cards) do
        local r = c.rank
        local ok = (basicOnly ~= true) or c.is_basic
        if ok then
            if mode == "low" then
                if type(r) == "number" and r >= 2 and r <= 6 then idx = i break end
            elseif mode == "high" then
                if r == 'A' or r == 10 or r == 'J' or r == 'Q' or r == 'K' then idx = i break end
            end
        end
    end
    if not idx and basicOnly == true then
        -- 偏好落空：退化为「任意固有牌」，保证过滤语义不丢
        for i, c in ipairs(self.cards) do
            if c.is_basic then idx = i break end
        end
    end
    if not idx then idx = 1 end
    local card = table.remove(self.cards, idx)
    if card and faceUp ~= nil then
        card.faceUp = faceUp
    end
    return card
end

-- 看抽牌堆顶 N 张（不消耗），返回浅拷贝列表
function Deck:peek(n)
    n = n or 1
    local out = {}
    for i = 1, math.min(n, #self.cards) do
        local c = self.cards[i]
        table.insert(out, { uid = c.uid,
                            suit = c.suit, rank = c.rank, value = c.value,
                            isSpecial = c.isSpecial, kind = c.kind,
                            is_67 = c.is_67, is_rps = c.is_rps,
                            is_blackhole = c.is_blackhole,   -- 黑洞牌标识不能丢，否则预览会显示成普通牌
                            is_cage = c.is_cage,             -- 牢笼牌标识同理
                            mult_bonus = c.mult_bonus })
    end
    return out
end

function Deck:drawMany(count, faceUp)
    local cards = {}
    for i = 1, count do
        table.insert(cards, self:draw(faceUp))
    end
    return cards
end

-- 【酒吧专用】塞回抽牌堆底部（末端 = 远离 drawFor 取牌端），保持旧语义与旧名
function Deck:discard(card)
    if card then
        card.faceUp = false
        table.insert(self.cards, card)
    end
end

-- 兼容名：旧语义是"抽空整体重建"，守恒版 = 弃牌洗回（绝不丢牌）
function Deck:reset()
    self:shuffleDiscardIn()
end

function Deck:count()
    return #self.cards
end

-- 统计抽牌堆里各种特殊牌的数量
function Deck:getSpecialCardStats()
    local stats = { decimal = 0, negative = 0, multiplier = 0, s67 = 0, rps = 0, blackhole = 0, normal = 0 }
    for _, c in ipairs(self.cards) do
        if c.is_67 then stats.s67 = stats.s67 + 1
        elseif c.is_rps then stats.rps = stats.rps + 1
        elseif c.kind and stats[c.kind] ~= nil then
            stats[c.kind] = stats[c.kind] + 1
        else
            stats.normal = stats.normal + 1
        end
    end
    return stats
end

function Deck.makeCard(suit, rank, faceUp)
    return {
        suit   = suit or "♠",
        rank   = rank or 'A',
        faceUp = faceUp ~= false,
        value  = nil,
        isSpecial = false,
        kind   = "normal",
        mult_bonus = 0,
    }
end

return Deck
