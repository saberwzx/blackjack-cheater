-- ============================================================
-- GameState — 游戏状态管理（基础 / 困难模式的核心规则层）
--
-- 状态机: relic_select → bet → player → dealer → result → shop → bet → ...
-- 阶段系统 + 作弊系统 + 反出千
--
-- 本文件分层（自上而下）:
--   1. 常量与模块引用
--   2. 开局 / 周目（new、startNewGame、startTutorial）
--   3. 小局生命周期（resetRound、placeBet、dealInitial、hit/stand/double、
--      dealerAction、accuseDealer、endRound、_doScoring、checkBrokeNow）
--   4. 标记系统（墨水标记 + 特种标记：tryMarkCard、mark*At、discoverMark）
--   5. 钓具 / 揭示 / 弃牌堆道具（rod*、salvage、backflow、rinse）
--   6. 商店 / 铸造 / 牌组注入（buyRelic、buyDeck、rerollShop、forge*、rebuildShoe）
--   7. 遗物事件注册与职阶（registerAllRelics、toggleRelicActive、classOffer）
--   8. 视觉辅助（updateVisuals）
-- 酒吧模式已整体拆到 src/bar_mode.lua（本文件末尾注册回 GameState 表）。
-- ============================================================

local GameState = {}
local EventManager = require("src.event_manager")
local Deck = require("src.deck")
local Blackjack = require("src.blackjack")
local Relics = require("src.relics")
local Scoring = require("src.scoring")
local Sfx = require("src.sfx")
local Cocktails = require("src.cocktails")
local BarLines = require("src.bar_lines")
local BarMode = require("src.bar_mode")

-- ========== 具名常量（不得散成魔法数字） ==========
local HAND_MAX = 12              -- 玩家/庄家手牌上限
local FLASH_DURATION = 2.0       -- 提示文字显示时间（秒）
local MARKS_MAX = 5              -- 同时存在的实体标记上限
local MARK_DISCOVERY = 0.02      -- 庄家要牌时发现墨水牌的概率（每次要牌判定）
local MARK_FINE_MULT = 3         -- 被发现时的罚金倍数（×当局下注）
-- 标记费用（按阶段）：花筹码买标记，取代旧墨水点数
local MARK_COST = { [1] = 50, [2] = 200, [3] = 1000 }
local BUST_BET_FRACTION = 0.5    -- 爆注额 = 主注的一半
local BUST_BET_EDGE = 0.9        -- 庄家抽水（赔率 = 0.9/爆率）
local BUST_BET_MIN_ODDS = 1.2    -- 爆注赔率上下限
local BUST_BET_MAX_ODDS = 8.0

GameState.MARKS_MAX = MARKS_MAX
GameState.MARK_COST = MARK_COST
GameState.MARK_DISCOVERY = MARK_DISCOVERY
GameState.MARK_FINE_MULT = MARK_FINE_MULT

-- 牢笼判定：该方「明牌最末尾」是否为牢笼牌
-- 明牌最末尾 = 手牌里最后一张 faceUp 的牌（庄家 hand[1] 是暗牌，不算）
-- 开局就发到的牢笼牌（_cageImmune）不算，封锁只认之后抽到的牌
local function isCageLocked(hand)
    if not hand then return false end
    for i = #hand, 1, -1 do
        local c = hand[i]
        if c and c.faceUp then
            return c.is_cage == true and not c._cageImmune
        end
    end
    return false
end

-- ============================================================
-- 创建全新游戏状态
-- ============================================================
function GameState.new()
    local state = setmetatable({}, GameState)

    state.events = EventManager.new()
    state.deck = Deck.new(1)
    state.relics = {}
    state.turn = 1
    state.roundsPlayed = 0   -- 本周目已打的小局数（最快通关纪录口径）

    -- 阶段系统: 3 阶段
    state.stage = 1
    state.stageEveryN = { [1] = 15, [2] = 15, [3] = 30 }
    state.roundsInStage = 0
    state.stageMinChips = { [1] = 2000, [2] = 20000, [3] = 2000000 }
    state.stageDifficulty = { [1] = 1, [2] = 2, [3] = 3 }
    state.stageName = { [1] = "新手赌场", [2] = "老练赌场", [3] = "黑暗赌场" }
    -- 换靴难度阶梯：副数随阶段上升 = 计数越来越难（基础规模 1 套起步）
    state.stageDeckNum = { [1] = 1, [2] = 2, [3] = 3 }

    -- 职阶系统（阶段 3 才会选）
    state.class = nil
    state.classCharges = 0           -- Rider 剩余跳过次数
    state.classOffer = nil           -- Caster 替换面板的 3 个候选遗物
    state.classOfferActive = false   -- Caster 替换面板是否打开
    state.classOfferTarget = nil     -- Caster 面板：玩家选中要替换的自己的遗物
    state._afterClassOffer = nil     -- Caster 面板关闭后回到的状态（result / shop）
    state._archer_preview = false    -- Archer 预览标记（下注时打上，发牌时读取）

    -- 游戏模式（"basic" 或 "hard"）— 困难模式庄家也有职阶
    state.gameMode = nil
    state.dealerClass = nil
    state.dealerCharges = 0
    state.dealerStreak = 0
    state.dealerRelics = {}    -- 庄家 Caster 持有的遗物（简化：名字列表）

    -- 作弊概率（阶段决定）；base 为只读基准，遗物改的是 cheatChance
    state.cheatChanceBase = { [1] = 0.0, [2] = 0.20, [3] = 0.45 }
    state.cheatChance = { [1] = 0.0, [2] = 0.20, [3] = 0.45 }

    state.player = { chips = 2500, bet = 0, hand = {} }
    state.dealer = { hand = {} }

    state.state = "relic_select"
    state.result = nil
    state.lastScoreDetails = nil
    state.quitTimer = 0
    state.exitReason = ""

    -- 设置（ESC 页）
    state.settings = {
        volume = 0.6,          -- 0.0 ~ 1.0
        resolutionIndex = 1,   -- 对应 UI.RESOLUTIONS
        fullscreen = false,
        autoEndOnBroke = true, -- 筹码耗尽 → 回标题界面（默认打开）
    }
    state.settingsOpen = false

    -- 临时提示（如"手牌已满"）— 2 秒自动消失
    state._flashMsg = nil     -- { text = string, expires = time }
    state.streak = 0
    state.firstHitThisRound = false

    -- 牌靴情报（BlackJacky 信息层 v1）
    state._shoePeek = 0          -- 本轮窥视深度（窥牌遗物点亮时设置，resetRound 清）
    state._shoeInfoOpen = false  -- 牌靴情报面板（UI 模态，与 deckOverview 同级互斥）

    -- 标签系统：实体标记（花筹码购买，无点数资源）
    state.shoeMarks = {}   -- [{uid, seen, rank, suit, at}] 锚定实体牌（uid）

    -- 阶段3：加倍 / 爆注 / 变化节拍
    state._doubled = nil       -- 本小局是否加倍（结算展示用）
    state._bustBetOn = false   -- 爆注开关（跨小局粘滞）
    state._bustBet = 0         -- 本小局爆注额
    state._bustBetOdds = nil   -- 发牌时锁定的赔率
    state._pendingShoe = nil   -- 阶段切换后待执行的换靴节拍

    -- 作弊状态（每轮开始时决定）
    state.cheatState = {
        isCheating = false,
        cheatType = 0,        -- 0=不作弊, 1=暗牌换BJ, 2=抽牌必10, 3=低牌换掉
        visualTell = false,   -- 本小局是否有可见表现（真痕迹或干扰项），不再等于 isCheating
        wasAccused = false,   -- 玩家是否指认过
        cheatExecuted = false, -- 作弊是否「实际执行」（三招真正改动手牌/牌堆时才置真）
        cheatTellKind = nil,   -- "A"/"B"/"C"=与招式绑定的真痕迹, "dA"/"dB"/"dC"=干扰项, nil=无表现
    }
    state._distractorShown = nil    -- 干扰项：每小局最多物化一次
    state._stage2BriefOpen = false  -- 阶段 2 说明弹窗是否打开（模态，纯阅读）
    state._stage2BriefShown = false -- 每次新游戏内只弹一次（仅 startNewGame 清）

    -- 反出千结果
    state.accuseResult = nil   -- "correct" / "wrong" / nil

    -- 遗物相关
    state.pendingRelics = nil
    state.shopOfferings = nil
    state.shopRerollCost = 200       -- 初始 200，每次刷新翻倍
    state.shopEveryN = 5
    state.roundsSinceShop = 0

    -- 牌组系统
    state.deckCollections = {}          -- 购买的牌组历史 [{label, count, cards}]
    state.shopDeckOfferings = nil       -- 商店里的牌组 offer
    state.lastDeckAddAnim = nil         -- 加牌动画状态
    state._baseDecks = 1                -- 固有牌堆初始套数（规模缩小：1 套 52 张）
    state._removedDecks = 0             -- 累计删除的套数

    -- 酒吧模式（gameMode == "bar"）—— 详见文件末尾的「酒吧模式」段落
    state.bar            = GameState.newBarState()
    state._barBriefOpen  = false
    state._barBriefShown = false
    state._barBriefPage  = nil           -- 说明弹窗当前页（1/2；nil = 未打开）
    state._barBriefReopen = false        -- true = 从「说明」入口重看（关闭后回 player，不推进小局）
    state.barEnding      = nil           -- "date" / "fish" / "buddy"

    -- 视觉爽感数据
    state.scorePopups = {}
    state.screenShake = 0

    -- 初始状态: 主菜单
    state.state = "title"

    GameState.registerAllRelics(state)
    return state
end

-- ============================================================
-- 遗物注册
-- ============================================================
function GameState.registerAllRelics(state)
    state.events:clear()
    for i, relic in ipairs(state.relics) do
        -- 新遗物（active==nil）默认不激活，除非 pre-game 事件或 auto_active
        if relic.active == nil then
            relic.active = Relics.isPreGame(relic) or relic.auto_active or false
        end
        if relic.triggers then
            for _, eventName in ipairs(relic.triggers) do
                local lid = relic.id .. "_" .. i
                local isPreGameEvent = Relics.PRE_GAME_EVENTS[eventName]
                state.events:on(eventName, lid, function(ctx)
                    if relic._expired then return nil end   -- 次数耗尽：当轮剩余时间也不再生效
                    -- 拦截：pre-game 事件 / auto_active 遗物直接放行；其他需要 active==true
                    if not isPreGameEvent and not relic.active and not relic.auto_active then
                        return nil
                    end
                    local ok, ret = pcall(relic.effect, ctx)
                    if not ok then
                        print(string.format("[Relic %s] 错误: %s", relic.id, tostring(ret)))
                        return nil
                    end
                    -- 一次性防护类：effect 真的生效了就减次数
                    if relic._consumable then
                        local triggered = false
                        if ret ~= nil then triggered = true end
                        -- 有些不 return，直接改 ctx — 检测 ctx 变化
                        if not triggered and eventName == "on_score_calc" then
                            if ctx.become_bust == false or ctx.force_win then triggered = true end
                        end
                        if not triggered and eventName == "on_hit" then
                            -- 只认本遗物自己打上的标记，避免被别的遗物设置的 force_draw_card 误判为"已生效"
                            if ctx.safe_hit or ctx._give_card_triggered then triggered = true end
                        end
                        -- 算牌师：on_round_start 自动亮牌必然生效。
                        -- resetRound 对 ROUND_START 触发两次（开头一次 + state="bet" 后一次），
                        -- 效果是 max 幂等无所谓，扣次必须按小局去重（turn 每小局 +1）
                        if not triggered and eventName == "on_round_start" and relic.id == "peek_auto" then
                            local g = ctx.game
                            if g and relic._lastPeekTurn ~= g.turn then
                                relic._lastPeekTurn = g.turn
                                triggered = true
                            end
                        end
                        if triggered then
                            relic._usesLeft = (relic._usesLeft or 3) - 1
                            if relic._usesLeft <= 0 then
                                relic._expired = true
                            end
                        end
                    end
                    return ret
                end, 50 + i)
            end
        end
    end
end

function GameState.toggleRelicActive(state, relicIndex)
    local relic = state.relics and state.relics[relicIndex]
    if not relic then return false end
    if Relics.isPreGame(relic) then return false end  -- pre-game 事件遗物不能 toggle（它们不读 active）
    if relic.auto_active then return false end         -- 自动激活的不能 toggle
    if relic._consumable and relic._expired then
        state._flashMsg = {
            text    = "该遗物次数已用完",
            expires = love.timer.getTime() + FLASH_DURATION,
        }
        return false
    end
    -- 铸造后的窥牌遗物：每小局自动点亮（resetRound），无需也无法手动 toggle
    if relic._forged and (relic.id == "peek_1" or relic.id == "peek_2" or relic.id == "peek_3" or relic.id == "far_sight") then
        return false
    end
    -- 玩家回合 / 下注阶段都可点亮（职阶残卷必须在下注前点亮才赶得上发牌时机）
    if state.state ~= "player" and state.state ~= "bet" then return false end

    relic.active = not relic.active

    -- 再点一次关闭 = 解除武装（钓具 / 打捞）
    if not relic.active then
        if state._rodArmed and state._rodArmed.relic == relic then state._rodArmed = nil end
        if state._salvagerArmed == relic then state._salvagerArmed = nil end
    end

    -- 移动网络：点亮即开店（一次性消耗，发动成功后本小局结束即从遗物栏消失）
    if relic.id == "mobile_network" and relic.active then
        local opened = GameState.openPlayerShop(state)
        relic.active = false
        if opened then
            if relic._consumable then
                relic._usesLeft = (relic._usesLeft or 1) - 1
                if relic._usesLeft <= 0 then
                    relic._expired = true
                end
            end
        else
            state._flashMsg = {
                text    = "移动网络：本小局已经发动过了",
                expires = love.timer.getTime() + FLASH_DURATION,
            }
        end
    end

    -- ===== 牌靴情报组（点亮即生效）=====
    if relic.active and (relic.id == "peek_1" or relic.id == "peek_2" or relic.id == "peek_3" or relic.id == "far_sight") then
        local depth = (relic.id == "peek_1") and 1 or (relic.id == "peek_2") and 2
            or (relic.id == "peek_3") and 3 or 5   -- 千里眼：一次亮明 5 张
        if GameState.hasRelic(state, "mind_memory") then depth = depth + 1 end   -- 过目不忘：窥视 +1
        state._shoePeek = math.max(state._shoePeek or 0, depth)
        GameState.markRelicRoundActive(state, relic.id)
        state._flashMsg = {
            text    = "窥视：接下来 " .. depth .. " 张已亮明（按 I 查看）",
            expires = love.timer.getTime() + FLASH_DURATION,
        }
        -- 窥牌 3 次限制：点亮成功扣 1 次（铸造后的窥牌在上面已被拦截，不会走到这里）
        if relic._consumable then
            relic._usesLeft = (relic._usesLeft or 3) - 1
            if relic._usesLeft <= 0 then
                relic._expired = true
            end
        end
    elseif relic.active and (relic.id == "burn_1" or relic.id == "burn_3") then
        local n = (relic.id == "burn_1") and 1 or 3
        local burned = GameState.burnTopCards(state, n)
        relic.active = false
        if burned > 0 then
            GameState.markRelicRoundActive(state, relic.id)
            if relic._consumable then
                relic._usesLeft = (relic._usesLeft or 1) - 1
                if relic._usesLeft <= 0 then
                    relic._expired = true
                end
            end
        end
    end

    -- ===== 钓具组（点亮即武装 / 发动，每回合限 1 次）=====
    if relic.active and relic.rod then
        if state._rodUsedRound then
            relic.active = false
            state._flashMsg = {
                text    = "钓具每回合只能用一次",
                expires = love.timer.getTime() + FLASH_DURATION,
            }
            return true
        end
        if state._rodPending then
            relic.active = false
            state._flashMsg = {
                text    = "上一竿还在收线，稍等动画结束",
                expires = love.timer.getTime() + FLASH_DURATION,
            }
            return true
        end
        -- 使用即打开情报界面（顺序带）
        state._shoeInfoOpen = true
        state.deckOverviewOpen = false
        state._shoeInfoTab = "strip"
        if relic.rod == "golden" or relic.rod == "rogue" or relic.rod == "lost" then
            -- 即发型：排队执行（鱼钩动画结束后真正改牌库）
            relic.active = false
            GameState.queueRod(state, relic, relic.rod, nil)
        else
            -- 点选型：武装，等待顺序带点击目标
            state._rodArmed = { relic = relic, kind = relic.rod, picked = {} }
            state._flashMsg = {
                text    = "钓具已装备：在情报面板点击已标记的牌（每回合限 1 次）",
                expires = love.timer.getTime() + FLASH_DURATION,
            }
        end
        return true
    end

    -- ===== 揭示组（点亮即亮明特定位置，本小局有效）=====
    if relic.active and relic.reveal then
        relic.active = false
        state._revealedPos = state._revealedPos or {}
        for _, rg in ipairs(relic.reveal) do
            for p = rg[1], rg[2] do state._revealedPos[p] = true end
        end
        state._shoeInfoOpen = true
        state.deckOverviewOpen = false
        state._shoeInfoTab = "strip"
        GameState.markRelicRoundActive(state, relic.id)
        if relic._consumable then
            relic._usesLeft = (relic._usesLeft or 3) - 1
            if relic._usesLeft <= 0 then
                relic._expired = true
            end
        end
        state._flashMsg = {
            text    = "揭示：牌库指定位置已亮明（本回合有效，按 I 查看）",
            expires = love.timer.getTime() + FLASH_DURATION,
        }
        return true
    end

    -- ===== 弃牌堆组（打捞 / 回流 / 淘洗）=====
    if relic.active and relic.discardTool then
        if relic.discardTool == "salvage" then
            -- 武装：等弃牌堆页签点击选牌（选中时才扣次）
            state._salvagerArmed = relic
            state._shoeInfoOpen = true
            state.deckOverviewOpen = false
            state._shoeInfoTab = "discard"
            state._flashMsg = {
                text    = "打捞已装备：点击弃牌堆一张牌，下次要牌将其打出",
                expires = love.timer.getTime() + FLASH_DURATION,
            }
        elseif relic.discardTool == "backflow" then
            relic.active = false
            local n = GameState.backflowDiscard(state)
            if n > 0 then
                GameState.markRelicRoundActive(state, relic.id)
                if relic._consumable then
                    relic._usesLeft = (relic._usesLeft or 3) - 1
                    if relic._usesLeft <= 0 then
                        relic._expired = true
                    end
                end
                state._shoeInfoOpen = true
                state.deckOverviewOpen = false
                state._shoeInfoTab = "strip"
            end
            state._flashMsg = {
                text    = (n > 0) and ("回流：弃牌堆最近 " .. n .. " 张已放回牌库顶")
                                       or "弃牌堆是空的 —— 次数未消耗",
                expires = love.timer.getTime() + FLASH_DURATION,
            }
        elseif relic.discardTool == "rinse" then
            relic.active = false
            local n = GameState.rinseDiscard(state)
            if n > 0 then
                GameState.markRelicRoundActive(state, relic.id)
                if relic._consumable then
                    relic._usesLeft = (relic._usesLeft or 3) - 1
                    if relic._usesLeft <= 0 then
                        relic._expired = true
                    end
                end
                state._shoeInfoOpen = true
                state.deckOverviewOpen = false
                state._shoeInfoTab = "strip"
            end
            state._flashMsg = {
                text    = (n > 0) and ("淘洗：弃牌堆 " .. n .. " 张已洗回并随机切牌")
                                       or "弃牌堆是空的 —— 次数未消耗",
                expires = love.timer.getTime() + FLASH_DURATION,
            }
        end
        return true
    end

    -- ===== 职阶残卷组（点亮后本小局生效；点亮即扣次，取消点亮不返还）=====
    -- 剑/狂走触发自动扣次，术是被动触发（openShardOffer 扣次），都不在这里扣
    if relic.active and relic.classShard
       and relic.id ~= "class_saber_shard" and relic.id ~= "class_berserker_shard"
       and relic.id ~= "class_caster_shard" then
        if relic._consumable then
            relic._usesLeft = (relic._usesLeft or 3) - 1
            if relic._usesLeft <= 0 then
                relic._expired = true
            end
        end
        GameState.markRelicRoundActive(state, relic.id)
        state._flashMsg = {
            text    = relic.name .. "：本小局生效（剩余 " .. math.max(0, relic._usesLeft or 0) .. " 次）",
            expires = love.timer.getTime() + FLASH_DURATION,
        }
    end

    return true
end

-- 焚牌：把牌靴顶 N 张烧进弃牌堆（不亮明）。返回实际烧掉张数。
-- 守恒语义：牌没有消失，只是从"抽牌堆的不确定"移进"弃牌堆的确定"。
function GameState.burnTopCards(state, n)
    n = n or 1
    local burned = 0
    for _ = 1, n do
        local c = state.deck:drawFor(nil)
        if not c then break end
        state.deck:toDiscard(c)
        burned = burned + 1
    end
    if burned > 0 then
        state._flashMsg = {
            text    = "焚牌：" .. burned .. " 张已烧进弃牌堆",
            expires = love.timer.getTime() + 1.5,
        }
    end
    return burned
end

-- ============================================================
-- 钓具组：改变已标记牌在牌库中的位置
--   流程：点亮（武装/即发）→ queueRod 排队 + 鱼钩动画 → updateVisuals 动画结束
--   → executeRod 真正改牌库 + 扣次（落空不扣次、不占每回合次数）
-- ============================================================

-- 排队一次钓获（xy 为动画锚点，可 nil → UI 用顺序带首个槽位兜底）
function GameState.queueRod(state, relic, kind, targets, ax, ay)
    state._rodPending = { relic = relic, kind = kind, targets = targets or {} }
    state._rodAnim = {
        startAt = love.timer.getTime(),
        duration = 0.8,
        x = ax, y = ay,
    }
end

-- 点选型目标点击（顺序带已标记的牌；swap 需要点两张）
function GameState.rodTarget(state, slotIndex, ax, ay)
    if state.state ~= "player" then return false end
    local armed = state._rodArmed
    if not armed then return false end
    if not state.deck or type(slotIndex) ~= "number" then return false end
    local card = state.deck.cards[slotIndex]
    if not card then return false end
    if not GameState.markUidMap(state)[card.uid] then
        state._flashMsg = {
            text    = "钓具武装中：请点击已标记的牌",
            expires = love.timer.getTime() + FLASH_DURATION,
        }
        return false
    end
    if armed.kind == "swap" then
        table.insert(armed.picked, card.uid)
        if #armed.picked < 2 then
            state._flashMsg = {
                text    = "换位钓具：再点一张已标记的牌完成互换",
                expires = love.timer.getTime() + FLASH_DURATION,
            }
            return true
        end
        GameState.queueRod(state, armed.relic, "swap", { armed.picked[1], armed.picked[2] }, ax, ay)
        armed.relic.active = false
        state._rodArmed = nil
        return true
    end
    GameState.queueRod(state, armed.relic, armed.kind, { card.uid }, ax, ay)
    armed.relic.active = false
    state._rodArmed = nil
    return true
end

-- 真正执行钓获重排（updateVisuals 动画结束时调用；也可直接调用做无头测试）
-- 返回是否成功；失败不扣次、退回每回合次数
function GameState.executeRod(state)
    local op = state._rodPending
    state._rodPending = nil
    state._rodAnim = nil
    if not op then return false end
    local relic = op.relic
    local cards = state.deck.cards
    local markMap = GameState.markUidMap(state)

    local function deckIndexOf(uid)
        for i, c in ipairs(cards) do
            if c.uid == uid then return i end
        end
        return nil
    end

    -- 从任意区域收走一张标记牌（守恒离场）：牌库 / 弃牌堆 / 双方手牌 / 卡包
    local function pluckMarked(uid)
        local i = deckIndexOf(uid)
        if i then return table.remove(cards, i) end
        local dp = state.deck.discardPile
        for j = 1, #dp do
            if dp[j].uid == uid then return table.remove(dp, j) end
        end
        for _, hand in ipairs({ state.player.hand, state.dealer.hand }) do
            for j = 1, #hand do
                if hand[j].uid == uid then return table.remove(hand, j) end
            end
        end
        if state._cardPackStored and state._cardPackStored.uid == uid then
            local c = state._cardPackStored
            state._cardPackStored = nil
            return c
        end
        return nil
    end

    local ok = false
    if op.kind == "standard" then
        -- 钓到第一张
        local c = pluckMarked(op.targets[1])
        if c then table.insert(cards, 1, c); ok = true end
    elseif op.kind == "deep" then
        -- 沉到最底（末尾 = 抽牌堆远离 drawFor 取牌端）
        local c = pluckMarked(op.targets[1])
        if c then table.insert(cards, c); ok = true end
    elseif op.kind == "trawl" then
        -- 向牌顶方向拖 3 张
        local i = deckIndexOf(op.targets[1])
        if i then
            local c = table.remove(cards, i)
            table.insert(cards, math.max(1, i - 3), c)
            ok = true
        end
    elseif op.kind == "swap" then
        -- 两张标记牌互换位置
        local i1 = deckIndexOf(op.targets[1])
        local i2 = deckIndexOf(op.targets[2])
        if i1 and i2 then
            cards[i1], cards[i2] = cards[i2], cards[i1]
            ok = true
        end
    elseif op.kind == "golden" then
        -- 牌库中所有标记牌按标记顺序钓到顶层依次排列
        local picked = {}
        for _, m in ipairs(state.shoeMarks or {}) do
            local i = deckIndexOf(m.uid)
            if i then table.insert(picked, table.remove(cards, i)) end
        end
        for k = 1, #picked do table.insert(cards, k, picked[k]) end
        ok = #picked > 0
    elseif op.kind == "rogue" then
        -- 所有标记牌（任意区域）随机抛回牌库各处
        local uids = {}
        for _, m in ipairs(state.shoeMarks or {}) do uids[#uids + 1] = m.uid end
        for _, uid in ipairs(uids) do
            local c = pluckMarked(uid)
            if c then table.insert(cards, love.math.random(1, #cards + 1), c) end
        end
        ok = #uids > 0
    elseif op.kind == "lost" then
        -- 弃牌堆所有标记牌钓回牌库顶（越晚弃的越靠顶）
        local dp = state.deck.discardPile
        local picked = {}
        for i = #dp, 1, -1 do
            if dp[i].uid and markMap[dp[i].uid] then
                table.insert(picked, table.remove(dp, i))
            end
        end
        for k = 1, #picked do table.insert(cards, k, picked[k]) end
        ok = #picked > 0
    end

    if ok then
        state._rodUsedRound = true
        if relic then
            GameState.markRelicRoundActive(state, relic.id)
            if relic._consumable then
                relic._usesLeft = (relic._usesLeft or 3) - 1
                if relic._usesLeft <= 0 then
                    relic._expired = true
                end
            end
        end
        state._flashMsg = {
            text    = "钓获！牌库已变化",
            expires = love.timer.getTime() + FLASH_DURATION,
        }
    else
        state._rodUsedRound = false   -- 落空：不占每回合次数
        state._flashMsg = {
            text    = "钓具落空 —— 没有符合条件的标记牌（次数未消耗）",
            expires = love.timer.getTime() + FLASH_DURATION,
        }
    end
    return ok
end

-- ============================================================
-- 弃牌堆组：打捞 / 回流 / 淘洗
-- ============================================================

-- 打捞：选定弃牌堆一张牌（下次要牌打出）
function GameState.salvagePick(state, index)
    if state.state ~= "player" then return false end
    local relic = state._salvagerArmed
    if not relic then return false end
    if not state.deck or type(index) ~= "number" then return false end
    local card = state.deck.discardPile and state.deck.discardPile[index]
    if not card then return false end
    state._salvagePick = card.uid
    state._salvagerArmed = nil
    state._shoeInfoOpen = false
    GameState.markRelicRoundActive(state, relic.id)
    if relic._consumable then
        relic._usesLeft = (relic._usesLeft or 3) - 1
        if relic._usesLeft <= 0 then
            relic._expired = true
        end
    end
    state._flashMsg = {
        text    = "打捞已选定：" .. tostring(card.rank) .. (card.suit or "") .. " —— 下次要牌将其打出",
        expires = love.timer.getTime() + FLASH_DURATION,
    }
    return true
end

-- 回流：弃牌堆最近 N 张按原弃牌顺序放回牌库顶（最早弃的先被抽到）。返回张数
function GameState.backflowDiscard(state, n)
    n = n or 3
    local dp = state.deck.discardPile
    local picked = {}
    for _ = 1, n do
        if #dp == 0 then break end
        table.insert(picked, table.remove(dp))   -- 从最新端取
    end
    -- picked = [最新, ..., 最旧]；逐个插到顶 → 最终牌序 = 最旧在最前（原弃牌顺序）
    for i = 1, #picked do
        table.insert(state.deck.cards, 1, picked[i])
    end
    return #picked
end

-- 淘洗：弃牌堆整体洗回牌库 + 随机切牌一次。返回洗入张数
function GameState.rinseDiscard(state)
    local n = state.deck:shuffleDiscardIn()
    if n > 0 and #state.deck.cards > 1 then
        GameState.cutShoe(state, love.math.random(1, #state.deck.cards), false)
    end
    return n
end

-- ============================================================
-- 标签系统：墨水标记 —— 花筹码锚定牌靴中的实体牌
--   · 费用按阶段（MARK_COST：500/2000/10000），同时最多 5 张
--   · 入口三处：牌库槽位（markCardAt）/ 牌桌明牌（markHandCard）/ 弃牌堆（markDiscardAt）
--   · 洗牌后仍追踪同一张实体牌（uid，守恒保证永不消失）
--   · 庄家要牌时手牌里藏着标记牌有 2% 被发现：罚 3 倍下注 + 去标记 + 庄家更换
-- ============================================================
function GameState.markUidMap(state)
    local map = {}
    for _, m in ipairs(state.shoeMarks or {}) do map[m.uid] = m end
    return map
end

-- 当前阶段的标记价；酒吧模式无经济 → nil（不可标记）
-- 墨水大盗：费用减半
function GameState.markPrice(state)
    if state.gameMode == "bar" then return nil end
    local price = MARK_COST[state.stage or 1] or 500
    if GameState.hasRelic(state, "ink_thief") then price = math.floor(price / 2) end
    return price
end

-- 持有某遗物（未被消耗完）即生效 —— 出千配合系遗物全走被动判定
-- 特种标记放在专属库存 state.specialMarks（不占遗物栏 5 格），这里一并查询
function GameState.hasRelic(state, id)
    for _, r in ipairs(state.relics or {}) do
        if r.id == id and not r._expired then return true end
    end
    for _, m in ipairs(state.specialMarks or {}) do
        if m.id == id then return true end
    end
    return false
end

-- 职阶残卷是否处于点亮中（本小局生效的一次性职阶仿制品）
function GameState.shardActive(state, id)
    for _, r in ipairs(state.relics or {}) do
        if r.id == id and r.active and not r._expired then return true end
    end
    return false
end

-- 被动型消耗遗物（hasRelic 判定系）消耗一次：_usesLeft 归零 → _expired（下个 resetRound 退场）
-- 返回 true = 找到并消耗；false = 未持有/已耗尽
function GameState.useRelicPassive(state, id)
    for _, r in ipairs(state.relics or {}) do
        if r.id == id and not r._expired then
            if r._consumable then
                r._usesLeft = (r._usesLeft or 3) - 1
                if r._usesLeft <= 0 then
                    r._expired = true
                end
            end
            return true
        end
    end
    return false
end

-- 标记上限（千门人脉 +2）
function GameState.marksCap(state)
    if GameState.hasRelic(state, "cheat_consort") then return MARKS_MAX + 2 end
    return MARKS_MAX
end

-- 特殊标记类型与优先序（同时持有多枚时按此顺序消耗）
local SPECIAL_MARKS = {
    { id = "mark_vanish", kind = "vanish" },
    { id = "mark_bomb",   kind = "bomb" },
    { id = "mark_flame",  kind = "flame" },
    { id = "mark_void",   kind = "void" },
    { id = "mark_bounty", kind = "bounty" },
}
GameState.SPECIAL_MARKS = SPECIAL_MARKS

-- 特种标记库存（不占遗物栏 5 格）：全库只能持有一枚，新获得的直接替换旧持有的（含重复购买同一款）
-- uses 归零即从库存移除（hasRelic 同步失效）；forged 为铸造后的永久标记
function GameState.addSpecialMark(state, relic)
    state.specialMarks = {}
    local add = relic._usesLeft or 3
    table.insert(state.specialMarks, { id = relic.id, uses = add })
    return true
end

-- 当前可用的特殊标记（持有 + 有次数 + 本回合未用过）；无则 nil（走普通墨水标记）
-- 消耗顺序按 SPECIAL_MARKS 优先序
function GameState.availableSpecialMark(state)
    if state._specialMarkUsedRound then return nil end
    for _, sm in ipairs(SPECIAL_MARKS) do
        for _, m in ipairs(state.specialMarks or {}) do
            if m.id == sm.id and (m.forged or (m.uses or 0) > 0) then
                return { mark = m, kind = sm.kind }
            end
        end
    end
    return nil
end

-- 特殊标记效果动画（UI.drawMarkFx 渲染，updateVisuals 到期清除）
-- anchor: "deck"（牌堆）| "hand"（玩家手牌）| "dealer"（庄家手牌）
function GameState.markFx(state, kind, anchor)
    state._markFx = {
        kind = kind,
        anchor = anchor or "deck",
        startAt = love.timer.getTime(),
        life = 0.9,
    }
end

-- 显影墨水：标记成功后立刻亮明这张牌（本就公开的牌不消耗次数）
-- 「公开」口径：手牌明牌 / 弃牌堆本就可见；只有牌库顺序带里 peek/揭示范围外的背面牌需要翻
function GameState.revealMarkedCard(state, card)
    if not card or card.faceUp then return false end
    for _, r in ipairs(state.relics or {}) do
        if r.id == "reveal_ink" and not r._expired and (r._usesLeft or 0) > 0 then
            card.faceUp = true
            r._usesLeft = r._usesLeft - 1
            if r._usesLeft <= 0 then r._expired = true end
            GameState.markRelicRoundActive(state, "reveal_ink")
            state._flashMsg = {
                text    = "显影墨水：标记的牌已亮明（剩余 " .. r._usesLeft .. " 次）",
                expires = love.timer.getTime() + FLASH_DURATION,
            }
            return true
        end
    end
    return false
end

-- 爆炸标记：把这张牌之后的 2 张炸进弃牌堆（玩家/庄家摸到都触发；守恒：炸毁=入弃牌堆）
function GameState.explodeAfter(state, card)
    for _ = 1, 2 do
        local c = state.deck:drawFor(nil)
        if not c then break end
        state.deck:toDiscard(c)
    end
    GameState.markFx(state, "bomb", "deck")
    state.screenShake = math.min(8, (state.screenShake or 0) + 3)   -- 爆炸轻微屏震
    state._flashMsg = {
        text    = "爆炸标记：其后的 2 张牌被炸进弃牌堆",
        expires = love.timer.getTime() + FLASH_DURATION,
    }
end

-- 虚空标记：标记瞬间吸收"上一张"牌（继承倍率/词条与判定值，黑洞同款）。
-- prevInfo: { card=, list=, index=, zone="hand"|"deck"|"discard", target=被标记牌 }
-- 手牌/牌库里的前一张守恒移入弃牌堆；弃牌堆里的本就在弃牌堆（词条已被吸收）。
-- 没有上一张 → 返回 false（本次不标记、不消耗次数）
function GameState.voidAbsorbPrev(state, prevInfo)
    if not prevInfo or not prevInfo.card or not prevInfo.target then
        state._flashMsg = {
            text    = "虚空标记：前面没有牌可吸收",
            expires = love.timer.getTime() + FLASH_DURATION,
        }
        return false
    end
    local prev, card = prevInfo.card, prevInfo.target
    card.mult_bonus = (card.mult_bonus or 0) + (prev.mult_bonus or 0)
    card.is_rps = card.is_rps or prev.is_rps
    card.is_67  = card.is_67  or prev.is_67
    card.is_cage = card.is_cage or prev.is_cage
    card.is_chip = card.is_chip or prev.is_chip
    -- 只继承标记不够：RPS 靠 rank 判"石/剪/布"、67 靠 rank/value 判 6/7 → 单独记下判定值
    if prev.is_rps then card.rps_symbol = card.rps_symbol or prev.rps_symbol or prev.rank end
    if prev.is_67 then card.s67_rank = card.s67_rank or prev.s67_rank or prev.value or prev.rank end
    if (prevInfo.zone == "hand" or prevInfo.zone == "deck") and prevInfo.list then
        table.remove(prevInfo.list, prevInfo.index)
        state.deck:toDiscard(prev)
    end
    -- 效果动画：手牌区吸收 → 锚玩家手牌；牌库/弃牌堆吸收 → 锚牌堆
    GameState.markFx(state, "void", (prevInfo.zone == "hand") and "hand" or "deck")
    state._flashMsg = {
        text    = "虚空标记：吸收了 " .. tostring(prev.rank) .. (prev.suit or "") .. " 及其词条",
        expires = love.timer.getTime() + 1.8,
    }
    return true
end

-- 统一入口：对任意实体牌做记号（扣费 / 去重 / 上限 / 酒吧拦截 全在这里）
-- 持有特殊标记遗物时：标记动作被替换为特殊标记（不花筹码、消耗次数、每回合 1 次）
-- prevInfo：虚空标记用的"上一张"位置信息（见 voidAbsorbPrev），由三个入口负责解析
function GameState.tryMarkCard(state, card, sourceDesc, prevInfo)
    if not card or not card.uid then return false end
    local price = GameState.markPrice(state)
    if not price then
        state._flashMsg = {
            text    = "酒吧模式没有标记玩法",
            expires = love.timer.getTime() + FLASH_DURATION,
        }
        return false
    end

    -- 取消标记：再次点击已标记的牌 → 摘掉标记（次数 / 筹码一律不返还）
    if GameState.markUidMap(state)[card.uid] then
        GameState.removeMarkByUid(state, card.uid)
        state._flashMsg = {
            text    = "已取消标记（次数 / 筹码不返还）",
            expires = love.timer.getTime() + FLASH_DURATION,
        }
        return true
    end

    local cap = GameState.marksCap(state)
    if #(state.shoeMarks or {}) >= cap then
        state._flashMsg = {
            text    = "标记已满（最多 " .. cap .. " 张）",
            expires = love.timer.getTime() + FLASH_DURATION,
        }
        return false
    end

    -- 特殊标记路径：替代普通墨水标记（次数耗尽自动回到普通标记）
    local sp = GameState.availableSpecialMark(state)
    if sp then
        -- 虚空标记：标记瞬间立即吸收上一张（不是摸到时才触发）
        local voidAbsorbed = false
        if sp.kind == "void" then
            if prevInfo then prevInfo.target = card end
            if not GameState.voidAbsorbPrev(state, prevInfo) then return false end
            voidAbsorbed = true
        end
        if not sp.mark.forged then
            sp.mark.uses = (sp.mark.uses or 0) - 1
            if sp.mark.uses <= 0 then
                -- 次数耗尽即从标记库存移除（不占遗物栏，没有"过期挂栏"形态）
                for i, m in ipairs(state.specialMarks) do
                    if m == sp.mark then table.remove(state.specialMarks, i) break end
                end
            end
        end
        state._specialMarkUsedRound = true
        table.insert(state.shoeMarks, {
            uid = card.uid, kind = sp.kind, seen = false, rank = nil, suit = nil,
            at = love.timer.getTime(),
        })
        GameState.revealMarkedCard(state, card)   -- 显影墨水：标记的同时翻开未公开的牌
        if not voidAbsorbed then
            state._flashMsg = {
                text    = "已施加特殊标记（" .. (sourceDesc or "实体牌") .. "）· 本回合特殊标记已用掉",
                expires = love.timer.getTime() + FLASH_DURATION,
            }
        end
        return true
    end

    -- 普通墨水标记（花钱）
    if (state.player.chips or 0) < price then
        state._flashMsg = {
            text    = "筹码不足 — 标记需要 $" .. price,
            expires = love.timer.getTime() + FLASH_DURATION,
        }
        return false
    end
    state.player.chips = state.player.chips - price
    -- 墨水大盗：这次标记真的享受了减费 → 消耗 1 次
    if GameState.hasRelic(state, "ink_thief") then
        GameState.useRelicPassive(state, "ink_thief")
    end
    -- 标记费用把筹码打穿底线 → 立即判负踢出（不等回合结算）
    GameState.checkBrokeNow(state, "标记费用让你倾家荡产！")
    table.insert(state.shoeMarks, {
        uid = card.uid, kind = "ink", seen = false, rank = nil, suit = nil,
        at = love.timer.getTime(),
    })
    GameState.revealMarkedCard(state, card)   -- 显影墨水：标记的同时翻开未公开的牌
    state._flashMsg = {
        text    = "标记成功：" .. (sourceDesc or "实体牌") .. "（-$" .. price .. "）· 洗牌仍追踪 · 庄家有 2% 概率发现",
        expires = love.timer.getTime() + FLASH_DURATION,
    }
    return true
end

-- 牌库槽位标记（顺序带点击）；虚空的"上一张"= 更靠近牌顶的前一张
function GameState.markCardAt(state, slotIndex)
    if not state.deck or type(slotIndex) ~= "number" then return false end
    local card = state.deck.cards[slotIndex]
    if not card then return false end
    local prevInfo
    if slotIndex >= 2 and state.deck.cards[slotIndex - 1] then
        prevInfo = { card = state.deck.cards[slotIndex - 1], list = state.deck.cards,
                     index = slotIndex - 1, zone = "deck" }
    end
    return GameState.tryMarkCard(state, card, "牌库第 " .. slotIndex .. " 张", prevInfo)
end

-- 牌桌明牌标记（点击桌面上的牌）；虚空的"上一张"= 手牌里它前面那张
function GameState.markHandCard(state, side, index)
    if type(index) ~= "number" then return false end
    local hand = (side == "dealer") and state.dealer.hand or state.player.hand
    local card = hand and hand[index] or nil
    if not card then return false end
    if side == "dealer" and not card.faceUp then
        state._flashMsg = {
            text    = "暗牌看不见，做不了记号",
            expires = love.timer.getTime() + FLASH_DURATION,
        }
        return false
    end
    local prevInfo
    if index >= 2 and hand[index - 1] then
        prevInfo = { card = hand[index - 1], list = hand, index = index - 1, zone = "hand" }
    end
    return GameState.tryMarkCard(state, card, side == "dealer" and "庄家的明牌" or "你手上的牌", prevInfo)
end

-- 弃牌堆标记（弃牌堆页签点击）；虚空的"上一张"= 它前一张弃牌（原地吸收词条）
function GameState.markDiscardAt(state, index)
    if not state.deck or type(index) ~= "number" then return false end
    local card = state.deck.discardPile and state.deck.discardPile[index] or nil
    if not card then return false end
    local prevInfo
    if index >= 2 and state.deck.discardPile[index - 1] then
        prevInfo = { card = state.deck.discardPile[index - 1], zone = "discard" }
    end
    return GameState.tryMarkCard(state, card, "弃牌堆第 " .. index .. " 张", prevInfo)
end

-- 去除某实体的标记（庄家发现 / 后续清理用）
function GameState.removeMarkByUid(state, uid)
    for i, m in ipairs(state.shoeMarks or {}) do
        if m.uid == uid then
            table.remove(state.shoeMarks, i)
            return true
        end
    end
    return false
end

-- 庄家发现（确定性部分）：罚 3 倍下注（封顶现有筹码）+ 去标记 + 庄家更换。
-- 老千世家：罚金减半，且 50% 概率保住标记。
-- 返回罚金数额；2% 掷骰在 dealerAction 的要牌循环里做（rollMarkDiscovery）。
-- 防御：牌上没有玩家的标记时不罚（rollMarkDiscovery 只会对标记牌调到这里）。
function GameState.discoverMark(state, card)
    if not card or not card.uid then return 0 end
    if not GameState.markUidMap(state)[card.uid] then return 0 end
    local spoiled = GameState.hasRelic(state, "sharp_family")
    local fine = math.min(state.player.chips or 0, math.floor((state.player.bet or 0) * MARK_FINE_MULT * (spoiled and 0.5 or 1)))
    state.player.chips = (state.player.chips or 0) - fine
    -- 老千世家：这次庇护真的生效了 → 消耗 1 次
    if spoiled then
        GameState.useRelicPassive(state, "sharp_family")
    end
    -- 罚金把筹码打穿底线 → 立即判负踢出（赢了这局也救不回来）
    GameState.checkBrokeNow(state, "标记罚金让你倾家荡产！")
    -- 老千世家：50% 概率保住标记（牌没被没收，只是被怀疑了一回）
    if not (spoiled and love.math.random() < 0.5) then
        GameState.removeMarkByUid(state, card.uid)
    end
    -- 庄家已更换：旧庄家的出千意图一并作废
    if state.cheatState then
        state.cheatState.isCheating = false
        state.cheatState.cheatType = 0
        state.cheatState.cheatExecuted = false
        state.cheatState.visualTell = false
        state.cheatState.cheatTellKind = nil
    end
    state._flashMsg = {
        text    = "墨水牌被发现，庄家已更换！罚没 $" .. fine,
        expires = love.timer.getTime() + FLASH_DURATION + 1,
    }
    return fine
end

-- 庄家要牌巡查（每次明牌时调用一次）：手牌里含「墨水标记」的明牌则掷 2%（发现即罚）
-- 特殊标记（消失/爆炸/火焰/虚空/赏金）是另一路手艺，庄家看不出 → 不参与判定
function GameState.rollMarkDiscovery(state)
    if not (state.shoeMarks and #state.shoeMarks > 0) then return false end
    local map = GameState.markUidMap(state)
    local foundCard = nil
    for _, c in ipairs(state.dealer.hand or {}) do
        local m = c.uid and map[c.uid] or nil
        if m and (m.kind or "ink") == "ink" and c.faceUp then
            foundCard = c
            break
        end
    end
    if not foundCard then return false end
    if love.math.random() < MARK_DISCOVERY then
        GameState.discoverMark(state, foundCard)
        return true
    end
    return false
end

-- 标记牌的实时位置：返回 where("draw"/"discard"/"player"/"dealer"/"stored"/"lost"), index
function GameState.markWhere(state, mark)
    if not mark or not mark.uid then return "lost", nil end
    local uid = mark.uid
    for i, c in ipairs(state.deck.cards) do
        if c.uid == uid then return "draw", i end
    end
    for i, c in ipairs(state.deck.discardPile or {}) do
        if c.uid == uid then return "discard", i end
    end
    for _, c in ipairs(state.player.hand or {}) do
        if c.uid == uid then return "player", nil end
    end
    for _, c in ipairs(state.dealer.hand or {}) do
        if c.uid == uid then return "dealer", nil end
    end
    if state._cardPackStored and state._cardPackStored.uid == uid then return "stored", nil end
    return "lost", nil
end

-- 一手结算（两手全部翻明）时，在场标记补记"已见过"与点数
-- 已知边界：黑洞吸收/斩击等中途离场的牌不经此处（其标记保持"未见"，只追踪位置）
function GameState.noteMarksSeen(state)
    if not (state.shoeMarks and #state.shoeMarks > 0) then return end
    local map = GameState.markUidMap(state)
    for _, hand in ipairs({ state.player.hand, state.dealer.hand }) do
        for _, c in ipairs(hand or {}) do
            local m = c.uid and map[c.uid] or nil
            if m and not m.seen then
                m.seen = true
                m.rank = c.rank
                m.suit = c.suit
            end
        end
    end
end

-- ============================================================
-- 变化动词（阶段3）：切牌 / 换靴
--   设计语义：变化让信息"衰减"，但守恒与标记追踪不破 —— 切牌只动顺序，
--   uid 标记自动跟随；换靴是剧情性大节拍，旧靴整体退场、标记随之离去。
-- ============================================================

-- 切牌：把抽牌堆顶部 k 张压到牌底。known=false 时为庄家行为（k 已知与否不影响标记）。
-- 返回实际移动张数（0 = 无效果）。
function GameState.cutShoe(state, k, known)
    local pile = state.deck.cards
    local n = #pile
    if n < 2 then return 0 end
    k = ((math.floor(k or 1) - 1) % n) + 1
    if k >= n then return 0 end
    local moved = {}
    for i = 1, k do moved[i] = table.remove(pile, 1) end
    for i = 1, k do table.insert(pile, moved[i]) end
    state._flashMsg = {
        text    = known and ("切牌：顶部 " .. k .. " 张已切到牌底（标记仍精确追踪）")
                       or "庄家切了牌 —— 牌序已变，你的标记仍在追踪各自的实体",
        expires = love.timer.getTime() + FLASH_DURATION,
    }
    return k
end

-- 换靴：整副牌靴换新（副数 = 新阶段难度）。购买过的特殊牌组按历史重新注入；
-- 旧靴上的标记随旧靴离去（守恒的剧情性例外：旧靴整体退场）。
function GameState.rebuildShoe(state, numDecks)
    numDecks = math.max(1, math.floor(numDecks or 1))
    local removedMarks = #(state.shoeMarks or {})
    state.deck = Deck.new(numDecks)
    for _, coll in ipairs(state.deckCollections or {}) do
        if coll.cards and #coll.cards > 0 then
            state.deck:addCards(coll.cards, coll.label)
        end
    end
    state.shoeMarks = {}
    state._baseDecks = numDecks   -- 删牌组商品的上限随新靴同步
    if removedMarks > 0 then
        state._flashMsg = {
            text    = "换新牌靴（" .. numDecks .. " 副）！你的 " .. removedMarks .. " 个标记随旧靴离去",
            expires = love.timer.getTime() + FLASH_DURATION + 1,
        }
    else
        state._flashMsg = {
            text    = "换新牌靴（" .. numDecks .. " 副）！构成重置，重新计数吧",
            expires = love.timer.getTime() + FLASH_DURATION + 1,
        }
    end
end

function GameState.addRelic(state, relic)
    -- 特种标记不进遗物栏：统一走专属标记库存（任何获取途径都路由到这里）
    if relic.markDot then return GameState.addSpecialMark(state, relic) end
    if #state.relics >= 5 then return false end
    table.insert(state.relics, relic)
    GameState.registerAllRelics(state)
    return true
end

-- ============================================================
-- 开局
-- ============================================================
function GameState.startNewGame(state)
    -- 完整重置（保留 settings + events 事件绑定）
    state.deck = Deck.new((state.stageDeckNum and state.stageDeckNum[1]) or 1)
    state.relics = {}
    state.turn = 1
    state.roundsPlayed = 0   -- 新周目小局计数归零

    -- 阶段系统重置
    state.stage = 1
    state.roundsInStage = 0

    -- 职阶重置
    state.class = nil
    state.classCharges = 0
    state.classOffer = nil
    state.classOfferActive = false
    state.classOfferTarget = nil
    state._afterClassOffer = nil
    state._archer_preview = false

    -- 游戏模式 + 庄家职阶（从设置读取，困难模式立即给庄家一个）
    local Classes = require("src.classes")
    state.gameMode = (state.settings and state.settings.gameMode) or "basic"
    if state.gameMode == "hard" then
        state.dealerClass = Classes.random()
        state.dealerCharges = (state.dealerClass.id == "rider") and 3 or 0
        state.dealerStreak = 0
        state.dealerRelics = {}
    else
        state.dealerClass = nil
        state.dealerCharges = 0
        state.dealerStreak = 0
        state.dealerRelics = {}
    end

    -- 玩家/庄家牌桌状态
    state.player = { chips = 2500, bet = 0, hand = {} }
    state.dealer = { hand = {} }

    -- 上局残留
    state.result = nil
    state.lastScoreDetails = nil
    state.quitTimer = 0
    state.exitReason = ""
    state._flashMsg = nil
    state.streak = 0
    state.firstHitThisRound = false
    state._shoePeek = 0          -- 新周目窥视深度清零
    state._shoeInfoOpen = false  -- 情报面板不跨周目残留
    state._shoeInfoTab = nil     -- 面板页签复位
    state.shoeMarks = {}
    state._specialMarkUsedRound = nil
    state.specialMarks = {}   -- 特种标记库存随周目清空（仅限一局内有效，新游戏刷新）
    state._doubled = nil
    state._bustBetOn = false
    state._bustBet = 0
    state._bustBetOdds = nil
    state._pendingShoe = nil
    state._s67_triggered = nil
    state._natural_bj = nil
    -- 卡包存牌只在本局内持久（resetRound 刻意不清），开局必须清掉，否则跨周目泄漏
    state._cardPackStored = nil
    state._mobileShopUsed = nil
    state._mobileShopReturn = nil
    state._drawRestrict = nil

    -- 钓具 / 揭示 / 弃牌堆道具与特殊标记动画（新周目一律清空）
    state._revealedPos = nil
    state._rodArmed = nil
    state._rodUsedRound = nil
    state._rodPending = nil
    state._rodAnim = nil
    state._salvagerArmed = nil
    state._salvagePick = nil
    state._markFx = nil

    -- 作弊概率回到基准（否则 庄家恐惧症 的减半会跨周目累积）
    if state.cheatChanceBase then
        state.cheatChance = {
            [1] = state.cheatChanceBase[1],
            [2] = state.cheatChanceBase[2],
            [3] = state.cheatChanceBase[3],
        }
    end
    -- 债务收藏家的借款只在本周目内有效，新游戏清空
    state.debt = nil

    -- 作弊状态
    state.cheatState = {
        isCheating = false,
        cheatType = 0,
        visualTell = false,
        wasAccused = false,
        cheatExecuted = false,
        cheatTellKind = nil,
    }
    state.accuseResult = nil
    state._distractorShown = nil
    state._probeActive = nil
    state._stage2BriefOpen = false
    state._stage2BriefShown = false   -- 每次新游戏内只弹一次阶段 2 说明

    -- 酒吧模式：无遗物 / 无商店 / 无阶段，走独立初始化后直接返回
    if state.gameMode == "bar" then
        GameState.barStartNewGame(state)
        return
    end

    -- 商店/遗物
    -- 开局三选一只出消耗品：永久类遗物（无 _consumable）不进初始三选一；
    -- 商店专属消耗品（特种标记 / 钓具 / 揭示 / 弃牌堆道具 / 职阶残卷 / 显影墨水）照旧排除
    local starterExclude = {}
    for _, sm in ipairs(SPECIAL_MARKS) do starterExclude[sm.id] = true end
    for _, r in ipairs(Relics.LIBRARY) do
        if not r._consumable or r.rod or r.reveal or r.discardTool or r.classShard or r.markFlip then
            starterExclude[r.id] = true
        end
    end
    state.pendingRelics = Relics.drawRandom(3, { common = 40, uncommon = 35, rare = 18, legendary = 5, cursed = 2 }, starterExclude)
    state.shopOfferings = nil
    state.shopRerollCost = 200
    state.roundsSinceShop = 0

    -- 牌组系统（不继承！）
    state.deckCollections = {}
    state.shopDeckOfferings = nil
    state.lastDeckAddAnim = nil
    state._baseDecks = (state.stageDeckNum and state.stageDeckNum[1]) or 6
    state._removedDecks = 0

    -- 视觉
    state.scorePopups = {}
    state.screenShake = 0

    state.state = "relic_select"
    state.tutorial = nil  -- 正式游戏不进教程
    -- 先清掉上一局残留的遗物事件监听，否则它们会在下面的 GAME_START 里再触发一次
    -- （例如 庄家恐惧症 会把刚重置好的新周目作弊概率又减半）
    GameState.registerAllRelics(state)
    state.events:trigger(EventManager.EVENTS.GAME_START, { game = state })
end

function GameState.startTutorial(state)
    -- 先完整重置
    GameState.startNewGame(state)
    -- 教程强制基础模式（庄家无职阶）
    state.gameMode = "basic"
    state.dealerClass = nil
    state.dealerCharges = 0
    state.dealerStreak = 0
    state.dealerRelics = {}
    state.settings.gameMode = "basic"
    -- 教程特殊覆盖
    state.pendingRelics = nil  -- 教程先不给遗物，Phase 4 再教
    state.state = "bet"        -- 直接进下注，Phase 1 教正常 21 点
    state.player.chips = 2500

    -- 清掉遗物（教程前几阶段不用）
    GameState.registerAllRelics(state)

    -- 初始化教程叠加层
    local Tutorial = require("src.tutorial")
    Tutorial.init(state)
end

function GameState.selectStarterRelic(state, index)
    if state.state ~= "relic_select" or not state.pendingRelics then return end
    -- 必须选一个：nil 或无效 index 都不能推进
    if not index or not state.pendingRelics[index] then return end
    GameState.addRelic(state, state.pendingRelics[index])
    state.pendingRelics = nil

    -- 教程模式下：选完遗物先清上一局脏手牌，再发牌进入 player 状态
    if state.tutorial and state.tutorial.active then
        GameState.resetRound(state)   -- 清上一局残留的手牌 + 重置状态到 bet
        GameState.placeBet(state, math.min(100, state.player.chips))
        local Tutorial = require("src.tutorial")
        Tutorial.onPlayerAction(state, "relic_picked")
    else
        GameState.resetRound(state)
    end
end

-- ============================================================
-- 回合重置
-- ============================================================
function GameState.resetRound(state)
    -- 酒吧模式：没有下注阶段，直接开下一小局（main.lua 的 result → resetRound 因此无需改动）
    if state.gameMode == "bar" then return GameState.barBeginRound(state) end

    for _, c in ipairs(state.player.hand) do c._tweened = nil; c.visual = nil end
    for _, c in ipairs(state.dealer.hand) do c._tweened = nil; c.visual = nil end

    -- 守恒回收：整手进弃牌堆（绝不 GC —— 计数与标签依赖牌的总量守恒）
    state.deck:discardHand(state.player.hand)
    state.deck:discardHand(state.dealer.hand)

    state.player.hand = {}
    state.dealer.hand = {}
    state.player.bet = 0
    state.result = nil
    state.lastScoreDetails = nil
    state.firstHitThisRound = false
    state._shoePeek = 0     -- 窥视深度每小局清：窥牌遗物需重新点亮
    state._specialMarkUsedRound = nil   -- 特殊标记每回合限 1 次，每小局重置
    state._shardRiderUsed = nil   -- 骑之残卷：本小局的跳过机会每小局重置
    state._accuseMult = nil       -- 指认倍率定格（铁证如山扣次后 _doScoring 仍要用）
    -- 钓具 / 揭示 / 弃牌堆道具：每小局清（_salvagePick 已扣次，保留到用掉为止）
    state._revealedPos = nil
    state._rodArmed = nil
    state._rodUsedRound = nil
    state._rodPending = nil
    state._rodAnim = nil
    state._salvagerArmed = nil
    state.turn = state.turn + 1
    state.roundsPlayed = (state.roundsPlayed or 0) + 1   -- 刷榜口径：本局是第几小局
    state.accuseResult = nil
    state._natural_bj = nil     -- 必须每轮清！否则上一轮 BJ 标记残留会拦截这一轮的 hit
    state._s67_triggered = nil  -- 同样每轮清
    state._archer_preview = nil
    state._peekActive = false  -- 不再用 _peekCard；peek 标记直接打手牌上
    state._blackHoleUsed = nil    -- 黑洞遗物：每小局只吸收一次
    state._cardPackActive = nil   -- 卡包是 on_hit 触发，初始 nil
    state._cardPackStored = state._cardPackStored or nil   -- 持久存储卡（resetRound 不清！）
    state._saberConsumed = nil   -- 每轮清：让 Saber 动画下轮还能触发
    state._forcedResult = nil    -- 每轮清：强制结算结果（庄家 Rider 跳过）只在当轮有效
    state._mobileShopUsed = nil  -- 移动网络遗物：每小局限一次
    state._mobileShopReturn = nil
    state._drawRestrict = nil    -- 独享至尊 / 闭关：每小局由 on_round_start 重新打标记
    -- Caster 替换面板状态（新回合一定是关着的）
    state.classOffer = nil
    state.classOfferActive = false
    state.classOfferTarget = nil
    state._afterClassOffer = nil
    if state.class then state.class._consumed = nil end

    -- 触发 round_start（让 auto_active 遗物每轮设置自己的标记）
    state.events:trigger("on_round_start", { game = state })

    -- 过目不忘：算牌师的每局自动窥视 +1（在 on_round_start 之后补加）
    -- 限 3 次口径：每小局的自动窥视消耗 1 次（耗尽即 _expired，下个 resetRound 退场）
    if GameState.hasRelic(state, "mind_memory") then
        state._shoePeek = math.max(state._shoePeek or 0, 2)
        GameState.useRelicPassive(state, "mind_memory")
    end

    -- 重置作弊状态
    state.cheatState = {
        isCheating = false, cheatType = 0, visualTell = false, wasAccused = false,
        cheatExecuted = false, cheatTellKind = nil,
    }
    state._distractorShown = nil     -- 干扰项每小局重新判定
    state._probeActive = nil         -- 作弊探测器：每小局由 on_deal 效果重新置位
    state._stage2BriefOpen = false   -- 说明弹窗不跨小局残留（_stage2BriefShown 在新游戏内保留）

    -- 遗物激活：每小局重置 —— 手动类遗物（非 pre-game、非 auto_active）一律回到未激活，
    -- 需要玩家在要牌阶段重新点亮；pre-game / auto_active 遗物保持自动生效
    local hasExpired = false
    local kept = {}
    for _, relic in ipairs(state.relics or {}) do
        relic._roundActive = nil   -- 反制组「本小局是否已生效」标记，每小局清空
        if relic._expired then
            hasExpired = true
        else
            if Relics.isPreGame(relic) or relic.auto_active then
                relic.active = true
            else
                relic.active = false     -- 手动类：每小局清空激活状态
            end
            table.insert(kept, relic)
        end
    end
    state.relics = kept
    if hasExpired then
        GameState.registerAllRelics(state)  -- 重建事件（清掉过期遗物的监听）
    end

    -- 铸造后的窥牌遗物：永久生效 —— 每小局自动点亮（含过目不忘 +1），无需手动
    for _, relic in ipairs(state.relics or {}) do
        if relic._forged and (relic.id == "peek_1" or relic.id == "peek_2" or relic.id == "peek_3" or relic.id == "far_sight") then
            local depth = (relic.id == "peek_1") and 1 or (relic.id == "peek_2") and 2
                or (relic.id == "peek_3") and 3 or 5
            if GameState.hasRelic(state, "mind_memory") then depth = depth + 1 end
            state._shoePeek = math.max(state._shoePeek or 0, depth)
            relic.active = true
            GameState.markRelicRoundActive(state, relic.id)
        end
    end

    -- 守恒牌堆：不再每轮重建。抽牌堆见底（不足以再发一手）时把弃牌洗回，
    -- shuffleCount +1。已购特殊牌随弃牌堆自然循环，无需 rebuildDeck 重注入。
    if #state.deck.cards < 16 and #state.deck.discardPile > 0 then
        state.deck:shuffleDiscardIn()
    end

    -- 换靴节拍（阶段3）：阶段切换后第一次回桌时执行（副数 = 新阶段难度）
    if state._pendingShoe then
        local nd = state.stageDeckNum[state.stage] or 1
        GameState.rebuildShoe(state, nd)
        GameState.cutShoe(state, love.math.random(8, 25), false)
        state._pendingShoe = nil
    end

    -- 阶段3 每小局字段复位（双处安置铁律：这里 + GameState.new + startNewGame）
    state._doubled = nil
    state._bustBet = 0
    state._bustBetOdds = nil

    state.state = "bet"
    state.events:trigger(EventManager.EVENTS.ROUND_START, { game = state })
end

-- ============================================================
-- 职阶效果派发（按职阶自己声明的 triggers 在正确时机调用）
-- on_score_calc 类由 scoring.buildContext 调用，这里只负责牌桌时机类
-- ============================================================
function GameState.triggerClassEffect(state, eventName, ctx)
    local class = state.class
    if not class then return end
    local Classes = require("src.classes")
    local cdef = Classes.get(class.id) or class
    if not (cdef and type(cdef.effect) == "function" and cdef.triggers) then return end
    for _, ev in ipairs(cdef.triggers) do
        if ev == eventName then
            local ok, err = pcall(cdef.effect, ctx)
            if not ok then
                print(string.format("[Class %s] 错误(%s): %s", tostring(class.id), eventName, tostring(err)))
            end
            return
        end
    end
end

-- ============================================================
-- 作弊决定（发牌前）
-- ============================================================
-- 干扰项概率（阶段 2 = 15%，阶段 3 = 25%）
-- 阶段 1 完全干净：作弊概率 0，且任何表现（真痕迹 / 干扰项）都不出现
local DISTRACTOR_CHANCE = { [1] = 0.0, [2] = 0.15, [3] = 0.25 }
GameState.DISTRACTOR_CHANCE = DISTRACTOR_CHANCE

-- 给持有该 id 的遗物实例打「本小局已生效」标记（resetRound 每小局清空）
-- 反制组遗物的状态显示读这份标记，让玩家能看出它们本局到底有没有真的起作用
function GameState.markRelicRoundActive(state, id)
    for _, r in ipairs(state.relics or {}) do
        if r.id == id then r._roundActive = true end
    end
end

function GameState.decideCheat(state)
    -- 酒吧模式：没有庄家出千，也不掷任何骰（保持基础/困难模式的随机序列不变）
    if state.gameMode == "bar" then return end

    local cs = state.cheatState
    cs.cheatExecuted = false
    cs.cheatTellKind = nil
    cs.visualTell = false

    local chance = state.cheatChance[state.stage] or 0
    if love.math.random() >= chance then
        -- 没作弊：阶段 2+ 才可能出干扰项（与真痕迹「类似但不等同」，细节缺一环）
        -- 无论「作弊探测器」是否生效都掷同一颗骰，保证随机序列稳定、结果可复现
        local dChance = DISTRACTOR_CHANCE[state.stage] or 0
        if dChance > 0 and love.math.random() < dChance then
            if state._probeActive then
                -- 抑制干扰项的遗物（作弊探测器 / 作弊之眼）本小局确实起了作用
                GameState.markRelicRoundActive(state, "cheat_probe")
                GameState.markRelicRoundActive(state, "cheat_eye")
            else
                local r = love.math.random()
                if r < 0.2 then
                    cs.cheatTellKind = "dA"      -- 位置错：明牌位（真 A 在暗牌位）
                elseif r < 0.4 then
                    cs.cheatTellKind = "dB"      -- 形态错：常亮细描边（真 B 是单次脉冲）
                elseif r < 0.6 then
                    cs.cheatTellKind = "dC"      -- 形态错：只闪一次（真 C 带替换残影）
                elseif r < 0.8 then
                    cs.cheatTellKind = "dD"      -- 形态错：紫单线（真 D 双线脉冲）
                else
                    cs.cheatTellKind = "dE"      -- 形态错：蓝单线（真 E 双线）
                end
                cs.visualTell = true
            end
        end
        return
    end

    -- 选作弊类型（五招：A 换暗牌 / B 必十 / C 压低牌 / D 神抽 / E 镜影）
    local typeRoll = love.math.random()
    local cheatType
    if typeRoll < 0.28 then cheatType = 1       -- Type A: 暗牌换成BJ
    elseif typeRoll < 0.56 then cheatType = 2   -- Type B: 抽牌必10
    elseif typeRoll < 0.78 then cheatType = 3   -- Type C: 低牌换掉
    elseif typeRoll < 0.89 then cheatType = 4   -- Type D: 神抽（牌靴深处抽恰好要的牌）
    else cheatType = 5                          -- Type E: 镜影（暗牌复制你的明牌）
    end

    cs.isCheating = true
    cs.cheatType = cheatType
    -- 痕迹与执行标记都不在这里置：必须等三招「真正改动牌」时才绑定，
    -- 否则会出现「决定要作弊但前置条件没满足」时线索照出、判定照赢的错位
end

-- ============================================================
-- 发牌
-- ============================================================
function GameState.dealInitial(state)
    local dealCtx = { game = state, weight_low = false, weight_high = false }
    state.events:trigger("on_deal", dealCtx)
    -- 职阶（on_deal 类）：Lancer 的"发三张"由下面直接判定，这里让声明了 on_deal 的职阶有机会出手
    GameState.triggerClassEffect(state, "on_deal", dealCtx)

    -- 先决定这轮作弊还是不作弊
    GameState.decideCheat(state)

    -- Assassin 玩家职阶 / 杀之残卷：庄家看不到你的牌 → 依赖"看玩家手牌"的作弊（Type A / E 镜影）直接放弃
    local assassinBlind = (state.class and state.class.id == "assassin")
                       or GameState.shardActive(state, "class_assassin_shard") or false
    if assassinBlind and state.cheatState.isCheating
       and (state.cheatState.cheatType == 1 or state.cheatState.cheatType == 5) then
        state.cheatState.isCheating = false
        state.cheatState.cheatType = 0
        state.cheatState.visualTell = false
    end

    -- 牌堆偏好（低牌/高牌加重遗物）— 只影响玩家开局的抽牌
    local drawMode = nil
    if dealCtx.weight_low then drawMode = "low"
    elseif dealCtx.weight_high then drawMode = "high" end
    -- 独享至尊 / 闭关：本小局该方只能抽固有牌堆的牌
    local playerBasicOnly = (state._drawRestrict and state._drawRestrict.player) and true or nil
    local dealerBasicOnly = (state._drawRestrict and state._drawRestrict.dealer) and true or nil
    local function drawForPlayer()
        if drawMode then return state.deck:drawPreferred(true, drawMode, playerBasicOnly) end
        return state.deck:drawFor(true, playerBasicOnly)
    end

    -- ===== 发牌 =====
    for i = 1, 2 do
        if i == 1 and dealCtx.force_first_card then
            table.insert(state.player.hand, dealCtx.force_first_card)
        elseif i == 2 and dealCtx.force_second_card then
            table.insert(state.player.hand, dealCtx.force_second_card)
        else
            local card = drawForPlayer()
            if card then table.insert(state.player.hand, card) end
        end
    end

    -- Lancer 职阶 / 枪之残卷：初始发三张，且保证三张合计不超过 21 点
    if (state.class and state.class.id == "lancer")
       or GameState.shardActive(state, "class_lancer_shard") then
        -- peek 顶牌：保证 + 这张 ≤ 21 才发
        local peekTop = state.deck:peek(1)
        if #peekTop > 0 then
            local curTotal = Blackjack.calculateHand(state.player.hand)
            local cVal = Blackjack.cardValue(peekTop[1])
            if curTotal + cVal <= 21 then
                local c3 = state.deck:drawFor(true, playerBasicOnly)
                if c3 then table.insert(state.player.hand, c3) end
            end
            -- 爆牌风险 → 放弃发第三张（玩家只有 2 张，仍可继续 hit）
        end
    end

    -- ===== 发牌后钩子：能真正改到牌型的遗物（第二张 A / JQK 配对）=====
    -- on_deal 在发牌之前触发，那时手牌还是空的，所以这类遗物必须挂在这里
    state.events:trigger("on_deal_after", dealCtx)

    -- =====  牌堆窥视：peek = 手牌[1]打 _peek 标记 =====
    -- 提前"暴露"第一张 → 半透明显示；hit 后标记清除 → 正常显示
    -- 这样 peek 牌就是手牌的同一对象，100% 不可能不一致！
    state._peekActive = false
    state._peekKind = nil
    local dealerArcher = state.gameMode == "hard" and state.dealerClass and state.dealerClass.id == "archer"
    local shardArcher = GameState.shardActive(state, "class_archer_shard")
    local shouldPeek = dealCtx.peek or state._archer_preview or dealerArcher or shardArcher
    if shouldPeek and #state.player.hand > 0 then
        state.player.hand[1]._peek = true
        state._peekActive = true
        state._peekKind = dealerArcher and "dealer_archer" or (state._archer_preview and "archer" or "deck_peek")
    end

    -- Type E 镜影：暗牌直接复制你的第一张明牌（合成牌，守恒计数在入弃牌堆时收编）
    local cheatEApplied = false
    local d1
    if state.cheatState.isCheating and state.cheatState.cheatType == 5 and state.player.hand[1] then
        local src = state.player.hand[1]
        d1 = { rank = src.rank, suit = src.suit, faceUp = false, value = src.value,
               isSpecial = false, kind = "normal", mult_bonus = 0 }
        cheatEApplied = true
    else
        d1 = state.deck:drawFor(false, dealerBasicOnly)
    end
    if d1 then table.insert(state.dealer.hand, d1) end
    local d2 = state.deck:drawFor(true, dealerBasicOnly)
    if d2 then table.insert(state.dealer.hand, d2) end

    -- 痕迹 E：暗牌位蓝框 + 你的明牌左上角蓝色菱形（镜影标记）
    if cheatEApplied and d1 then
        d1._tell  = "E"
        d1._tellT = love.timer.getTime()
        if state.player.hand[1] then state.player.hand[1]._tellE = true end
        state.cheatState.cheatExecuted = true
        state.cheatState.cheatTellKind = "E"
        state.cheatState.visualTell    = true
    end

    -- ===== 困难模式：Lancer 庄家发第三张（保证发完不爆 ≤ 21） =====
    if state.gameMode == "hard" and state.dealerClass and state.dealerClass.id == "lancer" then
        local peekTop = state.deck:peek(1)
        if #peekTop > 0 then
            local c = peekTop[1]
            local curTotal = Blackjack.calculateHand(state.dealer.hand)
            local cVal = Blackjack.cardValue(c)
            if curTotal + cVal <= 21 then
                local d3 = state.deck:drawFor(true, dealerBasicOnly)
                if d3 then table.insert(state.dealer.hand, d3) end
            end
            -- 爆牌风险 → 放弃发第三张
        end
    end

    -- 作弊 Type A: 暗牌换成 BJ（把暗牌换成能凑 21 的牌）
    -- 注意：如果玩家天然 21，作弊 Type A 没意义（庄家被动 BJ → push，作弊白做）
    if state.cheatState.isCheating
       and state.cheatState.cheatType == 1
       and not Blackjack.isBlackjack(state.player.hand) then

        local visibleTotal = Blackjack.calculateHand({ state.dealer.hand[2] })

        -- 边界：visibleTotal + 最大暗牌（11/A）< 19 → 这轮作弊 Type A 不可能有效，跳过
        if visibleTotal + 11 >= 19 then
            local holeCard
            if visibleTotal == 10 then
                -- 明牌是10 → 暗牌换成A → BJ
                holeCard = { rank = 'A', suit = '♠', faceUp = false }
            elseif visibleTotal == 11 then
                -- 明牌是A → 暗牌换成10 → BJ
                holeCard = { rank = 10, suit = '♥', faceUp = false }
            else
                -- 明牌不是10/A → 暗牌凑到19~21
                local needed = 19 - visibleTotal
                if needed <= 0 then needed = 11 end
                if needed > 11 then needed = 10 end
                -- 修正：needed 为 1 或 11 时都应该是 A
                if needed == 1 or needed == 11 then needed = 'A' end
                holeCard = { rank = needed, suit = '♦', faceUp = false }
            end
            -- 痕迹 A：暗牌位（位置 1）白描边 + 持续轻微抖动
            -- 「实际执行」标记只在这里置位：真正换掉了暗牌才算执行
            state.deck:toDiscard(state.dealer.hand[1])   -- 被换下的真暗牌守恒回收
            holeCard._tell  = "A"
            holeCard._tellT = love.timer.getTime()
            state.dealer.hand[1] = holeCard
            state.cheatState.cheatExecuted   = true
            state.cheatState.cheatTellKind   = "A"
            state.cheatState.visualTell      = true
        end
    end

    -- 干扰项 dA：本局没作弊，但表现「像」Type A —— 描边打在明牌位（位置 2）且不抖动
    if state.cheatState.cheatTellKind == "dA" and state.dealer.hand[2] and not state._distractorShown then
        state.dealer.hand[2]._tell  = "dA"
        state.dealer.hand[2]._tellT = love.timer.getTime()
        state._distractorShown = true
    end

    -- 牢笼：开局就发到的牌不算「抽到的牢笼牌」（封锁只认之后抽到的牌）
    for _, c in ipairs(state.player.hand) do c._cageImmune = true end
    for _, c in ipairs(state.dealer.hand) do c._cageImmune = true end

    -- 检查 natural 21
    if Blackjack.isBlackjack(state.player.hand) then
        if Sfx and Sfx.play21 then Sfx.play21() end
        state._natural_bj = true   -- 标记：自然 BJ，等玩家 toggle 完遗物后再自动结算
        GameState.onExact21(state) -- 刚好 21：商店提前一回合（天然 21 也算到达）
        -- 不 return，继续走 player 状态让玩家能 toggle 遗物
    end

    if Blackjack.isBust(state.player.hand) then
        GameState.endRound(state)
        return
    end
    state.firstHitThisRound = true

    -- 发牌后也检测 67 组合技（两张牌就可能触发）
    GameState.check67Combo(state)

    -- 反作弊陷阱遗物: 指认猜对后下一局自动 Stand
    if state.autoStandNextRound then
        state.autoStandNextRound = false
        state.state = "dealer"
        GameState.dealerAction(state)
        return
    end

    -- 注意： Lancer 不再自动 stand（2026/9/23 改）：发三张后玩家仍可继续 hit

    -- 正常流程: 进入 player 状态（让玩家 toggle 遗物、hit/stand）
    state.state = "player"

    -- 自然 BJ 时不自动 stand — 让玩家有机会 toggle 遗物，点 stand 后再结算

end

-- ============================================================
-- 玩家操作
-- ============================================================

-- ========== 67 卡组组合技：检测并填满到 12 张 ==========
function GameState.check67Combo(state)
    local hand = state.player.hand
    if not hand or #hand < 2 then return false end

    local has6 = false
    local has7 = false
    for _, c in ipairs(hand) do
        if c.is_67 then
            -- 黑洞牌继承 67 词条时，6/7 记在 s67_rank 上（它自己的 rank 是扑克点数）
            if c.rank == 6 or c.value == 6 or c.s67_rank == 6 then has6 = true end
            if c.rank == 7 or c.value == 7 or c.s67_rank == 7 then has7 = true end
        end
    end

    if not (has6 and has7) then return false end
    if #hand >= HAND_MAX then return false end   -- 已满

    -- 填满剩余栏位到 12 张，固定从 6 开始交替 6,7,6,7...
    local suits = { "♠", "♥", "♦", "♣" }
    local fillCount = HAND_MAX - #hand
    for i = 1, fillCount do
        local suit = suits[love.math.random(4)]
        local value = (i % 2 == 1) and 6 or 7   -- 1,3,5...→6  2,4,6...→7
        local newCard = {
            suit = suit,
            rank = value,
            value = value,
            faceUp = true,
            kind = "s67",
            isSpecial = true,
            is_67 = true,
        }
        table.insert(state.player.hand, newCard)
        -- 从牌堆消耗一张（如果有），没有也照样填满；祭品牌守恒回收
        if state.deck and #state.deck.cards > 0 then
            state.deck:toDiscard(state.deck:draw(true))
        end
    end

    state._s67_triggered = true   -- 标记：67 组合技触发，结算时不算爆
    Sfx.play67()                  -- 67 音效：本分支每小局只进一次（手牌已满 → 再次调用提前 return），只播一遍
    return true
end

function GameState.hitPlayer(state)
    if state.state ~= "player" then return end

    -- 酒吧模式：牌堆抽空前先重灌（80 张牌组按样牌重灌，绝不返回 nil）
    GameState.barEnsureDeck(state)

    -- hit 后清 peek 标记 → 手牌[1] 从半透明预览态转正为正常牌
    if state._peekActive then
        for _, c in ipairs(state.player.hand) do c._peek = false; c.faceUp = true end
        state._peekActive = false
    end

    -- 自然 BJ 不能 hit（已经 21 了），提示玩家点 stand
    if state._natural_bj then
        state._flashMsg = {
            text = "自然 Blackjack! 请点 Stand 结算",
            expires = love.timer.getTime() + FLASH_DURATION,
        }
        return
    end

    -- 手牌上限硬限制（必须在任何抽牌 / insert 之前，防止消耗被拒的牌）
    if #state.player.hand >= HAND_MAX then
        state._flashMsg = {
            text    = "手牌已满 (" .. HAND_MAX .. " 张) — 无法继续要牌",
            expires = love.timer.getTime() + FLASH_DURATION,
        }
        return  -- 拒绝，牌堆不消耗
    end

    -- 牢笼：明牌最末尾是牢笼牌 → 不能继续要牌（必须在抽牌 / 扣消耗次数之前拦截）
    if isCageLocked(state.player.hand) then
        state._flashMsg = {
            text    = "牢笼封锁 — 明牌最末尾是牢笼牌，不能继续要牌",
            expires = love.timer.getTime() + FLASH_DURATION,
        }
        return
    end

    local hitCtx = {
        game = state,
        is_first_hit = state.firstHitThisRound,
        safe_hit = false,
        force_draw_card = nil,
        stop_auto = false,        -- 遗物: 点数≥16 时改为停牌（不抽牌，在 on_hit 后立即处理）
        auto_five_if_bust = false, -- 遗物: 爆牌时最后一张换成 5
    }
    -- 消耗性遗物次数快照：若本次要牌被"16自动停牌"拦下（牌根本没发出去），
    -- 之前被扣掉的次数必须原样退回，否则描述里的"可用 N 次"会被白白吃掉
    local usesSnapshot = {}
    for _, rel in ipairs(state.relics or {}) do
        if rel._consumable then
            usesSnapshot[#usesSnapshot + 1] = { rel = rel, uses = rel._usesLeft, expired = rel._expired }
        end
    end
    state.events:trigger("on_hit", hitCtx)

    -- ===== 16自动停牌：点数已 ≥ 16 → 不抽牌，直接进入庄家回合 =====
    if hitCtx.stop_auto then
        for _, snap in ipairs(usesSnapshot) do
            snap.rel._usesLeft = snap.uses
            snap.rel._expired = snap.expired
        end
        state.firstHitThisRound = false
        state.state = "dealer"
        GameState.dealerAction(state)
        return
    end

    -- ===== 黑洞遗物（手动激活）：吸收位于第一位置的牌，每小局一次 =====
    if hitCtx.blackhole_absorb and not state._blackHoleUsed and #state.player.hand > 0 then
        state._blackHoleUsed = true
        local absorbed = table.remove(state.player.hand, 1)
        state.deck:toDiscard(absorbed)   -- 被吸收的牌守恒回收（叙事上仍在黑洞里）
        state._flashMsg = {
            text = "黑洞吸收了: " .. tostring(absorbed.rank) .. (absorbed.suit or ""),
            expires = love.timer.getTime() + 1.8,
        }
    end

    -- ===== 卡包遗物逻辑 =====
    -- 优先级：取出 > force_draw_card > 存牌（不进手牌）
    local _cardPackAction = nil   -- "take" | "store" | nil
    if state._cardPackActive then
        if state._cardPackStored then
            _cardPackAction = "take"
            hitCtx.force_draw_card = state._cardPackStored
            state._cardPackStored = nil
            state._flashMsg = {
                text = "卡包取出: " .. (hitCtx.force_draw_card.rank .. hitCtx.force_draw_card.suit),
                expires = love.timer.getTime() + 1.5,
            }
        else
            _cardPackAction = "store"
        end
        state._cardPackActive = nil   -- 本轮消费掉
    end

    -- 打捞遗物：下次要牌改为打出弃牌堆中选定的一张（走 force_draw_card 路径，照常结算）
    -- 卡包取牌优先：若本次要牌被卡包占用，打捞保留到下一次
    if state._salvagePick and not hitCtx.force_draw_card then
        local dp = state.deck.discardPile
        for i = 1, #dp do
            if dp[i].uid == state._salvagePick then
                local salvaged = table.remove(dp, i)
                salvaged.faceUp = true
                hitCtx.force_draw_card = salvaged
                state._flashMsg = {
                    text = "打捞打出: " .. tostring(salvaged.rank) .. (salvaged.suit or ""),
                    expires = love.timer.getTime() + 1.5,
                }
                break
            end
        end
        state._salvagePick = nil
    end

    local card
    if hitCtx.force_draw_card then
        card = hitCtx.force_draw_card
        card.faceUp = true
    else
        -- 闭关：本小局玩家只能抽固有牌堆的牌
        local basicOnly = (state._drawRestrict and state._drawRestrict.player) and true or nil
        card = state.deck:drawFor(true, basicOnly)
    end

    -- 消失标记（玩家摸牌时）：这张牌如同不存在般消失 → 补摸下一张（最多连跳 3 张防连锁）
    if card and not hitCtx.force_draw_card then
        for _ = 1, 3 do
            local vm = card.uid and GameState.markUidMap(state)[card.uid] or nil
            if vm and (vm.kind or "ink") == "vanish" then
                state.deck:toDiscard(card)
                card = state.deck:drawFor(true, (state._drawRestrict and state._drawRestrict.player) and true or nil)
                GameState.markFx(state, "vanish", "deck")   -- 效果动画：灰白牌影在牌堆处消散
                state._flashMsg = {
                    text    = "消失标记：一张牌如同不存在般消失了（补摸下一张）",
                    expires = love.timer.getTime() + FLASH_DURATION,
                }
            else
                break
            end
        end
    end

    -- 给牌类遗物发下的牌（force_draw_card）不能被卡包截走，否则遗物效果被静默吞掉；
    -- 此时卡包这一轮不存牌，下一次要牌会重新尝试存
    if _cardPackAction == "store" and card and not hitCtx.force_draw_card then
        -- 存牌模式：不加入手牌，存进卡包
        state._cardPackStored = card
        state._flashMsg = {
            text = "卡包已存: " .. (card.rank .. card.suit),
            expires = love.timer.getTime() + 1.5,
        }
        card = nil   -- 阻止后续 insert
    end

    if card then table.insert(state.player.hand, card) end

    -- ===== 黑洞牌组：黑洞牌吸收上一张手牌 =====
    if card and card.is_blackhole and #state.player.hand >= 2 then
        local prev = state.player.hand[#state.player.hand - 1]
        if prev then
            -- 继承特性（倍率 / RPS / 67 词条）
            card.mult_bonus = (card.mult_bonus or 0) + (prev.mult_bonus or 0)
            card.is_rps = card.is_rps or prev.is_rps
            card.is_67  = card.is_67  or prev.is_67
            card.is_cage = card.is_cage or prev.is_cage   -- 继承牢笼 → 黑洞牌自己成为牢笼牌
            card.is_chip = card.is_chip or prev.is_chip   -- 继承筹码 → 黑洞牌自己也算筹码牌
            -- 只继承标记不够：RPS 靠 rank 判"石/剪/布"、67 靠 rank/value 判 6/7，
            -- 而黑洞牌自己的 rank 是扑克点数 → 单独记下继承来的判定值，避免判定失效
            if prev.is_rps then
                card.rps_symbol = card.rps_symbol or prev.rps_symbol or prev.rank
            end
            if prev.is_67 then
                card.s67_rank = card.s67_rank or prev.s67_rank or prev.value or prev.rank
            end
            -- 吸收：移除上一张（守恒回收）
            state.deck:toDiscard(table.remove(state.player.hand, #state.player.hand - 1))
            state._flashMsg = {
                text = "黑洞牌吸收了: " .. tostring(prev.rank) .. (prev.suit or ""),
                expires = love.timer.getTime() + 1.8,
            }
        end
    end

    -- ===== 特殊标记触发（玩家摸到）：爆炸（消失已在抽牌前处理）=====
    -- 虚空标记已改为"标记瞬间"立即吸收上一张（见 tryMarkCard / voidAbsorbPrev），摸到时不再触发
    -- 位置铁律：必须在牌插入手牌之后
    if card and card.uid then
        local pm = GameState.markUidMap(state)[card.uid]
        if pm and (pm.kind or "ink") == "bomb" then
            GameState.explodeAfter(state, card)
        end
    end

    state.firstHitThisRound = false

    local total = Blackjack.calculateHand(state.player.hand)

    -- 遗物: 爆牌时自动换成 5
    if total > 21 and hitCtx.auto_five_if_bust then
        local last = state.player.hand[#state.player.hand]
        if last then
            last.rank = 5
            total = Blackjack.calculateHand(state.player.hand)
        end
    end

    -- 恰好 21 点（hit 出来的，不是 natural BJ）→ 收银机"叮" + 商店提前一回合
    if total == 21 and not Blackjack.isBlackjack(state.player.hand) then
        if Sfx and Sfx.play21 then Sfx.play21() end
        GameState.onExact21(state)
    end

    -- ========== 67 卡组组合技：同时有 s67 的 6 和 s67 的 7 → 填满到 12 张 ==========
    if GameState.check67Combo(state) then
        -- 填满后直接进入庄家回合（safe_hit 已在 check67Combo 里隐含，不会爆）
        state.state = "dealer"
        GameState.dealerAction(state)
        return
    end

    if total > 21 and not hitCtx.safe_hit then
        GameState.endRound(state)
    elseif total > 21 and hitCtx.safe_hit then
        state.deck:toDiscard(table.remove(state.player.hand))
        state.state = "dealer"
        GameState.dealerAction(state)
    end
end

function GameState.standPlayer(state)
    if state.state ~= "player" then return end
    state.state = "dealer"
    GameState.dealerAction(state)
end

-- ============================================================
-- 加倍（double down，阶段3）：首两张可加倍 —— 注码翻倍，只再要一张
-- ============================================================
function GameState.canDoubleDown(state)
    if state.state ~= "player" then return false end
    if #(state.player.hand or {}) ~= 2 then return false end
    if state._natural_bj or state._s67_triggered then return false end
    if (state.player.chips or 0) < (state.player.bet or 0) then return false end
    if state.player.bet <= 0 then return false end
    if isCageLocked(state.player.hand) then return false end   -- 牢笼封锁本质是要牌
    return true
end

function GameState.doubleDown(state)
    if not GameState.canDoubleDown(state) then return false end
    -- 注码翻倍（主注在下注时已扣过一次）
    state.player.chips = state.player.chips - state.player.bet
    state.player.bet = state.player.bet * 2
    state._doubled = true
    state.events:trigger("double_down", { game = state, bet = state.player.bet })
    -- 只再要一张（复用要牌通道：尊重固有牌过滤遗物）
    local basicOnly = (state._drawRestrict and state._drawRestrict.player) and true or nil
    local card = state.deck:drawFor(true, basicOnly)
    if card then table.insert(state.player.hand, card) end
    state._flashMsg = {
        text    = "加倍！注码 $" .. state.player.bet .. "，只再要一张",
        expires = love.timer.getTime() + FLASH_DURATION,
    }
    local total = Blackjack.calculateHand(state.player.hand)
    if total == 21 then
        GameState.onExact21(state)         -- 加倍后恰好 21：商店提前一回合
    end
    if total > 21 then
        GameState.endRound(state)          -- 加倍爆牌：立即结算
    else
        state.state = "dealer"
        GameState.dealerAction(state)
    end
    return true
end

-- Rider / 骑之残卷：跳过本回合（归还下注）
-- 职阶 Rider 用 classCharges（3 次）；骑之残卷点亮后本小局可跳过一次
function GameState.skipRound(state)
    if state.state ~= "player" then return end
    if state.class and state.class.id == "rider" then
        if (state.classCharges or 0) <= 0 then return end

        state.classCharges = state.classCharges - 1
        -- 归还下注（bet 已在 placeBet 时扣掉）
        state.player.chips = state.player.chips + state.player.bet
        state._flashMsg = {
            text = "Rider 发动！跳过本回合，下注 $" .. state.player.bet .. " 已归还（剩余 " .. state.classCharges .. " 次）",
            expires = love.timer.getTime() + 2,
        }
        state.player.bet = 0
        state.result = "push"
        state.state = "dealer"
        GameState.endRound(state)
        return
    end

    -- 骑之残卷：点亮 + 本小局未用过 → 跳过一次（残卷点亮即扣过次数）
    if not state._shardRiderUsed then
        for _, r in ipairs(state.relics or {}) do
            if r.id == "class_rider_shard" and r.active and not r._expired then
                state._shardRiderUsed = true
                r.active = false
                state.player.chips = state.player.chips + state.player.bet
                state._flashMsg = {
                    text = "骑之残卷发动！跳过本回合，下注 $" .. state.player.bet .. " 已归还",
                    expires = love.timer.getTime() + 2,
                }
                state.player.bet = 0
                state.result = "push"
                state.state = "dealer"
                GameState.endRound(state)
                return
            end
        end
    end
end

-- ============================================================
-- 后期投降（遗物 late_surrender）
-- 需要玩家先激活该遗物；点数小于 18 点时可按 [U] 投降，退回一半下注
-- ============================================================
function GameState.canSurrender(state)
    if state.state ~= "player" then return false end
    if Blackjack.calculateHand(state.player.hand) >= 18 then return false end
    for _, r in ipairs(state.relics or {}) do
        if r.id == "late_surrender" and r.active and not r._expired then return true end
    end
    return false
end

function GameState.surrenderPlayer(state)
    if not GameState.canSurrender(state) then return false end
    local refund = math.floor(state.player.bet * 0.5)
    state.player.chips = state.player.chips + refund
    state.player.bet = 0
    state.result = "push"
    state._flashMsg = {
        text = "后期投降：退回一半下注 +$" .. refund,
        expires = love.timer.getTime() + FLASH_DURATION,
    }
    state.state = "dealer"
    GameState.endRound(state, "push")
    return true
end

-- ============================================================
-- Caster 职阶：遗物替换面板（每 3 连胜开启一次）
-- 3 个随机遗物选 1 个，替换掉自己已有的 1 个遗物（也可以不换）
-- ============================================================
function GameState.openClassOffer(state)
    -- 只排除"永久持有且未过期"的（和商店同一套规则）
    local excludeIds = {}
    for _, r in ipairs(state.relics or {}) do
        if not r._consumable and not r._expired then excludeIds[r.id] = true end
    end
    local options = Relics.drawRandom(3, { common = 45, uncommon = 30, rare = 18, legendary = 7 }, excludeIds)
    if #options == 0 or #(state.relics or {}) == 0 then return false end

    state.classOffer = { options = options }
    state.classOfferTarget = nil
    state.classOfferActive = true
    state._afterClassOffer = state.state   -- "result" / "shop"
    -- 模态独占：清掉可能残留的浮层
    state.settingsOpen = false
    state.deckOverviewOpen = false
    state.state = "classOffer"
    return true
end

-- 选中"要换掉的自己的遗物"（relicIndex 对应 state.relics 下标）
-- 术之残卷的 replaceSelf 面板目标已锁定为残卷自身，不许改选
function GameState.selectClassOfferTarget(state, relicIndex)
    if state.state ~= "classOffer" or not state.classOffer then return false end
    if state.classOffer.replaceSelf then return false end
    if not (state.relics and state.relics[relicIndex]) then return false end
    state.classOfferTarget = relicIndex
    return true
end

-- 用第 offerIndex 个候选替换掉选中的遗物
function GameState.takeClassOffer(state, offerIndex)
    if state.state ~= "classOffer" or not state.classOffer then return false end
    if not state.classOfferTarget then return false end
    local offer = state.classOffer.options[offerIndex]
    if not offer then return false end
    if not state.relics[state.classOfferTarget] then return false end

    state.relics[state.classOfferTarget] = offer
    GameState.registerAllRelics(state)
    state._flashMsg = {
        text = "Caster 替换：获得 [" .. tostring(offer.name) .. "]",
        expires = love.timer.getTime() + 2,
    }
    GameState.closeClassOffer(state)
    return true
end

-- 不换 / 关面板：原样回到面板打开前的状态（result 或 shop）
function GameState.closeClassOffer(state)
    if state.state ~= "classOffer" then return end
    state.classOffer = nil
    state.classOfferActive = false
    state.classOfferTarget = nil
    state.state = state._afterClassOffer or "result"
    state._afterClassOffer = nil
end

-- 术之残卷：连胜 3 局 → 三选一替换残卷自身（可拒绝；面板开启即消耗 1 次）
-- 与 openClassOffer 同一套 classOffer 面板，差别是替换目标固定为残卷自己（replaceSelf）
function GameState.openShardOffer(state)
    local shardIndex
    for i, r in ipairs(state.relics or {}) do
        if r.id == "class_caster_shard" and not r._expired then shardIndex = i break end
    end
    if not shardIndex then return false end

    local excludeIds = {}
    for _, r in ipairs(state.relics or {}) do
        if not r._consumable and not r._expired then excludeIds[r.id] = true end
    end
    local options = Relics.drawRandom(3, { common = 45, uncommon = 30, rare = 18, legendary = 7 }, excludeIds)
    if #options == 0 then return false end

    state.classOffer = { options = options, replaceSelf = true }
    state.classOfferTarget = shardIndex   -- 目标预选：直接点候选即可完成替换
    state.classOfferActive = true
    state._afterClassOffer = state.state
    state.settingsOpen = false
    state.deckOverviewOpen = false
    state.state = "classOffer"
    GameState.useRelicPassive(state, "class_caster_shard")
    state._flashMsg = {
        text = "术之残卷觉醒！连胜 3 局 —— 挑一个候选替换它（ESC 可拒绝）",
        expires = love.timer.getTime() + 3,
    }
    return true
end

-- ============================================================
-- 反出千：玩家指认庄家作弊
-- ============================================================
function GameState.accuseDealer(state)
    if state.state ~= "player" then return false end
    if state.cheatState.wasAccused then return false end

    state.cheatState.wasAccused = true

    -- 判定口径：只看「作弊是否实际执行」，不看「庄家是否决定要作弊」
    -- （前置条件未满足、或被玩家职阶 assassin 取消看牌类作弊时，都判为猜错）
    local wasCheating = state.cheatState.cheatExecuted == true

    -- 触发 on_accuse 事件（反作弊遗物可以在这里触发）
    local accuseCtx = { game = state, was_cheating = wasCheating, dealer_hand = state.dealer.hand }
    state.events:trigger("on_accuse", accuseCtx)

    -- 翻牌（让玩家看到）
    for _, card in ipairs(state.dealer.hand) do card.faceUp = true end

    -- 提前结束回合（玩家指认后庄家不再继续要牌）
    state.state = "dealer"

    if wasCheating then
        -- 猜对了！
        state.accuseResult = "correct"
        -- 指认猜对 → 4 件 on_accuse 反制遗物本小局确实生效了（侧边栏状态显示读这份标记）
        GameState.markRelicRoundActive(state, "cheat_reverse")
        GameState.markRelicRoundActive(state, "cheat_sniffer")
        GameState.markRelicRoundActive(state, "cheat_trap")
        GameState.markRelicRoundActive(state, "scales_of_justice")
        -- 强制把结果改成玩家赢（双倍；铁证如山 → 5 倍）
        local bet = state.player.bet
        local ironOn = GameState.hasRelic(state, "iron_evidence")
        local accuseMult = ironOn and 5 or 3
        state._accuseMult = accuseMult   -- _doScoring 修正 winnings 用（扣次后遗物可能已过期）
        state.player.chips = state.player.chips + bet * accuseMult  -- 赢 (mult-1)x + 退回下注
        -- 铁证如山：这次加成真的生效了 → 消耗 1 次
        if ironOn then
            GameState.useRelicPassive(state, "iron_evidence")
        end
        -- 赊账太深时赢回来的钱也可能填不平负数 → 筹码仍 ≤ 0 立即判负结束
        if GameState.checkBrokeNow(state, "赊账太深，指认赢回的钱也填不平！") then return true end
        state.streak = state.streak + 1
        state.screenShake = 10

        -- 视觉反馈
        local w, h = love.graphics.getWidth(), love.graphics.getHeight()
        table.insert(state.scorePopups, {
            text = "猜对了！庄家作弊！ +$" .. (bet * accuseMult),
            x = w / 2, y = h / 2 - 80,
            t = 0, life = 2.5,
            color = {0.2, 1, 0.2}, scale = 2.5
        })

        -- 触发 on_dealer_bust 事件（ctx 与 on_accuse 保持同形，方便监听方直接复用判断）
        state.events:trigger("on_dealer_bust", { game = state, was_cheating = true, dealer_hand = state.dealer.hand })

        GameState.endRound(state)
        return true
    else
        -- 猜错了！庄家没作弊
        state.accuseResult = "wrong"
        -- 惩罚：下注不退，再扣 $50
        local bet = state.player.bet
        local penalty = math.min(50, bet)
        state.player.chips = state.player.chips - penalty
        -- 罚金后筹码 ≤ 0 → 立即判负结束，不再继续本回合（赊账时甚至会扣成负数）
        if GameState.checkBrokeNow(state, "指认失败罚金让你倾家荡产！") then return true end
        state.streak = 0

        -- 视觉反馈
        local w, h = love.graphics.getWidth(), love.graphics.getHeight()
        table.insert(state.scorePopups, {
            text = "错了！庄家没作弊！ -$" .. penalty,
            x = w / 2, y = h / 2 - 80,
            t = 0, life = 2.5,
            color = {1, 0.2, 0.2}, scale = 2
        })

        -- 继续正常庄家行动（现在玩家被惩罚了，庄家有优势）
        GameState.dealerAction(state)
        return true
    end
end

-- ============================================================
-- 庄家 AI（含作弊）
-- ============================================================
function GameState.dealerAction(state)
    -- 酒吧模式：牌堆抽空前先重灌（80 张牌组按样牌重灌，绝不返回 nil）
    GameState.barEnsureDeck(state)

    -- 进庄家回合 → peek 标记清除（所有手牌转正，不管之前有没有 hit）
    if state._peekActive then
        for _, c in ipairs(state.player.hand) do c._peek = false; c.faceUp = true end
        state._peekActive = false
    end

    local dealerCtx = {
        game = state,
        force_dealer_difficulty = nil,
        force_early_stop = false,
        force_dealer_stand_on_soft_17 = false,
        force_dealer_cheat_bust = false,  -- 反作弊遗物：强制庄家爆牌
        blind_dealer = false,             -- 反侦察器遗物：庄家不看你的牌
    }
    state.events:trigger("on_dealer_turn", dealerCtx)

    -- 反作弊遗物强制庄家爆牌
    if dealerCtx.force_dealer_cheat_bust and state.cheatState.isCheating then
        GameState.markRelicRoundActive(state, "cheat_buster_1")   -- 本小局确实生效了
        -- 强制把最后一张牌换成爆牌的高牌
        table.insert(state.dealer.hand, { rank = 10, suit = '♠', faceUp = true })
        table.insert(state.dealer.hand, { rank = 10, suit = '♠', faceUp = true })
        for _, card in ipairs(state.dealer.hand) do card.faceUp = true end
        GameState.endRound(state)
        return
    end

    for _, card in ipairs(state.dealer.hand) do card.faceUp = true end

    local difficulty = dealerCtx.force_dealer_difficulty or state.stageDifficulty[state.stage] or 1
    local playerTotal = Blackjack.calculateHand(state.player.hand)

    -- Assassin 玩家职阶 / 杀之残卷 / 反侦察器遗物：庄家看不到你的牌
    -- → 不把玩家点数交给庄家 AI（阶段 3 的"看明牌出牌"退化掉），它就只是按自己手牌打
    if (state.class and state.class.id == "assassin")
       or GameState.shardActive(state, "class_assassin_shard") then
        playerTotal = nil
    elseif dealerCtx.blind_dealer then
        playerTotal = nil
    end

    local moves = 0
    local maxMoves = dealerCtx.force_early_stop and 3 or 5

    while moves < maxMoves do
        -- 庄家手牌上限（必须在任何 draw/insert 之前）
        if #state.dealer.hand >= HAND_MAX then
            state._flashMsg = {
                text    = "庄家手牌已满 (" .. HAND_MAX .. " 张)",
                expires = love.timer.getTime() + FLASH_DURATION,
            }
            break  -- 庄家停牌，牌堆不消耗
        end

        -- 牢笼：庄家明牌最末尾是牢笼牌 → 不能继续要牌（在抽牌之前拦截）
        if isCageLocked(state.dealer.hand) then
            state._flashMsg = {
                text    = "牢笼封锁 — 庄家明牌最末尾是牢笼牌，庄家停牌",
                expires = love.timer.getTime() + FLASH_DURATION,
            }
            break
        end

        -- 酒吧模式 · 新加坡司令「封口」：本局庄家立即停牌不再抽牌（标记每小局末清空）
        if state.gameMode == "bar" and state._barDealerSealed then break end

        local shouldHit = Blackjack.dealerShouldHit(state.dealer.hand, difficulty, playerTotal, state.dealerClass)
        if dealerCtx.force_dealer_stand_on_soft_17 then
            local dt = Blackjack.calculateHand(state.dealer.hand)
            if dt >= 17 then shouldHit = false end
        end
        if not shouldHit then break end

        -- 火焰标记：庄家的下一张是火焰牌 → 无法要这张牌，只能停牌
        do
            local topC = state.deck.cards[1]
            local tm = topC and topC.uid and GameState.markUidMap(state)[topC.uid] or nil
            if tm and (tm.kind or "ink") == "flame" then
                GameState.markFx(state, "flame", "dealer")   -- 效果动画：庄家手牌处金焰跳动
                state._flashMsg = {
                    text    = "火焰标记：庄家的下一张是火焰牌，只能停牌",
                    expires = love.timer.getTime() + FLASH_DURATION,
                }
                break
            end
        end

        local hitCtx = { game = state, force_dealer_draw = nil }
        state.events:trigger("on_dealer_hit", hitCtx)

        local card
        -- 独享至尊：本小局庄家只能抽固有牌堆的牌
        local dealerBasicOnly = (state._drawRestrict and state._drawRestrict.dealer) and true or nil

        -- 应用作弊 Type B: 抽牌必10
        -- cheatBApplied 只在「真的白送了牌」的三种分支里为真；currentTotal >= 17 时
        -- 走正常抽牌 → 不算「实际执行」，也不该留痕迹（前置条件未满足）
        local cheatBApplied = false
        local cheatDApplied = false
        if state.cheatState.isCheating and state.cheatState.cheatType == 4 then
            -- Type D 神抽：从牌靴深处抽走恰好需要的牌（不消耗顶部牌序）
            -- 前置：当前点数还有救（≤19）才算执行，否则退化为普通抽牌、不留痕迹
            local currentTotal = Blackjack.calculateHand(state.dealer.hand)
            local need = 21 - currentTotal
            local wantRank
            if currentTotal <= 10 then wantRank = 'A'
            elseif need >= 10 then wantRank = 10
            elseif need >= 2 then wantRank = need end
            if wantRank then
                for i, c in ipairs(state.deck.cards) do
                    local match
                    if wantRank == 'A' then match = (c.rank == 'A')
                    elseif wantRank == 10 then
                        match = (c.rank == 10 or c.rank == 'J' or c.rank == 'Q' or c.rank == 'K')
                    else match = (c.rank == wantRank) end
                    if match then
                        card = table.remove(state.deck.cards, i)
                        card.faceUp = true
                        cheatDApplied = true
                        break
                    end
                end
            end
            if not cheatDApplied then
                card = state.deck:drawFor(true, dealerBasicOnly)
            end
        elseif state.cheatState.isCheating and state.cheatState.cheatType == 2 then
            -- 庄家需要牌时，给它好牌（10/A，不爆）
            local currentTotal = Blackjack.calculateHand(state.dealer.hand)
            if currentTotal <= 10 then
                card = { rank = 'A', suit = '♠', faceUp = true }  -- A = 11, 不会爆
                cheatBApplied = true
            elseif currentTotal <= 15 then
                card = { rank = 10, suit = '♥', faceUp = true }   -- 10
                cheatBApplied = true
            elseif currentTotal == 16 then
                card = { rank = 4, suit = '♦', faceUp = true }    -- 4 → 20（不爆）
                cheatBApplied = true
            else
                card = state.deck:drawFor(true, dealerBasicOnly)
            end
        elseif hitCtx.force_dealer_draw then
            card = state.deck:drawFor(true, dealerBasicOnly)
            if card then card.rank = hitCtx.force_dealer_draw end
        else
            card = state.deck:drawFor(true, dealerBasicOnly)
        end

        if card then
            table.insert(state.dealer.hand, card)

            -- 特殊标记触发（庄家摸到）：赏金 / 爆炸（火焰牌庄家摸不到，已在前面拦截）
            local dmk = card.uid and GameState.markUidMap(state)[card.uid] or nil
            if dmk and (dmk.kind or "ink") == "bounty" then
                state.player.chips = state.player.chips + 500
                local bw, bh = love.graphics.getWidth(), love.graphics.getHeight()
                table.insert(state.scorePopups, {
                    text = "+$500 赏金",
                    x = bw / 2, y = bh / 2 - 60,
                    t = 0, life = 1.5,
                    color = { 1, 0.85, 0.2 }, scale = 1.5,
                })
                state._flashMsg = {
                    text    = "赏金标记：庄家上钩了 +$500",
                    expires = love.timer.getTime() + FLASH_DURATION,
                }
            elseif dmk and (dmk.kind or "ink") == "bomb" then
                GameState.explodeAfter(state, card)
            end

            -- 痕迹 B：新抽到的那张牌带金色描边脉冲（单次，由强到弱）
            if cheatBApplied then
                card._tell  = "B"
                card._tellT = love.timer.getTime()
                state.cheatState.cheatExecuted = true
                state.cheatState.cheatTellKind = "B"
                state.cheatState.visualTell    = true
            end

            -- 痕迹 D：紫色描边 + 脉冲（神抽：这张牌是从牌靴深处"变"出来的）
            if cheatDApplied then
                card._tell  = "D"
                card._tellT = love.timer.getTime()
                state.cheatState.cheatExecuted = true
                state.cheatState.cheatTellKind = "D"
                state.cheatState.visualTell    = true
            end

            -- 作弊 Type C: 低牌换掉（抽到 2-6 且还没到 19 就换一张好牌）
            if state.cheatState.isCheating and state.cheatState.cheatType == 3 then
                local last = state.dealer.hand[#state.dealer.hand]
                if last and not last.is_blackhole
                   and type(last.rank) == "number" and last.rank >= 2 and last.rank <= 6 then
                    local afterTotal = Blackjack.calculateHand(state.dealer.hand)
                    if afterTotal < 19 then
                        -- 换掉！痕迹 C：青绿描边 + 旧牌残影（_tellOldRank 记下被换掉的点数）
                        state.deck:toDiscard(last)   -- 被换下的低牌守恒回收
                        state.dealer.hand[#state.dealer.hand] = {
                            rank = 10, suit = '♣', faceUp = true,
                            _tell = "C", _tellT = love.timer.getTime(), _tellOldRank = last.rank,
                        }
                        state.cheatState.cheatExecuted = true
                        state.cheatState.cheatTellKind = "C"
                        state.cheatState.visualTell    = true
                    end
                end
            end

            -- 干扰项 dB/dC：本局没作弊，但表现「像」Type B/C（每小局最多物化一次）
            if not state._distractorShown and not state.cheatState.isCheating then
                local dk = state.cheatState.cheatTellKind
                if dk == "dB" or dk == "dC" then
                    card._tell  = dk
                    card._tellT = love.timer.getTime()
                    state._distractorShown = true
                end
            end

            -- 黑洞牌组：庄家抽到黑洞牌同样吸收上一张（与玩家侧对称）
            if card.is_blackhole and #state.dealer.hand >= 2 then
                local prev = state.dealer.hand[#state.dealer.hand - 1]
                if prev then
                    card.mult_bonus = (card.mult_bonus or 0) + (prev.mult_bonus or 0)
                    card.is_rps  = card.is_rps  or prev.is_rps
                    card.is_67   = card.is_67   or prev.is_67
                    card.is_cage = card.is_cage or prev.is_cage
                    card.is_chip = card.is_chip or prev.is_chip
                    if prev.is_rps then
                        card.rps_symbol = card.rps_symbol or prev.rps_symbol or prev.rank
                    end
                    if prev.is_67 then
                        card.s67_rank = card.s67_rank or prev.s67_rank or prev.value or prev.rank
                    end
                    -- 吸收：移除上一张（守恒回收，与玩家侧对称）
                    state.deck:toDiscard(table.remove(state.dealer.hand, #state.dealer.hand - 1))
                    state._flashMsg = {
                        text = "庄家黑洞牌吸收了: " .. tostring(prev.rank) .. (prev.suit or ""),
                        expires = love.timer.getTime() + 1.8,
                    }
                end
            end

            moves = moves + 1
        end
    end

    GameState.endRound(state)
end

-- ============================================================
-- 下注
-- ============================================================
function GameState.placeBet(state, amount)
    if state.state ~= "bet" then return false end
    amount = math.floor(tonumber(amount) or 0)
    if amount < 1 then return false end   -- 不设最小下注：只要有筹码（≥1）就能下

    -- 检查是否有允许赊账的遗物（与 drawBetSlider / 滑条拖拽同一口径）
    local canCredit, creditLimit = Relics.getCreditInfo(state)

    -- 正常情况: 下注 ≤ 现有筹码
    -- 赊账遗物: 下注 ≤ 现有筹码 + creditLimit
    local maxAllowed = state.player.chips
    if canCredit then
        maxAllowed = state.player.chips + creditLimit
    end

    if amount > maxAllowed then return false end

    -- 阶段 3 强制半额：每次下注必须 ≥ 现有筹码的一半（筹码不足 2 时自然退化为可下任意金额）
    if state.stage and state.stage >= 3 then
        local minHalf = math.floor(state.player.chips / 2)
        if amount < minHalf then
            state._flashMsg = { text = "阶段 3 要求下注至少 $" .. minHalf .. "（现有筹码的一半）", expires = love.timer.getTime() + 2 }
            return false
        end
    end

    state.player.bet = amount
    state.player.chips = state.player.chips - amount
    local betCtx = { game = state, bet = amount }
    state.events:trigger("on_bet", betCtx)
    -- 职阶（on_bet 类）：Archer 在这里点亮"发牌前预览第一张牌"
    GameState.triggerClassEffect(state, "on_bet", betCtx)

    -- 爆注（阶段3）：押庄家爆牌的边注 —— 注码取主注一半，随主注一并押上
    state._bustBet = 0
    state._bustBetOdds = nil
    if state._bustBetOn then
        local stake = math.floor(amount * BUST_BET_FRACTION)
        if stake >= 1 and state.player.chips >= stake then
            state.player.chips = state.player.chips - stake
            state._bustBet = stake
        end
    end

    GameState.dealInitial(state)

    -- 爆注赔率锁定：按开局牌靴成分与庄家明牌计算，本小局不再变（"赔率牌"）
    if state._bustBet and state._bustBet > 0 then
        local ShoeInfo = require("src.shoe_info")
        local difficulty = state.stageDifficulty[state.stage] or 1
        local p = ShoeInfo.dealerBustOdds(state.dealer.hand, state.deck, difficulty)
        if p and p > 0.01 then
            state._bustBetOdds = math.min(BUST_BET_MAX_ODDS, math.max(BUST_BET_MIN_ODDS, BUST_BET_EDGE / p))
        else
            state._bustBetOdds = BUST_BET_MAX_ODDS
        end
        state._flashMsg = {
            text    = string.format("爆注 $%d 已押 · 赔率锁定 %.2f 倍", state._bustBet, state._bustBetOdds),
            expires = love.timer.getTime() + FLASH_DURATION,
        }
    end

    -- ===== 困难模式：Rider 庄家有 3 次主动跳过机会（push，注退回） =====
    if state.gameMode == "hard" and state.dealerClass and state.dealerClass.id == "rider"
       and state.dealerCharges and state.dealerCharges > 0
       and not state._natural_bj and not state._s67_triggered then
        -- 50% 概率触发（让玩家感受到"庄家 Rider 随时可能跳"）
        if love.math.random() < 0.5 then
            state.dealerCharges = state.dealerCharges - 1
            state._flashMsg = {
                text = "庄家 Rider 选择跳过 · 你的下注已退回",
                expires = love.timer.getTime() + 2,
            }
            -- 强制本回合按 push 结算（下注原样退回）
            GameState.endRound(state, "push")
            return true
        end
    end

    -- dealInitial 内部可能已经推进过状态机：
    -- · 开局即爆牌 → 已结算
    -- · autoStandNextRound → 已进入 dealer 并由庄家行动结束回合
    -- 此时绝对不能再把状态改回 "player"，否则会重复结算
    if state.state == "bet" then
        state.state = "player"
    end
    return true
end

-- ============================================================
-- 回合结算
-- ============================================================
-- forcedResult: 可选 — 强制本回合按指定结果结算（"push" 等），由 placeBet 的庄家 Rider 跳过使用
function GameState.endRound(state, forcedResult)
    if forcedResult then state._forcedResult = forcedResult end
    state.events:trigger("on_round_end_before", { game = state })

    for _, card in ipairs(state.dealer.hand) do card.faceUp = true end
    GameState.noteMarksSeen(state)   -- 标记"已见过"补记（此时两手已全部翻明）

    -- 反出千巡查（v2）：庄家明牌时才做一次判定 —— 手牌（明牌）里藏着墨水牌，单次 2% 掷骰。
    -- 旧版在每次要牌时判定，一手多次要牌累积概率远超 2%（用户实测"一下就被逮"的根因）。
    GameState.rollMarkDiscovery(state)

    -- ===== Saber 斩击动画（玩家 Saber 斩庄家最小；庄家 Saber 斩玩家最小）=====
    local targetCard, targetHand, targetSide = nil, nil, nil   -- targetSide: "player" | "dealer"
    local saberAttacker = nil
    local Blackjack = require("src.blackjack")

    -- 玩家 Saber / 剑之残卷 → 斩庄家手最小（职阶优先；残卷不与职阶叠加）
    local classSaberOn = state.class and state.class.id == "saber" and not state.class._consumed
    local shardSaberOn = (not classSaberOn) and GameState.shardActive(state, "class_saber_shard")
    if classSaberOn or shardSaberOn then
        local worstVal = 999
        for _, c in ipairs(state.dealer.hand) do
            local v = Blackjack.cardValue(c)
            if v < worstVal then worstVal = v; targetCard = c end
        end
        if targetCard and #state.dealer.hand >= 2 then
            targetHand = state.dealer.hand
            targetSide = "dealer"
            saberAttacker = "player"
            if shardSaberOn then
                -- 残卷这次真的斩到了 → 扣次 + 本小局生效标记（职阶斩不扣残卷）
                GameState.useRelicPassive(state, "class_saber_shard")
                GameState.markRelicRoundActive(state, "class_saber_shard")
            end
        end
    end

    -- 困难模式：庄家 Saber → 斩玩家手最小
    if not saberAttacker and state.gameMode == "hard"
       and state.dealerClass and state.dealerClass.id == "saber" then
        local worstVal = 999
        for _, c in ipairs(state.player.hand) do
            local v = Blackjack.cardValue(c)
            if v < worstVal then worstVal = v; targetCard = c end
        end
        if targetCard and #state.player.hand >= 2 then
            targetHand = state.player.hand
            targetSide = "player"
            saberAttacker = "dealer"
        end
    end

    if saberAttacker and targetCard then
        -- 启动斩击动画（0.9s），动画结束后再 remove + calculate
        state._saberAnim = {
            startAt = love.timer.getTime(),
            duration = 0.9,
            card = targetCard,
            hand = targetHand,
            side = targetSide,
            attacker = saberAttacker,
        }
        -- 让主循环跳过 calculate —— 在 finishSaberAnim 里再调
        return
    end

    GameState._doScoring(state)
end

-- 真正执行 Scoring.calculate（动画结束后调）
function GameState._doScoring(state)
    -- 骰子牌：结算前统一掷骰（全部结算路径的唯一汇合点 —— endRound 与 Saber 动画收尾都到这里）
    -- 只在此处调用一次；令牌 = 本小局（state.turn 每小局 +1，基础 resetRound / 酒吧 barResetRoundFields 都递增），
    -- 同一小局内重复进入结算不会改变已冻结的结果，新小局令牌变化则自动重掷。
    local diceToken = (state.gameMode or "base") .. "#" .. tostring(state.turn or 0)
    Blackjack.rollDice(state.player and state.player.hand, diceToken)
    Blackjack.rollDice(state.dealer and state.dealer.hand, diceToken)

    -- 标记 Saber 已被动画阶段手动处理过 — 防止 scoring.lua 里的 effect 再次斩
    if state.class and state.class.id == "saber" then state.class._consumed = true end
    -- 统一用一个全局 flag — scoring.lua 两端都检查这个
    state._saberConsumed = true

    local details = Scoring.calculate(state, state.events)

    -- 如果是玩家指认结果，已经提前处理过 winnings 了
    if state.accuseResult then
        state.lastScoreDetails = details
        -- 用指认结果覆盖 details 和 state.result
        if state.accuseResult == "correct" then
            state.result = "player"
            details.result = "player"
            -- 修正 winnings 为实际加的 bet*accuseMult（铁证如山 → 5 倍；倍率在指认时已定格）
            local accuseMult = state._accuseMult or (GameState.hasRelic(state, "iron_evidence") and 5 or 3)
            state._accuseMult = nil
            details.winnings = state.player.bet * accuseMult
            details.netChange = state.player.bet * (accuseMult - 1)
            details.xMultProd = details.xMultProd * 2  -- 视觉反馈
        elseif state.accuseResult == "wrong" then
            state.result = "dealer"
            details.result = "dealer"
            details.winnings = 0
            details.netChange = -math.min(50, state.player.bet)
        end
    else
        state.lastScoreDetails = details
        state.result = details.result
        state.player.chips = state.player.chips + details.winnings
    end

    -- ===== 爆注结算（阶段3）：押庄家爆 —— 命中返还本金×赔率，未命中已随注没收 =====
    if state._bustBet and state._bustBet > 0 then
        local hedgeOn = GameState.hasRelic(state, "hedge_fund")   -- 对冲基金：命中彩金 ×1.25 / 未中返半注
        local dealerTotal = Blackjack.calculateHand(state.dealer.hand)
        if dealerTotal > 21 then
            local payMult = (state._bustBetOdds or 2)
            if hedgeOn then payMult = payMult * 1.25 end
            local pay = math.floor(state._bustBet * payMult)
            state.player.chips = state.player.chips + state._bustBet + pay
            state._flashMsg = {
                text    = string.format("爆注命中！庄家爆了 → 本金 $%d + 彩头 $%d", state._bustBet, pay),
                expires = love.timer.getTime() + FLASH_DURATION,
            }
            details.bustBetWin = true
        else
            -- 对冲基金：爆注未中，返还一半注
            if hedgeOn then
                local refund = math.floor(state._bustBet / 2)
                state.player.chips = state.player.chips + refund
                state._flashMsg = {
                    text    = "对冲基金：爆注未中，返还一半 $" .. refund,
                    expires = love.timer.getTime() + FLASH_DURATION,
                }
            end
        end
        -- 对冲基金：这次爆注结算它真的参与了对冲 → 消耗 1 次
        if hedgeOn then
            GameState.useRelicPassive(state, "hedge_fund")
        end
        state._bustBet = 0
        state._bustBetOdds = nil
    end

    -- 债务收藏家：输掉一局时先扣掉这笔债（描述："输了先扣这 $5000"）
    if details.result == "dealer" and state.accuseResult ~= "correct" and (state.debt or 0) > 0 then
        local owed = state.debt
        state.player.chips = state.player.chips - owed
        state.debt = 0
        state._flashMsg = {
            text = "债务清偿 -$" .. math.floor(owed),
            expires = love.timer.getTime() + 2,
        }
    end

    if details.result == "player" or state.accuseResult == "correct" then
        state.streak = state.streak + 1
    else
        state.streak = 0
    end

    -- 酒吧模式：不进阶段 / 商店 / 破产分支，走独立的局末流程后返回
    if state.gameMode == "bar" then
        GameState._barAfterScoring(state, details)
        return
    end

    -- ===== 阶段3 即时胜利：筹码达标直接通关，不等 30 局 =====
    --（刷榜口径：越少小局通关越好，roundsPlayed 在 resetRound 里累计）
    if state.stage >= 3 and (state.player.chips or 0) >= (state.stageMinChips[3] or 0) then
        GameState.recordVictory(state)
        state.state = "victory"
        return
    end

    -- ===== 困难模式：庄家连胜计数 + Caster 每3连胜加遗物 =====
    if state.gameMode == "hard" and state.dealerClass then
        if details.result == "dealer" and not state.accuseResult then
            state.dealerStreak = state.dealerStreak + 1
            if state.dealerClass.id == "caster" and state.dealerStreak > 0 and state.dealerStreak % 3 == 0 then
                -- 每 3 连胜：从所有遗物里随机选一个加入（最多 5 件）
                if #state.dealerRelics < 5 then
                    local Relics = require("src.relics")
                    local all = Relics.LIBRARY
                    local ids = {}
                    for id, _ in pairs(all) do table.insert(ids, id) end
                    local chosenId = ids[love.math.random(1, #ids)]
                    local chosen = all[chosenId]
                    table.insert(state.dealerRelics, { id = chosenId, name = chosen.name })
                    state._flashMsg = {
                        text = "庄家 Caster 第 " .. state.dealerStreak .. " 连胜 · 获得遗物 [" .. chosen.name .. "]",
                        expires = love.timer.getTime() + 2,
                    }
                end
            end
        else
            state.dealerStreak = 0
        end
    end

    -- 视觉爽感
    local popupAmount = details.winnings
    if popupAmount ~= 0 and not state.accuseResult then
        local w, h = love.graphics.getWidth(), love.graphics.getHeight()
        table.insert(state.scorePopups, {
            text = (popupAmount > 0 and "+" or "") .. "$" .. math.floor(popupAmount),
            x = w / 2, y = h / 2,
            t = 0, life = 2.0,
            color = popupAmount > 0 and {0.3, 1, 0.3} or {1, 0.3, 0.3},
            scale = math.abs(popupAmount) > 50 and 2 or 1
        })
    end
    if details.xMultProd and details.xMultProd > 1.5 then
        state.screenShake = math.min(8, (details.xMultProd - 1) * 3)
    end

    -- ===== 21 至尊：直接判阶段胜利 + 奖励阶段目标筹码 + 强制跳阶段 =====
    if details.twentyone_supreme_hit then
        local reward = state.stageMinChips[state.stage] or 0
        state.player.chips = state.player.chips + reward
        state._flashMsg = {
            text = string.format("21 至尊触发！直接判阶段胜利 +$%d 筹码！", reward),
            expires = love.timer.getTime() + 2,
        }
        state._forceStageClear = true
    end

    -- 阶段计数（21 至尊跳过计数）
    if not details.twentyone_supreme_hit then
        state.roundsInStage = state.roundsInStage + 1
    end

    -- 阶段切换（21 至尊无条件触发；否则需要达到 stageEveryN 回合数）
    -- 标记罚金已在本回合中途判负（checkBrokeNow 置 forceExit）时不再推进阶段/淘汰判定
    if state.state ~= "forceExit" and (state._forceStageClear or state.roundsInStage >= (state.stageEveryN[state.stage] or 15)) then
        state._forceStageClear = nil   -- 清标记
        local minChips = state.stageMinChips[state.stage] or 0
        if state.player.chips < minChips then
            state.exitReason = "阶段 " .. state.stage .. " 淘汰！筹码不足 $" .. minChips
            state.quitTimer = 3; state.state = "forceExit"
            Sfx.playGetout()   -- 滚出去音效（所有 forceExit 都播，只播一遍）
            GameState.recordRunStats(state)   -- 记录最高到达阶段 / 最高筹码（事件驱动写盘）
            return
        elseif state.stage >= 3 then
            state.state = "victory"
            GameState.recordVictory(state)    -- 通关记录（口径：进入 victory 时 gameMode == "hard"）
            return
        else
            state.events:trigger("on_stage_clear", { game = state, cleared_stage = state.stage })
            state.stage = state.stage + 1
            state.roundsInStage = 0
            state._pendingShoe = true   -- 换靴节拍：下一次回桌时执行（resetRound 钩子）
            -- 引导：每次新游戏内首次进入阶段 2 时弹一次说明（模态，纯阅读 + 点确认）
            if state.stage == 2 and not state._stage2BriefShown then
                state._stage2BriefShown = true
                state._stage2BriefOpen = true
                -- 独占输入：清掉所有残留浮层
                state.settingsOpen = false
                state.deckOverviewOpen = false
                state.classOfferActive = false
                state.classOffer = nil
            end
            state.events:trigger("on_stage_start", { game = state, new_stage = state.stage })
            -- 困难模式：庄家阶段切换时转职（换成不同于当前的另一个）
            if state.gameMode == "hard" and state.dealerClass then
                local Classes = require("src.classes")
                state.dealerClass = Classes.randomAnother(state.dealerClass)
                state.dealerCharges = (state.dealerClass.id == "rider") and 3 or 0
                state.dealerStreak = 0
                state.dealerRelics = {}
            end
            -- 职阶只在 2 → 3 切换时选，1 → 2 正常进 stageClear
            if state.stage >= 3 then
                state.state = "classSelect"
            else
                state.state = "stageClear"
            end
            return
        end
    end

    -- 破产检查（autoEndOnBroke=false 时留个"赊账模式"，筹码负数游戏继续）
    -- 标记费用/罚金/指认罚金若已在本回合中途触发 checkBrokeNow（forceExit），这里只补 wentBroke 语义（音效/统计已播过）
    local autoEnd = state.settings and state.settings.autoEndOnBroke ~= false
    local wentBroke = (state.state == "forceExit")
    if not wentBroke and autoEnd then
        if state.player.chips < 0 then
            state.exitReason = "破产！筹码变负数！赌债追上门了！"
            state.quitTimer = 3; state.state = "forceExit"; wentBroke = true
        elseif state.player.chips <= 0 then
            state.exitReason = "没钱了！筹码归零！"
            state.quitTimer = 3; state.state = "forceExit"; wentBroke = true
        end
        if wentBroke then
            Sfx.playGetout()   -- 滚出去音效（所有 forceExit 都播，只播一遍）
            GameState.recordRunStats(state)   -- 记录最高到达阶段 / 最高筹码（事件驱动写盘）
        end
    end
    if not wentBroke then
        state.roundsSinceShop = state.roundsSinceShop + 1
        if state.roundsSinceShop >= state.shopEveryN then
            state.roundsSinceShop = 0; state.state = "shop"
            local DeckTypes = require("src.deck_types")
            local champOk = require("src.champion").isAvailable(state)   -- 冠军牌组：解锁 + 满 36 张才进池

            -- ===== 2% 概率：纯牌组商店 =====
            local curDecks = (state._baseDecks or 1) - (state._removedDecks or 0)
            if love.math.random() < 0.02 then
                state._pureDeckShop = true
                state.shopOfferings = {}   -- 遗物栏为空
                state.shopDeckOfferings = DeckTypes.generateShopOffer(5, state.stage, champOk, curDecks)
            else
                state._pureDeckShop = nil
                state.shopOfferings = Relics.generateShopOfferings(state.relics)
                state.shopDeckOfferings = DeckTypes.generateShopOffer(1, state.stage, champOk, curDecks)
            end
            state.shopRerollCost = 200   -- 进新商店 → 刷新费重置
            GameState.rollShopDiscount(state)   -- 打折位：每店掷一次（位置 2-9 折，重刷不重掷）
            GameState.rollForgeOffer(state)   -- 铸造按键：二阶段以后 20% 出现（每店掷一次，重刷不重掷）
        else
            state.state = "result"
        end
    end

    -- ===== Caster 职阶 / 术之残卷：每 3 连胜开一次遗物替换面板 =====
    -- 放在阶段/商店判定之后：面板关掉后原样回到 result / shop（商店内容已经生成好，不受影响）
    -- 职阶 Caster：三选一替换任意一件自己的遗物；术之残卷：三选一替换残卷自身
    if details.result == "player"
       and state.streak > 0 and state.streak % 3 == 0
       and (state.state == "result" or state.state == "shop") then
        if state.class and state.class.id == "caster" then
            GameState.openClassOffer(state)
        elseif GameState.hasRelic(state, "class_caster_shard") then
            GameState.openShardOffer(state)
        end
    end

    -- 教程钩子：一局结束时推进教程 Phase 2
    if state.tutorial and state.tutorial.active then
        local Tutorial = require("src.tutorial")
        Tutorial.onPlayerAction(state, "round_finished")
    end

    state.events:trigger(EventManager.EVENTS.ROUND_END, { game = state, details = details })
end

-- ============================================================
-- 商店
-- ============================================================
-- 刚好 21 点：商店提前一回合开门。可累计（每次到达刚好 21 都 +1），
-- 开门时随 roundsSinceShop 归零一并刷新。酒吧模式无商店不适用。
function GameState.onExact21(state)
    if state.gameMode == "bar" then return end
    state.roundsSinceShop = (state.roundsSinceShop or 0) + 1
    local remain = math.max(0, (state.shopEveryN or 5) - (state.roundsSinceShop or 0))
    state._flashMsg = {
        text    = "刚好 21 点！商店提前一回合开门"
                  .. (remain > 0 and ("（还差 " .. remain .. " 回合）") or "（本回合结算后开门）"),
        expires = love.timer.getTime() + FLASH_DURATION,
    }
end

-- 商店打折：每次进店随机一个货架位置固定打折（2-9 折，整店固定，重刷不重掷——
-- 折扣跟「位置」不跟商品，位置上的商品换了折扣依旧）。
-- _shopDiscount.slot = 混排货架位置（普通店 1-4 遗物 / 5 牌组；纯牌组店 1-5 牌组）
function GameState.rollShopDiscount(state)
    state._shopDiscount = {
        slot = love.math.random(5),
        rate = love.math.random(2, 9) / 10,   -- 0.2 ~ 0.9
    }
    return state._shopDiscount
end

-- 货架价（单一数据源：drawShop 价格与角标 / tooltip / buyRelic / buyDeck 都走这里）
-- shelfSlot = 混排货架位置；basePrice 已含阶段倍率（遗物传 getStagePrice 结果）
function GameState.shopItemPrice(state, basePrice, shelfSlot)
    local d = state._shopDiscount
    if d and d.slot == shelfSlot then
        return math.max(1, math.floor(basePrice * d.rate))
    end
    return basePrice
end

-- 标记致贫立即判负：沿用 endRound 的两条底线（<0 破产 / =0 筹码归零）。
-- autoEndOnBroke=false（赊账模式）时不踢出。被 tryMarkCard / discoverMark / accuseDealer 在回合中途调用。
function GameState.checkBrokeNow(state, reason)
    if not state or state.state == "forceExit" then return false end
    if state.settings and state.settings.autoEndOnBroke == false then return false end
    local chips = (state.player and state.player.chips) or 0
    if chips > 0 then return false end
    if chips < 0 then
        state.exitReason = "破产！" .. (reason or "筹码变负数！赌债追上门了！")
    else
        state.exitReason = "没钱了！" .. (reason or "筹码归零！")
    end
    state.quitTimer = 3
    state.state = "forceExit"
    Sfx.playGetout()
    GameState.recordRunStats(state)
    return true
end

-- ============================================================
-- 铸造（商店按键）：花 $10000 把一件有次数限制的遗物改为永久生效
-- 二阶段以后的商店 20% 出现，每店限铸一次
-- ============================================================
GameState.FORGE_PRICE = 10000

-- 每店掷一次（进店时调用，重刷不重掷）
function GameState.rollForgeOffer(state)
    state._forgeOffered = (state.stage or 1) >= 2 and love.math.random() < 0.20
    state._forgeUsed = false
    state.forgeSelectOpen = nil
end

-- 可铸造目标：未铸造的消耗品遗物（未过期）+ 未铸造的特种标记
function GameState.forgeTargets(state)
    local targets = {}
    for _, r in ipairs(state.relics or {}) do
        if r._consumable and not r._expired and not r._forged then
            table.insert(targets, { type = "relic", relic = r })
        end
    end
    for _, m in ipairs(state.specialMarks or {}) do
        if not m.forged then
            table.insert(targets, { type = "mark", mark = m })
        end
    end
    return targets
end

-- 点击铸造按键：先过守卫，通过才打开选择面板（此时还未扣款）
function GameState.tryOpenForge(state)
    if state.state ~= "shop" then return false end
    if not state._forgeOffered or state._forgeUsed then return false end
    if #GameState.forgeTargets(state) == 0 then
        state._flashMsg = {
            text    = "你没有有次数限制的遗物",
            expires = love.timer.getTime() + FLASH_DURATION,
        }
        return false
    end
    if (state.player.chips or 0) < GameState.FORGE_PRICE then
        state._flashMsg = {
            text    = "筹码不足 — 铸造需要 $" .. GameState.FORGE_PRICE,
            expires = love.timer.getTime() + FLASH_DURATION,
        }
        return false
    end
    state.forgeSelectOpen = true
    return true
end

-- 面板点选确认：扣款并铸造（目标永久生效；窥牌类由 resetRound 自动点亮）
function GameState.forgeRelic(state, target)
    if state.state ~= "shop" then return false end
    if not state._forgeOffered or state._forgeUsed then return false end
    if not target then return false end
    if (state.player.chips or 0) < GameState.FORGE_PRICE then return false end
    state.player.chips = state.player.chips - GameState.FORGE_PRICE
    if target.type == "relic" then
        target.relic._forged = true
        target.relic._consumable = nil   -- 清掉消耗品属性：所有扣次路径天然失效
        target.relic._usesLeft = nil
    else
        target.mark.forged = true
    end
    state._forgeUsed = true          -- 每店限铸造一次
    state.forgeSelectOpen = nil
    state._flashMsg = {
        text    = "铸造完成！该遗物永久生效（-$" .. GameState.FORGE_PRICE .. "）",
        expires = love.timer.getTime() + FLASH_DURATION + 1,
    }
    return true
end

function GameState.closeForgeSelect(state)
    state.forgeSelectOpen = nil
end

function GameState.buyRelic(state, shopIndex)
    if state.state ~= "shop" then return false end
    local relic = state.shopOfferings and state.shopOfferings[shopIndex]
    if not relic or relic.sold then return false end
    -- 打折位：遗物货架位置 = shopIndex（混排货架 1-4 为遗物）
    local price = GameState.shopItemPrice(state, Relics.getStagePrice(relic, state.stage), shopIndex)
    if state.player.chips < price then return false end
    -- 特种标记：不进遗物栏（不占 5 格），放入遗物栏专属标记区
    if relic.markDot then
        state.player.chips = state.player.chips - price
        GameState.addSpecialMark(state, relic)
        relic.sold = true
        relic._shopPrice = nil   -- 清掉购买时的折扣价快照（ Owned 后 tooltip 走阶段价）
        return true
    end
    -- 计数：有效遗物（未过期的）
    local activeCount = 0
    for _, r in ipairs(state.relics) do if not r._expired then activeCount = activeCount + 1 end end
    if activeCount >= 5 then return false end
    state.player.chips = state.player.chips - price
    GameState.addRelic(state, relic); relic.sold = true; relic._shopPrice = nil; return true
end

function GameState.rerollShop(state)
    if state.state ~= "shop" then return false end
    local price = state.shopRerollCost
    if state.player.chips < price then return false end
    state.player.chips = state.player.chips - price
    -- 下一次刷新翻倍
    state.shopRerollCost = price * 2
    -- 防御：两个货架表必须存在（正常进店流程都会先建好，这里兜底防外部残留 nil）
    state.shopOfferings = state.shopOfferings or {}
    state.shopDeckOfferings = state.shopDeckOfferings or {}

    local DeckTypes = require("src.deck_types")
    local champOk = require("src.champion").isAvailable(state)
    local curDecks = (state._baseDecks or 1) - (state._removedDecks or 0)

    if state._pureDeckShop then
        -- ========== 纯牌组商店：只刷新牌组 ==========
        local newDecks = DeckTypes.generateShopOffer(5, state.stage, champOk, curDecks)
        for i = 1, 5 do
            local old = state.shopDeckOfferings and state.shopDeckOfferings[i]
            if old and old.sold then
                -- sold 保留
            else
                state.shopDeckOfferings[i] = newDecks[i]
            end
        end
    else
        -- ========== 正常商店 ==========
        -- 重刷遗物（保留 sold 栏位）
        local excludeIds = {}
        for _, r in ipairs(state.relics) do
            if not r._consumable and not r._expired then excludeIds[r.id] = true end
        end
        local newRelics = Relics.drawRandom(4, { common = 45, uncommon = 30, rare = 18, legendary = 7 }, excludeIds)
        local remainIdx = 1
        for i = 1, 4 do
            local old = state.shopOfferings and state.shopOfferings[i]
            if old and old.sold then
                -- sold 栏位原样保留
            else
                state.shopOfferings[i] = newRelics[remainIdx]
                remainIdx = remainIdx + 1
            end
        end

        -- 重刷牌组（保留 sold 栏位）
        local newDecks = DeckTypes.generateShopOffer(1, state.stage, champOk, curDecks)
        for i = 1, 1 do
            local old = state.shopDeckOfferings and state.shopDeckOfferings[i]
            if old and old.sold then
                -- sold 保留
            else
                state.shopDeckOfferings[i] = newDecks[i]
            end
        end
    end

    return true
end

-- ============================================================
-- 移动网络遗物：要牌阶段开店一次（每小局限一次）
-- 复用回合结束商店的生成规则；离开商店后回到 player 状态（本小局未结算）
-- ============================================================
function GameState.openPlayerShop(state)
    if state.state ~= "player" then return false end        -- 只能在要牌阶段开店
    if state._mobileShopUsed then return false end          -- 每小局限一次（遗物自己的标记）
    state._mobileShopUsed = true
    state._mobileShopReturn = "player"                      -- leaveShop 回跳目标

    local DeckTypes = require("src.deck_types")
    local champOk = require("src.champion").isAvailable(state)
    local curDecks = (state._baseDecks or 1) - (state._removedDecks or 0)
    if love.math.random() < 0.02 then
        state._pureDeckShop = true
        state.shopOfferings = {}
        state.shopDeckOfferings = DeckTypes.generateShopOffer(5, state.stage, champOk, curDecks)
    else
        state._pureDeckShop = nil
        state.shopOfferings = Relics.generateShopOfferings(state.relics)
        state.shopDeckOfferings = DeckTypes.generateShopOffer(1, state.stage, champOk, curDecks)
    end
    state.shopRerollCost = 200   -- 进新商店 → 刷新费重置
    GameState.rollShopDiscount(state)   -- 打折位：每店掷一次（重刷不重掷）
    GameState.rollForgeOffer(state)   -- 铸造按键：与回合末商店同规则（二阶段以后 20%）
    state.state = "shop"
    return true
end

function GameState.leaveShop(state)
    if state.state ~= "shop" then return end
    -- 要牌阶段用移动网络开的店：回到要牌阶段，本小局继续（不结算、不重置）
    if state._mobileShopReturn == "player" then
        state._mobileShopReturn = nil
        state._pureDeckShop = nil
        state.state = "player"
        return
    end
    GameState.resetRound(state)
end

-- ============================================================
-- 牌组系统：购买 + 注入
-- ============================================================

-- 购买一个牌组 offer，直接注入牌堆（或删除固有牌组）
function GameState.buyDeck(state, deckIndex)
    if state.state ~= "shop" then return false end
    local offer = state.shopDeckOfferings and state.shopDeckOfferings[deckIndex]
    if not offer then return false end
    if offer.sold then return false end
    -- 打折位：纯牌组店货架位置 = deckIndex；普通店唯一牌组固定在混排货架第 5 位
    local price = GameState.shopItemPrice(state, offer.price, state._pureDeckShop and deckIndex or 5)
    if state.player.chips < price then return false end

    local DeckTypes = require("src.deck_types")

    if offer.isRemove then
        -- 删除牌组: 减少固有套数，rebuildDeck 重新生成
        local removeN = offer.removeDecks or 1
        local currentDecks = (state._baseDecks or 6) - (state._removedDecks or 0)
        local newDecks = math.max(0, currentDecks - removeN)
        if newDecks <= 0 then
            state._flashMsg = {
                text = "固有牌组已空，不能再删！",
                expires = love.timer.getTime() + 2,
            }
            return false
        end
        state.player.chips = state.player.chips - price
        state._removedDecks = (state._removedDecks or 0) + removeN
        GameState.rebuildDeck(state)  -- 用新套数重建

        table.insert(state.deckCollections, {
            label   = offer.name,
            typeKey = "remove",
            sizeKey = offer.sizeKey,
            cards   = {},
            price   = offer.price,
            removedDecks = removeN,
        })
    else
        -- 冠军牌组：内容来自玩家自选的 36 张（小 36 / 中 72 / 大 108 = 按遍数复制）
        local cards
        if offer.typeKey == "champion" then
            cards = require("src.champion").buildDeck(state.championCards, offer.sizeKey)
        else
            cards = DeckTypes.generate(offer.typeKey, offer.sizeKey)
        end
        state.player.chips = state.player.chips - price
        state.deck:addCards(cards, offer.name)

        table.insert(state.deckCollections, {
            label   = offer.name,
            typeKey = offer.typeKey,
            sizeKey = offer.sizeKey,
            cards   = cards,
            price   = offer.price,
        })
    end

    offer.sold = true
    return true
end

-- 重建牌堆（包含所有已购特殊牌组，扣除已删除的固有套数）— 永久生效
function GameState.rebuildDeck(state)
    local baseDecks = state._baseDecks or 6
    local removed   = state._removedDecks or 0
    local numDecks  = math.max(0, baseDecks - removed)
    state.deck = require("src.deck").new(numDecks)
    -- 重注入所有已购买的特殊牌组（跳过 delete 类）
    for _, coll in ipairs(state.deckCollections or {}) do
        if coll.cards and #coll.cards > 0 then
            state.deck:addCards(coll.cards, coll.label)
        end
    end
end

-- ============================================================
-- 存档：通关记录 + 冠军牌组编辑（一律事件驱动写盘，绝不每帧写）
-- ============================================================
-- 通关写盘：口径 = 进入 victory 时 gameMode == "hard"（基础模式通关不解锁冠军牌组）
function GameState.recordVictory(state)
    local Persist = require("src.persist")
    if state.gameMode == "hard" then
        Persist.recordVictory(state)     -- 内部已含「最高到达阶段 / 最高筹码」刷新与写盘
    else
        Persist.recordVictoryRounds(state)   -- 基础模式：记最快通关小局（不解锁困难通关）
        Persist.recordRunStats(state)
    end
end

-- 一次游玩结束（破产 / 阶段淘汰）：刷新最高到达阶段与历史最高筹码并写盘
function GameState.recordRunStats(state)
    return require("src.persist").recordRunStats(state)
end

-- 进入冠军牌组编辑界面（模态：打开时清掉所有残留浮层，保证独占输入）
function GameState.openDeckEditor(state)
    local Champion = require("src.champion")
    if not Champion.isUnlocked(state) then return false end

    state.settingsOpen     = false
    state.deckOverviewOpen = false

    -- 工作副本：未保存前绝不动 state.championCards（退出即丢弃）
    state._deckEditorCards = {}
    for _, c in ipairs(state.championCards or {}) do
        table.insert(state._deckEditorCards, Champion.cloneCard(c))
    end
    state._deckEditorPool    = Champion.buildPool()
    state.deckEditorType     = state._deckEditorPool[1] and state._deckEditorPool[1].key or "normal"
    state.deckEditorScroll   = 0
    state.deckEditorDropOpen = false
    state.state = "deckEditor"
    return true
end

-- 退出编辑：丢弃未保存的改动，回主界面
function GameState.closeDeckEditor(state)
    state._deckEditorCards   = nil
    state._deckEditorPool    = nil
    state.deckEditorDropOpen = false
    state.state = "title"
end

-- 保存冠军牌组：必须满 36 张才允许（完成度拦截），写盘后回主界面
function GameState.saveDeckEditor(state)
    local Champion = require("src.champion")
    local cards = state._deckEditorCards or {}
    if not Champion.isComplete(cards) then
        state._flashMsg = {
            text = "必须凑满 " .. Champion.SIZE .. " 张才能保存（当前 "
                   .. Champion.count(cards) .. " 张）",
            expires = love.timer.getTime() + 2,
        }
        return false
    end
    state.championCards = {}
    for _, c in ipairs(cards) do
        table.insert(state.championCards, Champion.cloneCard(c))
    end
    require("src.persist").saveCollection(state)
    state._flashMsg = {
        text = "冠军牌组已保存（" .. Champion.SIZE .. " 张），已加入商店出售",
        expires = love.timer.getTime() + 2.5,
    }
    GameState.closeDeckEditor(state)
    return true
end

-- ============================================================
-- 视觉更新
-- ============================================================
function GameState.updateVisuals(state, dt)
    -- ===== Saber 斩击动画推进 =====
    local sa = state._saberAnim
    if sa then
        local now = love.timer.getTime()
        local elapsed = now - sa.startAt
        sa.t = elapsed   -- UI 渲染用
        if elapsed >= sa.duration then
            -- 动画结束！真正移除那张牌 → 继续结算
            local idx = nil
            for i, c in ipairs(sa.hand) do if c == sa.card then idx = i; break end end
            if idx then state.deck:toDiscard(table.remove(sa.hand, idx)) end   -- 被斩的牌守恒回收
            state._saberAnim = nil
            GameState._doScoring(state)
            return
        end
    end

    -- ===== 钓具鱼钩动画收尾：动画结束后真正改牌库 =====
    local ra = state._rodAnim
    if ra and love.timer.getTime() - ra.startAt >= (ra.duration or 0.8) then
        state._rodAnim = nil
        if state._rodPending then GameState.executeRod(state) end
    end

    -- ===== 特殊标记效果动画到期清除 =====
    local fx = state._markFx
    if fx and love.timer.getTime() - fx.startAt >= (fx.life or 0.9) then
        state._markFx = nil
    end

    if state.screenShake > 0 then
        state.screenShake = math.max(0, state.screenShake - dt * 20)
    end
    for i = #state.scorePopups, 1, -1 do
        local p = state.scorePopups[i]
        p.t = p.t + dt
        p.y = p.y - dt * 60
        if p.t >= p.life then table.remove(state.scorePopups, i) end
    end
end

-- ============================================================
-- 酒吧模式子系统（src/bar_mode.lua）：这里只做注册。
-- bar* 函数本体都在 BarMode 内实现（含 state.bar 容器与调酒/醉酒/主动技能），
-- 对外仍以 GameState.barXxx 的名义调用，调用点零改动。
-- ============================================================
BarMode.bind(GameState, { HAND_MAX = HAND_MAX, FLASH_DURATION = FLASH_DURATION })

return GameState
