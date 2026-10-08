-- ============================================================
-- BarMode — 酒吧模式（gameMode == "bar"）
--
-- 职责：独立于基础/困难模式的第三条玩法线——无筹码/下注/破产/商店/遗物/职阶/
--       出千/阶段（state.stage 恒 1）；每小局直接发牌比大小，固定 100 小局。
-- 状态容器：state.bar（见 newBarState），杯口径 mouth = 已喝口数（5 = 空，随即出栏）。
-- 调用方：startNewGame / resetRound / hitPlayer / _doScoring 的酒吧分支、main.lua 输入分发。
-- 禁区：不改基础与困难模式的任何行为；随机源只用 love.math.random；不写存档。
--
-- 分层：本模块只依赖叶子模块（见 require），唯一对上层的依赖是
--       GameState 的三个回调（dealInitial / endRound / registerAllRelics），
--       由 game_state.lua 在加载末尾调用 BarMode.bind(GameState, deps) 注入，
--       再把 BarMode 的全部 bar* 函数回填到 GameState 表 —— 对外调用点
--       （GameState.barXxx）保持不变。
-- ============================================================

local Cocktails    = require("src.cocktails")
local BarLines     = require("src.bar_lines")
local Sfx          = require("src.sfx")
local Blackjack    = require("src.blackjack")
local DeckTypes    = require("src.deck_types")
local Champion     = require("src.champion")
local EventManager = require("src.event_manager")
local Deck         = require("src.deck")

local BarMode = {}

-- GameState 回调与共用常量（bind 时注入；HAND_MAX / FLASH_DURATION 的唯一
-- 定义仍在 game_state.lua，这里只是引用，避免两处常量失步）
local GS, HAND_MAX, FLASH_DURATION

-- 注入依赖并把全部 bar* 函数回填到 GameState 表（game_state.lua 加载末尾调用一次）
function BarMode.bind(gameState, deps)
    GS = gameState
    HAND_MAX = deps.HAND_MAX
    FLASH_DURATION = deps.FLASH_DURATION
    for name, fn in pairs(BarMode) do
        if type(fn) == "function" and name ~= "bind" then
            gameState[name] = fn
        end
    end
end

-- ========== 酒吧模式常量 ==========
local BAR_TOTAL_ROUNDS    = 100    -- 固定 100 小局
local BAR_FALLBACK_EVERY  = 20     -- 每满 20 局保底赠酒一次（第 20/40/60/80/100 局开局时）
local BAR_GIFT_CHOICES    = 3      -- 保底通道三选一
local BAR_PROB_BASE       = 0.01   -- 概率通道基础 1%
local BAR_PROB_PER_WIN    = 0.005  -- 每赢一局 +0.5%
local BAR_PROB_PER_WIN_2X = 0.01   -- 收获之月：每胜 +1%
local BAR_PLUTO_BONUS     = 0.02   -- 黑暗风暴：被动期间每胜额外 +2%
local BAR_PLANETX_BACKFILL= 0.25   -- 泛银河系漱口酒：每小局结束 25% 回填
local BAR_MAX_CUPS        = 6      -- 调酒栏上限 6 杯
local BAR_DECK_FACES      = 10     -- 10 种牌面（含六面 / 二十面骰子牌组）
local BAR_CARDS_EACH      = 10     -- 每种 10 张
local BAR_MIN_CARDS       = 4      -- 牌堆少于这个数就重灌（防抽空卡死）
local BAR_HALF_POUR       = 0.5    -- 血腥玛丽：输局只喝半口
local BAR_EPS             = 0.000001
local BAR_BRIEF_PAGES     = 2      -- 说明弹窗页数（第 1 页玩法 / 第 2 页醉酒）
-- 候选池：TYPES 里除 remove（生成空列表）与 champion（需解锁）之外的 10 种
-- 顺序 = 说明文案的展示顺序；骰子牌组固定在末尾（见 barBuildDeck 的 order 注释）
local BAR_DECK_POOL = {
    "decimal", "negative", "multiplier", "s67",
    "rps", "blackhole", "cage", "chip", "dice6", "dice20",
}

-- 空容器（new 与 startNewGame 都必须重建，禁止跨周目泄漏）
function BarMode.newBarState()
    return {
        round        = 0,      -- 已完成的小局数（0 = 还没开始第一局）
        cups         = {},     -- 调酒栏：[{ id = 酒 id, mouth = 已喝口数, wobble = 视觉时间戳 }]
        obtained     = {},     -- 获得过的酒 id 集合（保底/概率通道都只发没获得过的）
        buffs        = {},     -- 醉酒倒计时：id → 剩余小局数
        template     = {},     -- 80 张样牌模板（8 种 × 10 张，开局构建一次）
        faces        = {},     -- 8 项牌面描述：[{ type = 牌组 key, card = 样牌 }]
        prob         = BAR_PROB_BASE,  -- 概率通道当前概率
        winCount     = 0,
        loseCount    = 0,
        winsSinceBackfill = 0, -- 迈泰：距上次回填的胜场数
        lastResult   = nil,    -- 仅标记本小局是否已递减过倒计时（tickDown 后清空，保证每小局只减一次）
        boilerLine   = nil,    -- 酒保文本框当前科普短句
        giftText     = nil,    -- 概率通道送出时的「送给你」临时文案
        giftTextUntil= 0,
        lastGiftKind = nil,    -- "prob" / "fallback"
        probGiftCount= 0,
        fallbackCount= 0,
        fallbackDone = {},     -- 已经触发过保底的局号（防重入）
        pendingFallbackRound = nil,  -- 非 nil = 三选一弹窗正开着
        giftOfferIds = nil,    -- 三选一的 3 个候选酒 id
        drinkAmount  = nil,    -- 弹窗待喝的杯数（1 或 0.5）
        drinkReason  = nil,    -- "loss" / "manual"
        lastDrink    = nil,
        abilitiesUsed = {},     -- 主动技能：每小局使用记录（酒 id → true）
        hangoverRound = nil,   -- 宿醉生效的小局号：与 bar.round 相等时本局处于宿醉
        hangoverColor = nil,   -- 宿醉全屏滤镜颜色 { r, g, b }
    }
end

-- 牌面拷贝（只拷标量字段；模板与手牌必须互不影响）
function BarMode.barCloneCard(c)
    local n = {}
    for k, v in pairs(c) do
        if type(v) ~= "table" then n[k] = v end
    end
    n.faceUp = false
    return n
end

-- 从 10 种特殊牌组各取一张样牌（有点数的样牌比较点数尽量两两严格不同），
-- 每种样牌复制 BAR_CARDS_EACH 张 = 100 张，作为本模式唯一牌组（不再随机挑 3 种 × 30 张）。
-- faces/template 落盘一律按 BAR_DECK_POOL 固定顺序，保证 UI 展示顺序稳定、可复现。
function BarMode.barBuildDeck(state)
    local DeckTypes = require("src.deck_types")

    -- 样牌的「比较点数」折算（严格去重用）：无法折算时返回 nil → 该样牌不参与去重，直接放行
    local function compareValue(card)
        local kind = card.kind
        -- 骰子牌掷骰前没有确定点数：显式返回 nil（放行、不占位、不参与去重）
        if kind == "dice6" or kind == "dice20" then return nil end
        if kind == "decimal" or kind == "negative" or kind == "multiplier" or kind == "s67" then
            return card.value
        end
        if kind == "rps" then return 0 end
        if card.is_blackhole or card.is_cage or card.is_chip then
            local rank = card.rank
            if rank == "A" then return 1 end
            if type(rank) == "number" then return rank end
            if rank == "J" or rank == "Q" or rank == "K" then return 10 end
        end
        return nil
    end

    -- 分配顺序按「可选值域宽度升序」，降低撞号概率（s67 只有 {6, 7}，必须最先占位）
    -- 骰子牌组固定在最后：它们没有确定点数（compareValue 返回 nil），排在末尾可保证
    -- 既有 8 种类型的占位行为与顺序一字不变（回归保护）
    local order = { "rps", "s67", "decimal", "negative", "multiplier", "blackhole", "cage", "chip", "dice6", "dice20" }
    -- 每个类型重试上限：超限就接受当前这张（绝不允许 while true 死循环，也绝不抛错）
    local RETRY_MAX = 200

    local picked, used = {}, {}   -- picked[key] = 样牌；used[比较点数] = true
    for _, key in ipairs(order) do
        local one, cval = nil, nil
        for _ = 1, RETRY_MAX do
            local sample = DeckTypes.generate(key, "small")
            if #sample == 0 then break end        -- 空列表（如 remove）→ 跳过该类型，既有防御
            local cand = sample[love.math.random(#sample)]
            one, cval = cand, compareValue(cand)
            if cval == nil or not used[cval] then break end   -- 无可折算值或不撞号 → 采用
        end
        if one then
            if cval ~= nil then used[cval] = true end
            picked[key] = one
        end
    end

    local template, faces = {}, {}
    for _, key in ipairs(BAR_DECK_POOL) do
        local one = picked[key]
        if one then
            faces[#faces + 1] = { type = key, card = BarMode.barCloneCard(one) }
            for _ = 1, BAR_CARDS_EACH do
                template[#template + 1] = BarMode.barCloneCard(one)
            end
        end
    end
    state.bar.template = template
    state.bar.faces    = faces
    BarMode.barRefillDeck(state)
end

-- 用模板重灌牌堆并洗牌（每小局开始时调用一次；模板本身永不被消耗）
function BarMode.barRefillDeck(state)
    local cards = {}
    for _, c in ipairs(state.bar.template) do
        cards[#cards + 1] = BarMode.barCloneCard(c)
    end
    state.deck = Deck.new(0)                 -- 空牌堆（不生成固有扑克）
    state.deck:addCards(cards, "bar")        -- 注入 + 洗牌
end

-- 抽空兜底：牌堆见底就重灌，保证 drawFor 永远抽得到牌、不返回 nil
function BarMode.barEnsureDeck(state)
    if state.gameMode ~= "bar" then return end
    if not state.bar or not state.deck then return end
    if #state.deck.cards < BAR_MIN_CARDS then BarMode.barRefillDeck(state) end
end

-- ============================================================
-- 开局
-- ============================================================
function BarMode.barStartNewGame(state)
    state.stage        = 1
    state.roundsInStage = 0
    state.class        = nil
    state.classCharges = 0
    state.dealerClass  = nil
    state.dealerCharges = 0
    state.dealerStreak = 0
    state.dealerRelics = {}
    state.relics       = {}
    state.pendingRelics = nil
    state.shopOfferings = nil
    state.shopDeckOfferings = nil
    state.deckCollections = {}
    state.debt         = nil
    state.turn         = 1
    state.player       = { chips = 0, bet = 0, hand = {} }
    state.dealer       = { hand = {} }
    state.result       = nil
    state.lastScoreDetails = nil
    state.streak       = 0
    state.accuseResult = nil
    state.scorePopups  = {}
    state.screenShake  = 0

    state.bar          = BarMode.newBarState()
    state.barEnding    = nil
    BarMode.barBuildDeck(state)            -- 开局构建一次 80 张牌组
    BarLines.resetBag()
    -- 开局没有已有酒 → 并集为空 → 通用池（随机序列与旧版 BarLines.next 完全一致）
    state.bar.boilerLine = BarLines.nextTrivia({})

    -- 开局说明弹窗（两页，模态，纯阅读 + 点确认；确认后才进第一局）
    state._barBriefOpen  = true
    state._barBriefShown = true
    state._barBriefPage  = 1
    state._barBriefReopen = false
    state.settingsOpen   = false
    state.deckOverviewOpen = false
    state.state          = "bar_brief"

    GS.registerAllRelics(state)       -- relics 为空 → 清掉上一周目残留的监听
    state.events:trigger(EventManager.EVENTS.GAME_START, { game = state })
end

-- 说明弹窗关闭（最后一次前进时调用）
function BarMode.barCloseBrief(state)
    if not state._barBriefOpen then return end
    local reopen = state._barBriefReopen
    state._barBriefOpen   = false
    state._barBriefPage   = nil
    state._barBriefReopen = false
    if reopen then
        -- 重看入口：只看说明，关闭后回要牌阶段，不推进小局、不动任何小局数据
        state.state = "player"
        return
    end
    BarMode.barBeginRound(state)
end

-- 说明弹窗「前进」：未到最后一页只翻页；已在最后一页则关闭弹窗
function BarMode.barBriefNext(state)
    if state.state ~= "bar_brief" then return end
    local page = state._barBriefPage or 1
    if page < BAR_BRIEF_PAGES then
        state._barBriefPage = page + 1
        return
    end
    BarMode.barCloseBrief(state)
end

-- 「说明」入口：重看说明。仅要牌阶段可点（避免记录/还原旧 state 的复杂度）
-- 关闭后回 "player"，且不得重置当前小局的任何数据（手牌、点数、abilitiesUsed 全部原样）
function BarMode.barOpenBrief(state)
    if state.gameMode ~= "bar" then return end
    if state.state ~= "player" then return end
    state._barBriefOpen    = true
    state._barBriefPage    = 1
    state._barBriefReopen  = true
    -- 清掉所有浮层：说明弹窗是模态，底下不许再叠调酒列表 / 设置页 / 牌堆总览
    state._barAlcOpen      = nil
    state.settingsOpen     = false
    state.deckOverviewOpen = false
    state.state            = "bar_brief"
end

-- ============================================================
-- 小局推进
-- ============================================================
function BarMode.barBeginRound(state)
    local bar = state.bar
    if not bar then return end

    -- 100 局跑完 → 结局判定
    if bar.round >= BAR_TOTAL_ROUNDS then
        return BarMode.barSettle(state)
    end

    local nextRound = bar.round + 1

    -- ===== 保底通道：开局（第 1 局）+ 每满 20 局（第 20/40/60/80/100 局开局时）=====
    if bar.pendingFallbackRound == nil and not bar.fallbackDone[nextRound]
       and (nextRound == 1 or nextRound % BAR_FALLBACK_EVERY == 0) then
        bar.fallbackDone[nextRound] = true
        local pool = BarMode.barGiftPool(state)
        if #pool > 0 then                      -- 一款不剩 → 本通道跳过
            bar.pendingFallbackRound = nextRound
            BarMode.barOpenGiftPick(state, pool)
            return
        end
    end

    -- ===== 概率通道：每小局开始时按当前概率判定 =====
    BarMode.barRollGift(state)

    -- ===== 正式开这一小局 =====
    bar.round = nextRound
    BarMode.barResetRoundFields(state)
    BarMode.barRefillDeck(state)
    GS.dealInitial(state)
    state.events:trigger(EventManager.EVENTS.ROUND_START, { game = state })
end

-- 每小局清场（对应基础模式的 resetRound，但不下注、不重建固有牌堆）
function BarMode.barResetRoundFields(state)
    state.player.hand = {}
    state.dealer.hand = {}
    state.player.bet  = 0
    state.result      = nil
    state.lastScoreDetails = nil
    state.firstHitThisRound = false
    state.turn        = state.turn + 1
    state.accuseResult = nil
    state._natural_bj  = nil
    state._s67_triggered = nil
    state._archer_preview = nil
    state._peekActive  = false
    state._peekKind    = nil
    state._blackHoleUsed = nil
    state._cardPackActive = nil
    state._saberConsumed = nil
    state._saberAnim   = nil
    state._forcedResult = nil
    state._mobileShopUsed = nil
    state._mobileShopReturn = nil
    state._drawRestrict = nil
    state._distractorShown = nil
    state._probeActive = nil
    state._barDrinkOpen = false
    state.cheatState = {
        isCheating = false, cheatType = 0, visualTell = false, wasAccused = false,
        cheatExecuted = false, cheatTellKind = nil,
    }
    state.scorePopups = {}
    state.bar.abilitiesUsed = {}      -- 主动技能：每小局使用记录（酒 id → true），每小局清空
    state._barDealerSealed  = false   -- 新加坡司令「封口」：每小局清空，不允许跨局残留

    -- 宿醉清理：宿醉局本身（round == hangoverRound）必须保留，再下一局才恢复原状。
    -- 本函数是在 barBeginRound 里 bar.round = nextRound 之后被调用的，所以用 > 而不是 >=。
    if state.bar.hangoverRound and state.bar.round > state.bar.hangoverRound then
        state.bar.hangoverRound = nil
        state.bar.hangoverColor = nil
    end
end

-- ============================================================
-- 赠酒两条通道
-- ============================================================
-- 候选池 = 玩家从未获得过的酒
function BarMode.barGiftPool(state)
    local out = {}
    for _, def in ipairs(Cocktails.LIBRARY) do
        if not state.bar.obtained[def.id] then out[#out + 1] = def.id end
    end
    return out
end

-- 入栏（满 6 杯 / 已获得过 → 不入栏，返回 false）
function BarMode.barAddCup(state, id)
    local bar = state.bar
    if not id or bar.obtained[id] then return false end
    if #bar.cups >= BAR_MAX_CUPS then return false end
    bar.obtained[id] = true
    bar.cups[#bar.cups + 1] = { id = id, mouth = 0, wobble = 0 }
    return true
end

-- 保底通道：随机抽 3 款（不足 3 款则全给出）→ 三选一弹窗（独占输入）
function BarMode.barOpenGiftPick(state, pool)
    local copy, ids = {}, {}
    for _, id in ipairs(pool) do copy[#copy + 1] = id end
    local n = math.min(BAR_GIFT_CHOICES, #copy)
    for _ = 1, n do
        ids[#ids + 1] = table.remove(copy, love.math.random(#copy))
    end

    state.bar.giftOfferIds = ids
    state._barGiftOpen = true
    state._barDrinkOpen = false
    state.settingsOpen = false
    state.deckOverviewOpen = false
    state.classOfferActive = false
    state.classOffer = nil
    state.state = "bar_gift"
end

-- 三选一确认（index 从 1 起）
function BarMode.barPickGift(state, index)
    local bar = state.bar
    if not state._barGiftOpen then return end
    local ids = bar.giftOfferIds or {}
    local id  = ids[index]

    state._barGiftOpen = false
    bar.giftOfferIds = nil
    bar.pendingFallbackRound = nil
    bar.fallbackCount = bar.fallbackCount + 1
    bar.lastGiftKind = "fallback"

    if id then
        if not BarMode.barAddCup(state, id) then
            state._flashMsg = {                 -- 栏满 6 杯：照常弹窗，不入栏
                text = "调酒栏已满，" .. Cocktails.getById(id).name .. " 先记在账上",
                expires = love.timer.getTime() + 2,
            }
        else
            state._flashMsg = {
                text = "酒保请了你一杯「" .. Cocktails.getById(id).name .. "」",
                expires = love.timer.getTime() + 2,
            }
        end
    end

    BarMode.barBeginRound(state)              -- 回到开局流程，继续这一小局
end

-- 概率通道：每小局开始判定，中了白送一杯（玩家没有选择权）
function BarMode.barRollGift(state)
    local bar = state.bar
    if love.math.random() >= bar.prob then return end

    bar.prob = BAR_PROB_BASE                    -- 送出后立刻回到 1%
    bar.probGiftCount = bar.probGiftCount + 1
    bar.lastGiftKind = "prob"
    bar.giftText = "送给你"                     -- 文本框临时替换
    bar.giftTextUntil = love.timer.getTime() + 3.0

    local pool = BarMode.barGiftPool(state)
    if #pool == 0 then return end
    local id = pool[love.math.random(#pool)]
    if BarMode.barAddCup(state, id) then
        state._flashMsg = {
            text = "酒保请了你一杯「" .. Cocktails.getById(id).name .. "」",
            expires = love.timer.getTime() + 2,
        }
    else                                        -- 栏满：不新增杯数，但文案与归位照常
        state._flashMsg = {
            text = "酒保想请你一杯，但调酒栏已经满了",
            expires = love.timer.getTime() + 2,
        }
    end
end

-- ============================================================
-- 喝酒
-- ============================================================
-- 喝一口：mouth += amount；喝空立刻出栏；该酒被动倒计时刷回 5
function BarMode.barDrink(state, cupIndex, amount, reason)
    local bar = state.bar
    local cup = cupIndex and bar.cups[cupIndex]
    if not cup then return false end
    amount = amount or 1

    cup.mouth = (cup.mouth or 0) + amount
    Cocktails.refreshBuff(state, cup.id)
    bar.lastDrink = { id = cup.id, reason = reason, index = cupIndex }

    local def = Cocktails.getById(cup.id)
    if cup.mouth >= Cocktails.POURS_PER_CUP - BAR_EPS then
        cup.mouth = Cocktails.POURS_PER_CUP
        table.remove(bar.cups, cupIndex)
        state._flashMsg = {
            text = (def and def.name or cup.id) .. " 喝完了",
            expires = love.timer.getTime() + 2,
        }
    else
        state._flashMsg = {
            text = "喝了一口 " .. (def and def.name or cup.id),
            expires = love.timer.getTime() + 1.5,
        }
    end
    return true
end

-- 主动喝酒（要牌阶段点调酒栏；与被动喝酒同一套流程）
function BarMode.barManualDrink(state, cupIndex)
    if state.gameMode ~= "bar" then return end
    if state.state ~= "player" then return end
    if state._barDrinkOpen or state._barGiftOpen or state._barBriefOpen then return end
    local bar = state.bar
    if not bar or #bar.cups == 0 then return end

    if #bar.cups <= 1 then
        -- 只有一杯：不必选，直接喝
        BarMode.barDrink(state, 1, 1, "manual")
        if #bar.cups == 0 then return BarMode.barFail(state) end  -- 喝空即失败
        return
    end

    bar.drinkAmount = 1
    bar.drinkReason = "manual"
    state._barDrinkOpen = true
    state.settingsOpen = false
    state.deckOverviewOpen = false
    state.state = "bar_drink"
end

-- 喝酒选择弹窗确认
function BarMode.barPickDrink(state, index)
    local bar = state.bar
    if not state._barDrinkOpen then return end
    local reason = bar.drinkReason or "manual"
    local amount = bar.drinkAmount or 1

    state._barDrinkOpen = false
    bar.drinkReason = nil
    bar.drinkAmount = nil

    BarMode.barDrink(state, index, amount, reason)

    if reason == "manual" then
        if #bar.cups == 0 then return BarMode.barFail(state) end
        state.state = "player"                  -- 回到要牌阶段
        return
    end
    BarMode.barAfterDrink(state)              -- 输局：继续局末收尾
end

-- 喝酒之后的收尾：失败 / 结局 / 回到 result
function BarMode.barAfterDrink(state)
    if #state.bar.cups == 0 then return BarMode.barFail(state) end
    if state.bar.round >= BAR_TOTAL_ROUNDS then return BarMode.barSettle(state) end
    state.state = "result"
    state.events:trigger(EventManager.EVENTS.ROUND_END, {
        game = state, details = state.lastScoreDetails,
    })
end

-- ============================================================
-- 失败与结局
-- ============================================================
-- 调酒栏为空 → 被请出去（沿用 forceExit 通道；文案不得出现「没钱」）
function BarMode.barFail(state)
    -- 一次性守卫：进入 forceExit 只允许发生一次。
    -- 若被重复调用，Sfx.playGetout() 内部的 stop + play 会把播放位置反复归零，听感就是「没有声音」。
    if state.state == "forceExit" then return end
    state._barDrinkOpen = false
    state._barGiftOpen  = false
    state.exitReason    = "调酒栏空了 —— 酒保把你请了出去。"
    -- 倒计时与音效时长对齐：保证「滚出去」音效播完再回标题（Sfx 拿不到时长时退化为 3 秒）
    state.quitTimer     = math.max(3, Sfx.getGetoutDuration() + 0.5)
    state.state         = "forceExit"
    -- 问题 3：酒吧模式的结束路径不播「滚出去」音效（基础 / 困难破产照旧播）。
    -- 写成「非酒吧才播」的条件，而不是删掉调用或改动 Sfx 模块内部。
    if state.gameMode ~= "bar" then Sfx.playGetout() end
end

-- 第 100 局结算后判结局（优先级：约会 > 养鱼 > 好酒友）
function BarMode.barSettle(state)
    local bar = state.bar
    local total = Cocktails.totalPours(state)
    local ending
    if math.abs(total - 1) < BAR_EPS then
        ending = "date"                          -- 全场只剩一口
    elseif #bar.cups >= BAR_MAX_CUPS then
        ending = "fish"                          -- 6 杯全都有剩
    elseif total > 0 then
        ending = "buddy"                         -- 还有酒没喝完
    else
        return BarMode.barFail(state)          -- 全喝光 → 走失败，不算结局
    end
    state.barEnding = ending
    state.state     = "bar_ending"
    if Sfx and Sfx.play21 then Sfx.play21() end
end

-- ============================================================
-- 酒吧模式：34 款酒的主动技能（见 Cocktails.LIBRARY[].ability）
--
-- 规则：
--   * 只能在自己回合、停牌之前用（state.state == "player"）
--   * 每款生效中的酒每小局最多用 1 次（state.bar.abilitiesUsed[id]）
--   * 需要选牌的技能走 state.state == "bar_alcpick" + state._barAlcPick 模态，
--     取消不消耗次数；执行完统一走 BarMode.barAfterAbility
-- 禁区：不改基础与困难模式的任何行为；随机源只用 love.math.random；
--       手牌操作必须同步 card.faceUp / card.visual / card._tweened
-- ============================================================

-- 单张手牌的点数（低/最高牌的判定口径）
local function barCardScore(card)
    return Blackjack.calculateHand({ card })
end

-- 按「入场」规格加入手牌：明牌、清 tween 以便走入场动画、清 visual 防残留
local function barAddHandCard(hand, card)
    if not card then return false end
    card.faceUp = true
    card._tweened = nil
    card.visual = nil
    hand[#hand + 1] = card
    return true
end

-- 「移走即补」（问题 6）：庄家明牌（下标 >= 2）被移走之后，立刻补 1 张新明牌，
-- 保证净明牌数不变。供本次「移花」与后续同类「移走庄家明牌」的技能共用（模块级局部，不污染全局）。
--   牌堆见底 → 先走 barEnsureDeck 重灌再抽，绝不抽到 nil；
--   安全上限 → 庄家手牌总数已达 HAND_MAX（= 12，drawHands 的 6 列 x 2 行绘制容量）时跳过补牌，
--              不硬塞、也不改任何手牌内容；
--   补牌规格 → 明牌 / 清 _tweened / 清 visual，与其它入场牌一致（走 barAddHandCard）。
local function barRefillDealerUpCard(state)
    local dHand = state and state.dealer and state.dealer.hand
    if not dHand then return false end
    if #dHand >= HAND_MAX then return false end
    BarMode.barEnsureDeck(state)
    local card = state.deck:drawFor(true)
    if not card then return false end
    return barAddHandCard(dHand, card)
end

-- 从手牌移除指定下标并丢弃回牌堆底部（清 visual / tween，避免残留绘制）
local function barRemoveHandAt(state, hand, idx)
    local c = table.remove(hand, idx)
    if not c then return nil end
    c._tweened = nil
    c.visual = nil
    state.deck:discard(c)          -- discard 内部会把 faceUp 置 false 并追加到牌堆末尾
    return c
end

-- 提示（沿用既有 _flashMsg 通道，结构不得改动）
local function barAbilityFlash(state, text)
    state._flashMsg = { text = text, expires = love.timer.getTime() + FLASH_DURATION }
end

-- 牌面去重键（换牌候选用：value 优先，其次 rps 符号，最后 rank）
local function barFaceKey(card)
    if not card then return "nil" end
    if card.value ~= nil then return "v" .. tostring(card.value) end
    if card.rps_symbol ~= nil then return "r" .. tostring(card.rps_symbol) end
    return "k" .. tostring(card.rank)
end

-- 技能前置条件（不含「生效中 / 本小局已用 / 回合」判定）——不满足则该行灰显
function BarMode.barAbilityReady(state, key)
    local bar = state and state.bar
    if not (bar and state.player and state.dealer and state.deck) then return false end
    local hand  = state.player.hand
    local dHand = state.dealer.hand
    local nHand = #hand
    local kinds = {
        reshuffle = nHand > 0,
        swap      = nHand > 0,
        peek3     = #state.deck.cards > 0,
        burn      = #state.deck.cards > 0,
        dup       = nHand > 0 and nHand < HAND_MAX,
        seal      = true,
        chill     = nHand > 0,
        snatch    = nHand > 0 and #dHand >= 2,   -- 必须存在酒保明牌（下标 >= 2）
        discard   = nHand > 0,
        chaos     = nHand < HAND_MAX,
        take      = #dHand >= 2,
        flick     = nHand > 0,
        -- ===== 后 22 款技能（口径：明牌 = 下标 >= 2，即 #dHand - 1 张）=====
        -- 方向 A：改变庄家明牌数量
        foolish   = #dHand >= 2,
        magic     = #dHand < HAND_MAX,
        hush      = #dHand >= 2,
        crown     = (#dHand - 1) < 2 and #dHand < HAND_MAX,       -- 明牌不足 2 张才可发动
        pairing   = #dHand >= 2 and #dHand < HAND_MAX,
        tide      = (#dHand - 1) < nHand and #dHand < HAND_MAX,   -- 明牌少于你的手牌数才补
        blaze     = #dHand >= 2 and #dHand < HAND_MAX,
        globe     = (#dHand - 1) < 3 and #dHand < HAND_MAX,       -- 明牌不足 3 张才可发动
        -- 方向 B：强制庄家抽牌
        decree    = #dHand < HAND_MAX,
        sermon    = #dHand + 2 <= HAND_MAX,
        charge    = #dHand + 2 <= HAND_MAX,
        brute     = nHand > 0 and #dHand + 2 <= HAND_MAX,         -- 手牌为空时不可发动
        hang      = #dHand >= 2 and #state.deck.cards > 0,
        doom      = #dHand + 3 <= HAND_MAX,
        tempt     = #dHand < HAND_MAX and #state.deck.cards > 0,
        collapse  = #dHand < HAND_MAX and #state.deck.cards > 0
                     and Blackjack.calculateHand(dHand) < 21,      -- 已到 21 点再点就是空放
        -- 方向 C：改变牌库构成
        reckon    = #state.deck.cards > 0,
        solitude  = #state.deck.cards > 0,
        revolve   = true,                                          -- 模板常在，随时可重灌
        temper    = #state.deck.cards > BAR_MIN_CARDS,             -- 牌堆必须大于保底才可发动
        wish      = true,
        verdict   = #state.deck.cards > BAR_MIN_CARDS,             -- 同调和
    }
    return kinds[key] == true
end

-- 该酒的技能此刻是否可点（生效中 + 未用过 + 在自己回合 + 前置条件满足）
function BarMode.barAbilityUsable(state, id)
    if not (state and state.gameMode == "bar" and state.bar) then return false end
    if state.state ~= "player" then return false end
    if not Cocktails.isActive(state, id) then return false end
    if state.bar.abilitiesUsed and state.bar.abilitiesUsed[id] then return false end
    local def = Cocktails.getById(id)
    if not (def and def.ability) then return false end
    return BarMode.barAbilityReady(state, def.ability.key)
end

-- 展开列表的数据源（顺序按 LIBRARY，UI 只读）
function BarMode.barAbilityList(state)
    local out = {}
    if not (state and state.gameMode == "bar" and state.bar) then return out end
    local used = state.bar.abilitiesUsed or {}
    for _, def in ipairs(Cocktails.LIBRARY) do
        if def.ability and Cocktails.isActive(state, def.id) then
            out[#out + 1] = {
                def     = def,
                id      = def.id,
                ability = def.ability,
                used    = used[def.id] == true,
                usable  = BarMode.barAbilityUsable(state, def.id),
            }
        end
    end
    return out
end

-- 换牌候选：该牌所属牌组的全部可能牌面（复用 Champion.buildGroupCards，按牌面去重）
function BarMode.barSwapOptions(state, handIndex)
    local card = state.player and state.player.hand[handIndex]
    if not card then return {} end
    local Champion = require("src.champion")
    local kind = card.kind or "normal"
    if card.is_blackhole then kind = "blackhole"
    elseif card.is_cage then kind = "cage"
    elseif card.is_chip then kind = "chip" end
    local all, out, seen = Champion.buildGroupCards(kind), {}, {}
    for _, c in ipairs(all) do
        local k = barFaceKey(c)
        if not seen[k] then
            seen[k] = true
            out[#out + 1] = c
        end
    end
    return out
end

-- 错乱候选：冠军牌组 36 张（深拷贝）；不可用时从 8 种酒吧牌组随机兜底一张
function BarMode.barChaosOptions(state)
    local Champion = require("src.champion")
    local out = {}
    if Champion.isAvailable(state) then
        for _, c in ipairs(state.championCards or {}) do
            out[#out + 1] = Champion.cloneCard(c)
        end
        return out
    end
    local DeckTypes = require("src.deck_types")
    local key = BAR_DECK_POOL[love.math.random(#BAR_DECK_POOL)]
    local sample = DeckTypes.generate(key, "small")
    if #sample > 0 then out[1] = sample[love.math.random(#sample)] end
    return out
end

-- 打开选牌模态（swap / snatch 的第 1 步、peek3 勾选、chaos 选牌）
function BarMode.barAbilityPickInit(state, id)
    local def = Cocktails.getById(id)
    local ab  = def and def.ability
    if not ab then return false end
    local pick = { id = id, key = ab.key, name = ab.name, step = 1 }

    if ab.key == "peek3" then
        local top = state.deck:peek(3)
        if #top == 0 then return false end
        pick.cards  = top
        pick.marked = {}
    elseif ab.key == "chaos" then
        pick.options = BarMode.barChaosOptions(state)
        if #pick.options == 0 then return false end
    end

    state._barAlcPick       = pick
    state._barAlcOpen       = nil
    state.settingsOpen      = false
    state.deckOverviewOpen  = false
    state.state             = "bar_alcpick"
    return true
end

-- 选牌模态：一次选择（模态内部步骤由 pick.step 推进）
function BarMode.barAbilityPickSelect(state, arg)
    local pick = state and state._barAlcPick
    if not pick then return false end
    local key = pick.key
    local ok
    if key == "peek3" then
        ok = BarMode.barAbilityApply(state, pick.id, { marked = (type(arg) == "table") and arg or {} })
    elseif key == "chaos" then
        if type(arg) ~= "number" then return false end
        ok = BarMode.barAbilityApply(state, pick.id, { index = arg, options = pick.options })
    elseif key == "swap" then
        if pick.step == 1 then
            if type(arg) ~= "number" or not state.player.hand[arg] then return false end
            pick.handIndex = arg
            pick.options   = BarMode.barSwapOptions(state, arg)
            if #pick.options == 0 then return false end
            pick.step = 2
            return true
        end
        if type(arg) ~= "number" then return false end
        ok = BarMode.barAbilityApply(state, pick.id,
            { handIndex = pick.handIndex, index = arg, options = pick.options })
    elseif key == "snatch" then
        if pick.step == 1 then
            if type(arg) ~= "number" or not state.player.hand[arg] then return false end
            pick.handIndex = arg
            pick.step = 2
            return true
        end
        if type(arg) ~= "number" then return false end
        ok = BarMode.barAbilityApply(state, pick.id, { handIndex = pick.handIndex, index = arg })
    else
        return false
    end
    if not ok then return false end

    state.bar.abilitiesUsed[pick.id] = true
    state._barAlcPick = nil
    state.state       = "player"
    BarMode.barAfterAbility(state)
    return true
end

-- 取消选牌：不消耗本小局的使用次数，直接回到玩家回合
function BarMode.barAbilityPickCancel(state)
    if not (state and state._barAlcPick) then return end
    state._barAlcPick = nil
    if state.gameMode == "bar" then state.state = "player" end
end

-- 技能执行（34 款：12 立即 + 4 选牌模态 + 22 立即；选牌类由 barAbilityPickSelect 传入 data）
-- 分发表：key → handler(state, data, hand)。handler 返回 false = 条件不满足（本次不生效），
-- 其余返回值一律视为成功；使用次数落账（abilitiesUsed）在 barAbilityRun。
local BAR_ABILITY_APPLY = {}

-- 重洗：弃掉全部手牌，再抽等量张新牌（牌堆不足时优雅停下）
BAR_ABILITY_APPLY.reshuffle = function(state, data, hand)
    local n = #hand
    if n == 0 then return false end
    BarMode.barEnsureDeck(state)
    for i = n, 1, -1 do barRemoveHandAt(state, hand, i) end
    local drawn = 0
    for _ = 1, n do
        local c = state.deck:drawFor(true)
        if not c then break end
        barAddHandCard(hand, c)
        drawn = drawn + 1
    end
    barAbilityFlash(state, "重洗：弃 " .. n .. " 抽 " .. drawn)
end


-- 换牌：把旧牌换成同牌组的另一张牌面（新牌沿用旧牌花色）
BAR_ABILITY_APPLY.swap = function(state, data, hand)
    local idx  = data and data.handIndex
    local old  = idx and hand[idx]
    local cand = data and data.options and data.index and data.options[data.index]
    if not (old and cand) then return false end
    local new = BarMode.barCloneCard(cand)
    new.suit     = old.suit or new.suit
    new.faceUp   = true
    new._tweened = nil
    new.visual   = nil
    hand[idx]    = new
    state.deck:discard(old)                 -- 旧牌回牌堆底部
    barAbilityFlash(state, "换牌：换掉了 1 张手牌")
end


-- 透牌：把被勾选的牌（牌堆顶 3 张之内）按原相对顺序沉到牌堆底
BAR_ABILITY_APPLY.peek3 = function(state, data, hand)
    local cards = state.deck and state.deck.cards
    if not cards or #cards == 0 then return false end
    local marked = (data and data.marked) or {}
    local moved  = {}
    for i = #cards, 1, -1 do
        if i <= 3 and marked[i] then
            local c = table.remove(cards, i)
            if c then table.insert(moved, 1, c) end    -- 升序收集，保持相对顺序
        end
    end
    for _, c in ipairs(moved) do cards[#cards + 1] = c end
    barAbilityFlash(state, "透牌：沉底 " .. #moved .. " 张")
end


-- 着火：本局牌堆洗牌后只留随机一半（下一小局 barRefillDeck 自动重灌回 80 张）
BAR_ABILITY_APPLY.burn = function(state, data, hand)
    local cards = state.deck and state.deck.cards
    local total = cards and #cards or 0
    if total == 0 then return false end
    state.deck:shuffle()
    local keep = math.max(1, math.floor(total / 2))
    for i = total, keep + 1, -1 do cards[i] = nil end
    barAbilityFlash(state, "着火：烧掉 " .. (total - keep) .. " 张，牌堆剩 " .. keep .. " 张")
end


-- 双份：复制点数最低的一张手牌（并列取最后一张）
BAR_ABILITY_APPLY.dup = function(state, data, hand)
    local n = #hand
    if n == 0 or n >= HAND_MAX then return false end
    local bestIdx, bestVal = nil, nil
    for i = 1, n do
        local v = barCardScore(hand[i])
        if bestVal == nil or v <= bestVal then bestIdx, bestVal = i, v end
    end
    local copy = BarMode.barCloneCard(hand[bestIdx])
    barAddHandCard(hand, copy)
    barAbilityFlash(state, "双份：复制了点数最低的一张手牌")
end


-- 封口：本局庄家立即停牌（标记在 barResetRoundFields 里清空）
BAR_ABILITY_APPLY.seal = function(state, data, hand)
    state._barDealerSealed = true
    barAbilityFlash(state, "封口：酒保本局停牌")
end


-- 加冰（降级口径）：弃掉点数最高的一张手牌（并列取最后一张）
BAR_ABILITY_APPLY.chill = function(state, data, hand)
    local n = #hand
    if n == 0 then return false end
    local bestIdx, bestVal = nil, nil
    for i = 1, n do
        local v = barCardScore(hand[i])
        if bestVal == nil or v >= bestVal then bestIdx, bestVal = i, v end
    end
    barRemoveHandAt(state, hand, bestIdx)
    barAbilityFlash(state, "加冰：弃掉点数最高的一张手牌")
end


-- 掉包：自己的 1 张手牌 与 酒保的 1 张「明牌」（下标 >= 2）互换
BAR_ABILITY_APPLY.snatch = function(state, data, hand)
    local pIdx  = data and data.handIndex
    local dIdx  = data and data.index
    local pCard = pIdx and hand[pIdx]
    local dCard = dIdx and state.dealer.hand[dIdx]
    if not (pCard and dCard) or dIdx < 2 then return false end
    table.remove(hand, pIdx)
    table.remove(state.dealer.hand, dIdx)
    pCard._tweened = nil; pCard.visual = nil; pCard.faceUp = true
    state.dealer.hand[#state.dealer.hand + 1] = pCard      -- 自己的牌 → 酒保明牌
    dCard._tweened = nil; dCard.visual = nil; dCard.faceUp = true
    table.insert(hand, pIdx, dCard)                        -- 酒保那张 → 自己的原位
    barAbilityFlash(state, "掉包：换走了酒保的 1 张明牌")
end


-- 弃牌：随机弃掉 1 张手牌
BAR_ABILITY_APPLY.discard = function(state, data, hand)
    local n = #hand
    if n == 0 then return false end
    barRemoveHandAt(state, hand, love.math.random(n))
    barAbilityFlash(state, "弃牌：随机弃掉 1 张手牌")
end


-- 错乱：从冠军牌组挑一张打进手牌（深拷贝，绝不塞本体）
BAR_ABILITY_APPLY.chaos = function(state, data, hand)
    local cand = data and data.options and data.index and data.options[data.index]
    if not cand then return false end
    if #hand >= HAND_MAX then return false end
    local Champion = require("src.champion")
    barAddHandCard(hand, Champion.cloneCard(cand))
    barAbilityFlash(state, "错乱：从冠军牌组打进 1 张")
end


-- 移花：抽走酒保点数最大的一张明牌（下标 >= 2），沉到牌堆底
BAR_ABILITY_APPLY.take = function(state, data, hand)
    local dHand = state.dealer.hand
    if #dHand < 2 then return false end
    local bestIdx, bestVal = nil, nil
    for i = 2, #dHand do
        local v = barCardScore(dHand[i])
        if bestVal == nil or v >= bestVal then bestIdx, bestVal = i, v end
    end
    if not bestIdx then return false end
    local c = table.remove(dHand, bestIdx)
    c._tweened = nil; c.visual = nil
    state.deck:discard(c)
    barRefillDealerUpCard(state)          -- 移走即补：酒保立刻补 1 张新明牌（净明牌数不变）
    barAbilityFlash(state, "移花：抽走酒保 1 张明牌沉底")
end


-- 弹走：把点数最小的一张手牌弹给酒保（并列取最后一张）
BAR_ABILITY_APPLY.flick = function(state, data, hand)
    local n = #hand
    if n == 0 then return false end
    local bestIdx, bestVal = nil, nil
    for i = 1, n do
        local v = barCardScore(hand[i])
        if bestVal == nil or v <= bestVal then bestIdx, bestVal = i, v end
    end
    local c = table.remove(hand, bestIdx)
    if not c then return false end
    c._tweened = nil; c.visual = nil; c.faceUp = true
    state.dealer.hand[#state.dealer.hand + 1] = c
    barAbilityFlash(state, "弹走：最小的一张手牌弹给了酒保")
end


-- ============================================================
-- 后 22 款技能（全部立即生效；A=改明牌数 / B=强制抽牌 / C=改牌库）
-- 通用约束：补牌走 barEnsureDeck + drawFor(true) + barAddHandCard；
--           「移走即补」一律复用 barRefillDealerUpCard；随机只用 love.math.random。
-- ============================================================

-- ===== 方向 A：改变庄家明牌数量 =====
-- 胡闹：庄家最后一张明牌沉底 + 立刻补 1 张（复用「移走即补」，净明牌数不变）

BAR_ABILITY_APPLY.foolish = function(state, data, hand)
    local dHand = state.dealer.hand
    if #dHand < 2 then return false end
    local c = table.remove(dHand, #dHand)
    if not c then return false end
    c._tweened = nil; c.visual = nil
    state.deck:discard(c)
    barRefillDealerUpCard(state)
    barAbilityFlash(state, "胡闹：最后一张明牌沉底，已补 1 张")
end


-- 戏法：为庄家额外发 1 张明牌
BAR_ABILITY_APPLY.magic = function(state, data, hand)
    local dHand = state.dealer.hand
    if #dHand >= HAND_MAX then return false end
    BarMode.barEnsureDeck(state)
    if not barAddHandCard(dHand, state.deck:drawFor(true)) then return false end
    barAbilityFlash(state, "戏法：庄家多了 1 张明牌")
end


-- 低语：庄家点数最小的明牌沉底 + 立刻补 1 张（复用「移走即补」，净明牌数不变）
BAR_ABILITY_APPLY.hush = function(state, data, hand)
    local dHand = state.dealer.hand
    if #dHand < 2 then return false end
    local minIdx, minVal = nil, nil
    for i = 2, #dHand do
        local v = barCardScore(dHand[i])
        if minVal == nil or v < minVal then minIdx, minVal = i, v end
    end
    if not minIdx then return false end
    local c = table.remove(dHand, minIdx)
    c._tweened = nil; c.visual = nil
    state.deck:discard(c)
    barRefillDealerUpCard(state)
    barAbilityFlash(state, "低语：最小明牌沉底，已补 1 张")
end


-- 加冕：明牌不足 2 张补到 2 张（只补不收）
BAR_ABILITY_APPLY.crown = function(state, data, hand)
    local dHand = state.dealer.hand
    local added = 0
    while #dHand - 1 < 2 and #dHand < HAND_MAX do
        BarMode.barEnsureDeck(state)
        local c = state.deck:drawFor(true)
        if not c then break end
        barAddHandCard(dHand, c)
        added = added + 1
    end
    if added == 0 then return false end
    barAbilityFlash(state, "加冕：为庄家补了 " .. added .. " 张明牌")
end


-- 结对：复制庄家的最后一张明牌（明牌 +1）
BAR_ABILITY_APPLY.pairing = function(state, data, hand)
    local dHand = state.dealer.hand
    if #dHand < 2 or #dHand >= HAND_MAX then return false end
    local copy = BarMode.barCloneCard(dHand[#dHand])
    copy.faceUp = true
    if not barAddHandCard(dHand, copy) then return false end
    barAbilityFlash(state, "结对：复制了庄家的最后一张明牌")
end


-- 潮汐：补牌直到明牌数与你的手牌数相同（只补不收）
BAR_ABILITY_APPLY.tide = function(state, data, hand)
    local dHand = state.dealer.hand
    local target = #hand
    local added = 0
    while #dHand - 1 < target and #dHand < HAND_MAX do
        BarMode.barEnsureDeck(state)
        local c = state.deck:drawFor(true)
        if not c then break end
        barAddHandCard(dHand, c)
        added = added + 1
    end
    if added == 0 then return false end
    barAbilityFlash(state, "潮汐：为庄家补了 " .. added .. " 张明牌")
end


-- 炽热：为庄家每张明牌各补 1 张（明牌数翻倍，受 HAND_MAX 防护）
BAR_ABILITY_APPLY.blaze = function(state, data, hand)
    local dHand = state.dealer.hand
    local dFace = #dHand - 1
    if dFace < 1 or #dHand >= HAND_MAX then return false end
    local added = 0
    for _ = 1, dFace do
        if #dHand >= HAND_MAX then break end
        BarMode.barEnsureDeck(state)
        local c = state.deck:drawFor(true)
        if not c then break end
        barAddHandCard(dHand, c)
        added = added + 1
    end
    if added == 0 then return false end
    barAbilityFlash(state, "炽热：为庄家每张明牌各补 1 张（+" .. added .. "）")
end


-- 环球：明牌不足 3 张补到 3 张（只补不收）
BAR_ABILITY_APPLY.globe = function(state, data, hand)
    local dHand = state.dealer.hand
    local added = 0
    while #dHand - 1 < 3 and #dHand < HAND_MAX do
        BarMode.barEnsureDeck(state)
        local c = state.deck:drawFor(true)
        if not c then break end
        barAddHandCard(dHand, c)
        added = added + 1
    end
    if added == 0 then return false end
    barAbilityFlash(state, "环球：为庄家补了 " .. added .. " 张明牌")
end


-- ===== 方向 B：强制庄家抽牌 =====
-- 律令：强制庄家立即抽 1 张明牌

BAR_ABILITY_APPLY.decree = function(state, data, hand)
    local dHand = state.dealer.hand
    if #dHand >= HAND_MAX then return false end
    BarMode.barEnsureDeck(state)
    if not barAddHandCard(dHand, state.deck:drawFor(true)) then return false end
    barAbilityFlash(state, "律令：庄家抽了 1 张明牌")
end


-- 布道：强制庄家立即抽 2 张明牌
BAR_ABILITY_APPLY.sermon = function(state, data, hand)
    local dHand = state.dealer.hand
    if #dHand + 2 > HAND_MAX then return false end
    local added = 0
    for _ = 1, 2 do
        BarMode.barEnsureDeck(state)
        local c = state.deck:drawFor(true)
        if not c then break end
        barAddHandCard(dHand, c)
        added = added + 1
    end
    if added == 0 then return false end
    barAbilityFlash(state, "布道：庄家抽了 " .. added .. " 张明牌")
end


-- 冲锋：强制庄家抽 2 张明牌，然后本局庄家停牌（复用「封口」的既有通道）
BAR_ABILITY_APPLY.charge = function(state, data, hand)
    local dHand = state.dealer.hand
    if #dHand + 2 > HAND_MAX then return false end
    local added = 0
    for _ = 1, 2 do
        BarMode.barEnsureDeck(state)
        local c = state.deck:drawFor(true)
        if not c then break end
        barAddHandCard(dHand, c)
        added = added + 1
    end
    if added == 0 then return false end
    state._barDealerSealed = true
    barAbilityFlash(state, "冲锋：庄家抽了 " .. added .. " 张并本局停牌")
end


-- 蛮力：庄家抽 1 张明牌，再从你手牌随机抽 1 张塞给庄家当明牌
-- 手牌被抽空是预期副作用；手牌为空时判据已拦下，这里按字段规格重置
BAR_ABILITY_APPLY.brute = function(state, data, hand)
    local dHand = state.dealer.hand
    if #hand == 0 or #dHand + 2 > HAND_MAX then return false end
    BarMode.barEnsureDeck(state)
    local drawn = state.deck:drawFor(true)
    if not drawn then return false end
    barAddHandCard(dHand, drawn)
    local idx = love.math.random(#hand)
    local c = table.remove(hand, idx)
    if not c then return false end
    c._tweened = nil; c.visual = nil; c.faceUp = true
    dHand[#dHand + 1] = c
    barAbilityFlash(state, "蛮力：庄家多 1 张明牌，你的手牌少了 1 张")
end


-- 悬挂：庄家点数最小的明牌与牌堆顶交换（互换不是移走，不触发补牌）
BAR_ABILITY_APPLY.hang = function(state, data, hand)
    local dHand = state.dealer.hand
    local cards = state.deck and state.deck.cards
    if #dHand < 2 or not cards or #cards == 0 then return false end
    local minIdx, minVal = nil, nil
    for i = 2, #dHand do
        local v = barCardScore(dHand[i])
        if minVal == nil or v < minVal then minIdx, minVal = i, v end
    end
    if not minIdx then return false end
    local top = table.remove(cards)          -- 牌堆顶 = drawFor 的取牌端
    local old = dHand[minIdx]
    top._tweened = nil; top.visual = nil; top.faceUp = true
    dHand[minIdx] = top                      -- 牌堆顶那张成为庄家新明牌
    old._tweened = nil; old.visual = nil; old.faceUp = false
    cards[#cards + 1] = old                  -- 庄家那张被顶到牌堆顶
    barAbilityFlash(state, "悬挂：庄家的最小明牌与牌堆顶交换了")
end


-- 终末：强制庄家立即抽 3 张明牌
BAR_ABILITY_APPLY.doom = function(state, data, hand)
    local dHand = state.dealer.hand
    if #dHand + 3 > HAND_MAX then return false end
    local added = 0
    for _ = 1, 3 do
        BarMode.barEnsureDeck(state)
        local c = state.deck:drawFor(true)
        if not c then break end
        barAddHandCard(dHand, c)
        added = added + 1
    end
    if added == 0 then return false end
    barAbilityFlash(state, "终末：庄家抽了 " .. added .. " 张明牌")
end


-- 诱引：庄家抽 1 张明牌，且该张必为牌堆中点数最大的那张
BAR_ABILITY_APPLY.tempt = function(state, data, hand)
    local dHand = state.dealer.hand
    local cards = state.deck and state.deck.cards
    if #dHand >= HAND_MAX or not cards or #cards == 0 then return false end
    local bestIdx, bestVal = nil, nil
    for i = 1, #cards do
        local v = barCardScore(cards[i])
        if bestVal == nil or v > bestVal then bestIdx, bestVal = i, v end
    end
    if not bestIdx then return false end
    local c = table.remove(cards, bestIdx)
    if not barAddHandCard(dHand, c) then
        cards[#cards + 1] = c                -- 兜底：塞不回去就放回牌堆顶
        return false
    end
    barAbilityFlash(state, "诱引：庄家拿到了牌堆里点数最大的那张")
end


-- 崩塌：庄家连续抽牌直到点数 >= 21；张数上限 HAND_MAX 防护
-- （酒吧牌池含 0 点与负点牌，无上限会无限抽死；到上限正常收尾不抛错）
BAR_ABILITY_APPLY.collapse = function(state, data, hand)
    local dHand = state.dealer.hand
    local added = 0
    while Blackjack.calculateHand(dHand) < 21 and #dHand < HAND_MAX do
        BarMode.barEnsureDeck(state)
        local c = state.deck:drawFor(true)
        if not c then break end
        barAddHandCard(dHand, c)
        added = added + 1
    end
    if added == 0 then return false end
    barAbilityFlash(state, "崩塌：庄家连抽了 " .. added .. " 张")
end


-- ===== 方向 C：改变牌库构成 =====
-- 清算：本局牌堆按点数从小到大排序

BAR_ABILITY_APPLY.reckon = function(state, data, hand)
    local cards = state.deck and state.deck.cards
    if not cards or #cards == 0 then return false end
    table.sort(cards, function(a, b) return barCardScore(a) < barCardScore(b) end)
    barAbilityFlash(state, "清算：牌堆已按点数从小到大排好")
end


-- 独酌：牌堆顶 5 张整块沉到牌堆底（不足 5 张沉现有的全部）
BAR_ABILITY_APPLY.solitude = function(state, data, hand)
    local cards = state.deck and state.deck.cards
    if not cards or #cards == 0 then return false end
    local n = math.min(5, #cards)
    for _ = 1, n do
        local c = table.remove(cards)        -- 顶（数组末尾）
        table.insert(cards, 1, c)            -- 底（数组开头），整块相对顺序不变
    end
    barAbilityFlash(state, "独酌：顶上 " .. n .. " 张沉到了牌堆底")
end


-- 轮转：用模板重灌整副牌堆并重新洗牌（barRefillDeck 内部 addCards 即洗牌）
BAR_ABILITY_APPLY.revolve = function(state, data, hand)
    BarMode.barRefillDeck(state)
    barAbilityFlash(state, "轮转：牌堆已重灌并重新洗过")
end


-- 调和：随机删 10 张，牌堆剩余不少于 BAR_MIN_CARDS（本局有效，下一小局重灌恢复）
BAR_ABILITY_APPLY.temper = function(state, data, hand)
    local cards = state.deck and state.deck.cards
    if not cards or #cards <= BAR_MIN_CARDS then return false end
    local removeN = math.min(10, #cards - BAR_MIN_CARDS)
    for _ = 1, removeN do
        table.remove(cards, love.math.random(#cards))
    end
    barAbilityFlash(state, "调和：删掉了 " .. removeN .. " 张，牌堆剩 " .. #cards .. " 张")
end


-- 祈愿：往牌堆随机位置插入 5 张 10 点牌
-- 结构完整：合法 suit/rank + value=10 + isSpecial + 临时标记 is_wish，
-- 否则绘制到这张牌时 card.rank .. card.suit 会因字段缺失崩在渲染层
BAR_ABILITY_APPLY.wish = function(state, data, hand)
    local cards = state.deck and state.deck.cards
    if not cards then return false end
    local suits = { "\u{2660}", "\u{2665}", "\u{2666}", "\u{2663}" }
    for i = 1, 5 do
        local c = {
            suit = suits[(i - 1) % 4 + 1], rank = "10", value = 10, faceUp = false,
            kind = "wish10", isSpecial = true, mult_bonus = 0,
            is_wish = true,                  -- 可识别的临时标记（本局有效）
        }
        local pos = (#cards > 0) and love.math.random(#cards + 1) or 1
        table.insert(cards, pos, c)
    end
    barAbilityFlash(state, "祈愿：牌堆里多了 5 张 10 点牌")
end


-- 末日：本局牌堆压缩为点数最大的一半（剩余不少于 BAR_MIN_CARDS；本局有效）
-- 同点数按原下标稳定排序，保留原相对顺序 —— 同种子两次运行结果一致
BAR_ABILITY_APPLY.verdict = function(state, data, hand)
    local cards = state.deck and state.deck.cards
    if not cards or #cards <= BAR_MIN_CARDS then return false end
    local keepN = math.max(BAR_MIN_CARDS, math.floor(#cards / 2))
    local order = {}
    for i, c in ipairs(cards) do order[i] = { v = barCardScore(c), i = i } end
    table.sort(order, function(a, b)
        if a.v ~= b.v then return a.v > b.v end
        return a.i < b.i
    end)
    local keep = {}
    for k = 1, keepN do keep[order[k].i] = true end
    local removedN = 0
    for i = #cards, 1, -1 do
        if not keep[i] then
            table.remove(cards, i)
            removedN = removedN + 1
        end
    end
    barAbilityFlash(state, "末日：压缩掉了 " .. removedN .. " 张，剩 " .. #cards .. " 张")
end


-- 统一入口：id → 技能 key → 查表分发；hand 守卫与原实现一致（nil 即不生效）
function BarMode.barAbilityApply(state, id, data)
    local def = Cocktails.getById(id)
    local key = def and def.ability and def.ability.key
    if not key then return false end
    local fn = BAR_ABILITY_APPLY[key]
    if not fn then return false end
    local hand = state.player and state.player.hand
    if not hand then return false end
    if fn(state, data, hand) == false then return false end
    return true
end

-- 入口：点列表里的某一项（立即技能直接执行；需选牌的技能打开模态）
function BarMode.barAbilityRun(state, id)
    if not BarMode.barAbilityUsable(state, id) then return false end
    local def = Cocktails.getById(id)
    local ab  = def and def.ability
    if not ab then return false end
    if ab.pick then return BarMode.barAbilityPickInit(state, id) end
    if not BarMode.barAbilityApply(state, id) then return false end

    state.bar.abilitiesUsed[id] = true
    state._barAlcOpen = nil              -- 执行成功 → 展开列表自动关闭
    state.state       = "player"
    BarMode.barAfterAbility(state)
    return true
end

-- 统一收尾：重算玩家点数（UI 每帧重算，此处只需判爆牌）→ 已爆牌走爆牌路径 → 否则继续玩家回合
function BarMode.barAfterAbility(state)
    if not (state and state.gameMode == "bar" and state.bar) then return end
    local total = Blackjack.calculateHand(state.player.hand)
    if total > 21 then
        return GS.endRound(state)      -- 等价 standPlayer 的爆牌路径
    end
    state.state = "player"
end

-- ============================================================
-- 局末流程：倒计时 → 概率累加 → 喝酒 → 失败 / 结局
-- ============================================================
function BarMode._barAfterScoring(state, details)
    local bar = state.bar
    if not bar then return end
    bar.lastResult = details.result

    if details.result == "player" then
        bar.winCount = bar.winCount + 1
    elseif details.result == "dealer" then
        bar.loseCount = bar.loseCount + 1
    end

    -- 醉酒倒计时：每小局无条件递减一次（旧版的酒被动差异已随主动技能改版废除）
    local expired = Cocktails.tickDown(state)
    bar.lastResult = nil
    -- 有酒在本小局到期 → 下一小局宿醉：全场手牌模糊 + 该酒颜色的全屏淡色滤镜
    if #expired > 0 then
        bar.hangoverRound = bar.round + 1
        bar.hangoverColor = Cocktails.blendColors(expired)
    end

    if details.result == "player" then
        -- 概率累加：每胜 +0.5%
        bar.prob = bar.prob + BAR_PROB_PER_WIN

        -- 酒保文本框：赢下一小局换一条科普短句
        -- 科普口径 = 「当前已有的酒」并集（调酒栏杯子 id + 生效中 buffs key）；
        -- 并集为空时 nextTrivia 内部回退通用池。
        local triviaIds = {}
        for _, cup in ipairs(bar.cups) do triviaIds[#triviaIds + 1] = cup.id end
        for id in pairs(bar.buffs) do triviaIds[#triviaIds + 1] = id end
        bar.boilerLine = BarLines.nextTrivia(triviaIds)
    end

    -- 栏已空 → 直接失败（理论上前一小局就应拦下，这里兜底）
    if #bar.cups == 0 then return BarMode.barFail(state) end

    -- ===== 输一局必须喝一口 =====
    if details.result == "dealer" then
        if #bar.cups <= 1 then
            BarMode.barDrink(state, 1, 1, "loss")        -- 只有一杯：直接喝
        else
            bar.drinkAmount = 1
            bar.drinkReason = "loss"
            state._barDrinkOpen = true
            state.settingsOpen = false
            state.deckOverviewOpen = false
            state.state = "bar_drink"                      -- 未选择前不推进
            return
        end
    end

    BarMode.barAfterDrink(state)
end

return BarMode
