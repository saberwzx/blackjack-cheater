-- ============================================================
-- Scoring — 算分管线（多阶段链式计算）
--
-- 最终收益 = base_chips × (1 + 基础 mult) × product(x_mult 叠加)
--
-- 阶段：
--   1. 收集上下文
--   2. 计算 base_chips（传统胜负 × 下注）
--   3. 遗物 on_score_calc 链式触发（chips, mult 加法；x_mult 乘法）
--   4. 应用规则型效果（force_win, half_loss, soft_bust 等）
--   5. 最终结算
-- ============================================================

local Scoring = {}
local Blackjack = require("src.blackjack")

-- ============================================================
-- 构建算分上下文（供遗物效果函数读取）
-- ============================================================
function Scoring.buildContext(game)
    local ctx = {}
    ctx.game           = game      -- ← 必须！遗物们读 stage / bet / debt 都靠这个
    ctx.player_hand    = game.player.hand or {}
    ctx.dealer_hand    = game.dealer.hand or {}
    ctx.player_total   = Blackjack.calculateHand(ctx.player_hand)
    ctx.dealer_total   = Blackjack.calculateHand(ctx.dealer_hand)
    ctx.player_bust    = Blackjack.isBust(ctx.player_hand)
    ctx.dealer_bust    = Blackjack.isBust(ctx.dealer_hand)

    -- 困难模式庄家职阶 effect（对玩家造成困难）
    if game.gameMode == "hard" and game.dealerClass then
        local dc = game.dealerClass
        -- ===== 庄家持有遗物效果（Caster 每 3 连胜 +1 件，最多 5 件）=====
        -- 简化：每件庄家遗物让玩家 total -1 + 庄家 total +0.5
        if game.dealerRelics and #game.dealerRelics > 0 then
            local n = #game.dealerRelics
            ctx.player_total = math.max(2, ctx.player_total - n)
            if ctx.player_bust and ctx.player_total <= 21 then
                ctx.player_bust = false
            end
            ctx.dealer_total = ctx.dealer_total + math.floor(n / 2)
        end

        -- ===== Saber 庄家：结算时斩断玩家最小的一张牌 =====
        -- 注意：如果 endRound 已经启动过斩击动画并手动 remove（_saberConsumed），这里跳过
        if dc.id == "saber" and not game._saberConsumed then
            local chopped, worstVal = nil, 999
            for _, c in ipairs(ctx.player_hand) do
                local v = Blackjack.cardValue(c)
                if v < worstVal then worstVal = v; chopped = c end
            end
            if chopped and #ctx.player_hand >= 2 then
                local newHand = {}
                for _, c in ipairs(ctx.player_hand) do
                    if c ~= chopped then table.insert(newHand, c) end
                end
                ctx.player_total = Blackjack.calculateHand(newHand)
                ctx.player_bust = Blackjack.isBust(newHand)
            end
        -- ===== Berserker 庄家：25 点才爆 + 比玩家大则 force dealer win =====
        elseif dc.id == "berserker" then
            if ctx.dealer_total > 21 and ctx.dealer_total <= 25 then
                ctx.dealer_bust = false
            end
            if not ctx.dealer_bust and ctx.dealer_total > ctx.player_total then
                ctx.force_dealer_win = true
            end
        -- ===== Lancer 庄家：已在 dealInitial 给庄家发了3张牌，这里放宽 dealer_bust =====
        elseif dc.id == "lancer" then
            if #ctx.dealer_hand >= 3 and ctx.dealer_total <= 25 then
                ctx.dealer_bust = false
            end
        end
    end

    -- 67 卡组组合技：触发后永远不算爆牌 + 强制赢 + ×67 倍率
    -- 统一进 ctx（ctx 是唯一数据源，calculate 不再绕回 game）
    ctx.is_67_combo = game._s67_triggered or false
    if ctx.is_67_combo then
        ctx.player_bust = false
        ctx.force_win = true
    end
    ctx.is_blackjack   = Blackjack.isBlackjack(ctx.player_hand)

    -- ========== 石头剪刀布：各有且仅有一张 RPS 牌 → 跳过 BJ，用 RPS 判定 ==========
    local function countRPS(hand)
        local n, lastRank = 0, nil
        for _, c in ipairs(hand or {}) do
            -- 黑洞牌继承 RPS 词条时，符号记在 rps_symbol 上（它自己的 rank 是扑克点数）
            if c.is_rps then n = n + 1; lastRank = c.rps_symbol or c.rank end
        end
        return n, lastRank
    end
    local pRPS, pR = countRPS(ctx.player_hand)
    local dRPS, dR = countRPS(ctx.dealer_hand)
    if pRPS == 1 and dRPS == 1 then
        ctx._rps_mode = true
        -- 胜负表: 石胜剪 / 剪胜布 / 布胜石；平算玩家赢
        if pR == dR then
            ctx.result = "player"          -- 平局玩家赢
        elseif (pR == "石" and dR == "剪")
            or (pR == "剪" and dR == "布")
            or (pR == "布" and dR == "石") then
            ctx.result = "player"
        else
            ctx.result = "dealer"
        end
    end

    ctx.result         = ctx.result or Blackjack.determineWinner(ctx.player_hand, ctx.dealer_hand)
    -- 强制结果（庄家 Rider 跳过 = push，下注原样退回）优先级最高
    if game._forcedResult then ctx.result = game._forcedResult end
    ctx.bet            = game.player.bet or 0
    ctx.chips          = game.player.chips or 0
    ctx.stage          = game.stage or 1

    -- ========== 职阶效果（在遗物链之前执行）==========
    -- 只跑声明了 on_score_calc 的职阶：其余职阶（lancer 发三张 / archer 下注预览 /
    -- assassin 庄家失明 / rider 主动跳过）都在对应时机的 game_state 里实现，
    -- 不能在这里跑（时机不对，跑了也只是空写标记）
    local okCls, Classes = pcall(require, "src.classes")
    local class = game.class
    if okCls and class then
        local cdef = Classes.get(class.id) or Classes.get(class)
        local wantScoreCalc = false
        for _, ev in ipairs((cdef and cdef.triggers) or {}) do
            if ev == "on_score_calc" then wantScoreCalc = true break end
        end
        if wantScoreCalc and cdef.effect then
            cdef.effect(ctx)
        end
    end

    -- 辅助牌型信息（用于条件遗物）
    ctx.has_pair       = Blackjack.hasPair(ctx.player_hand)
    ctx.flush_count    = 0
    if #ctx.player_hand >= 3 then
        local suits = {}
        for _, c in ipairs(ctx.player_hand) do
            suits[c.suit] = (suits[c.suit] or 0) + 1
        end
        for _, cnt in pairs(suits) do
            if cnt > ctx.flush_count then ctx.flush_count = cnt end
        end
    end

    -- 庄家明牌
    if #ctx.dealer_hand >= 2 then
        ctx.dealer_first_face = ctx.dealer_hand[2].rank  -- 经典规则中 index 2 是明牌
    end

    -- 连胜统计（游戏状态中维护）
    ctx.streak = game.streak or 0

    return ctx
end

-- ============================================================
-- 主算分函数
-- 参数：
--   game         — 游戏状态
--   eventManager — 事件管理器
-- 返回：
--   finalChips   — 玩家最终筹码（加上赢的，或减去输的）
--   result       — 胜负结果 "player"/"dealer"/"push"
--   details      — 算分详情表（用于 UI 显示）
-- ============================================================
function Scoring.calculate(game, eventManager)
    local ctx = Scoring.buildContext(game)
    local bet = ctx.bet

    -- ========== Phase 1: 计算基础分（传统 21 点模式） ==========
    -- base_chips = 下注 × 胜负系数
    local baseChips = 0
    if ctx.result == "player" then
        -- 赢：Blackjack 3:2，普通 2:1
        if ctx.is_blackjack then
            baseChips = bet * 1.5  -- Blackjack 赢 3:2
        else
            baseChips = bet * 2    -- 普通赢 2:1
        end
    elseif ctx.result == "push" then
        baseChips = bet  -- 平局退回
    else
        baseChips = 0    -- 输：没有筹码
    end

    -- 初始化算分 values（传给 EventManager 链式修改）
    local values = {
        chips  = 0,     -- 所有遗物累加的 chips
        mult   = 0,     -- 所有遗物累加的 mult
        x_mult = 1,     -- 所有遗物乘法叠加（初始为 1）
    }

    -- ========== Phase 2: 触发遗物效果（链式叠加 + 每步检查 ctx 修改） ==========
    -- 只在 ctx 还没被 67 / class effect 预设时才初始化
    ctx.force_win    = ctx.force_win or false
    ctx.half_loss    = ctx.half_loss or false
    ctx.become_bust  = ctx.become_bust or nil

    -- 如果 67 / class effect 已经 force_win，直接把 ctx.result 改成 player + 重算 baseChips
    if ctx.force_win and ctx.result ~= "player" then
        ctx.result = "player"
        ctx.player_bust = false
        baseChips = bet * 2
    end

    -- 庄家 Berserker force_dealer_win（67 force_win 优先级更高，已在上处理）
    if ctx.force_dealer_win and ctx.result ~= "player" then
        ctx.result = "dealer"
        ctx.dealer_bust = false
        baseChips = 0
    end

    -- 立即计算原始 ctx.result（用于 force_win 对比）
    local _ctx_orig_result = ctx.result

    if eventManager then
        local listeners = eventManager._listeners["on_score_calc"] or {}
        for _, listener in ipairs(listeners) do
            ctx.values = values

            local ok, ret = pcall(listener.fn, ctx)
            if not ok then
                print(string.format("[EventManager] ERROR in listener '%s': %s",
                    listener.id, tostring(ret)))
            elseif ret and type(ret) == "table" then
                for k, v in pairs(ret) do
                    if type(v) == "number" then
                        if k == "x_mult" or k == "xmult" then
                            values[k] = (values[k] or 1) * v
                        else
                            values[k] = (values[k] or 0) + v
                        end
                    elseif type(v) == "boolean" then
                        values[k] = v
                    end
                end
            end

            -- 每个遗物跑完都检查 ctx 修改（force_win / become_bust / result 直接修改）
            if ctx.force_win and ctx.result ~= "player" then
                ctx.result = "player"
                ctx.player_bust = false
                baseChips = bet * 2
            end
            if ctx.become_bust == false and ctx.player_bust then
                ctx.player_bust = false
                ctx.result = Blackjack.determineWinner(ctx.player_hand, ctx.dealer_hand)
                if ctx.result ~= "dealer" then
                    baseChips = bet * 2
                end
            end
            -- 检测 ctx.result 被遗物直接修改（如 dealer_22_push 设 push）
            if ctx.result ~= _ctx_orig_result then
                -- 重新算 baseChips（按新的 result）
                _ctx_orig_result = ctx.result
                if ctx.result == "player" then
                    baseChips = ctx.is_blackjack and bet * 1.5 or bet * 2
                elseif ctx.result == "push" then
                    baseChips = bet
                else
                    baseChips = 0
                end
            end
        end
    end

    -- 67 组合技: ×67 倍率（乘法叠在所有 x_mult 之后）
    if ctx.is_67_combo then
        values.x_mult = (values.x_mult or 1) * 67
    end

    -- ========== 筹码牌组：手牌里每张筹码牌额外提供「点数 × 100」筹码 ==========
    -- 只在玩家赢/平局时发；A 按 1 计（走 Blackjack.cardValue，与点数算法一致）
    -- 黑洞牌吸收筹码牌后会继承 is_chip，因此这里能一并算到
    if ctx.result == "player" or ctx.result == "push" then
        local chipPts = 0
        for _, c in ipairs(ctx.player_hand or {}) do
            if c.is_chip then
                chipPts = chipPts + Blackjack.cardValue(c)
            end
        end
        if chipPts > 0 then
            values.chips = values.chips + chipPts * 100
        end
    end

    -- ========== Phase 3: 合并最终分数 ==========
    -- 公式 = (baseChips + values.chips) × (1 + values.mult) × values.x_mult
    local additiveChips = baseChips + values.chips
    local multFactor = 1 + values.mult

    -- 倍率牌组加成：只在赢的时候生效
    local deckMultBonus = 0
    if ctx.result == "player" or ctx.result == "push" then
        deckMultBonus = Blackjack.collectMultBonuses(ctx.player_hand)
        multFactor = multFactor + deckMultBonus  -- 加法叠加到基础 mult 上
    end

    local xMultFactor = values.x_mult

    -- 防止负数
    additiveChips = math.max(0, additiveChips)

    local winnings = additiveChips * multFactor * xMultFactor

    -- ========== Phase 4: 应用 half_loss ==========
    -- half_loss 只在玩家输的时候生效
    if ctx.half_loss and ctx.result == "dealer" then
        -- 输了只输一半筹码（相当于损失减半）
        -- bet 已经被扣掉了，所以返还一半
        winnings = winnings + (bet * 0.5)
    end

    -- ========== Phase 5: 返回详情（UI 显示用） ==========
    local details = {
        result      = ctx.result,
        bet         = bet,
        baseChips   = baseChips,
        relicChips  = values.chips,
        multAdd     = values.mult,
        xMultProd   = values.x_mult,
        additiveTotal = additiveChips,
        multFactor  = multFactor,
        winnings    = math.floor(winnings),
        -- 原始下注是已经被扣掉的，所以最终净增减 = winnings - bet + (平局退回的 bet)
        netChange   = math.floor(winnings - bet),
        twentyone_supreme_hit = ctx.twentyone_supreme_hit or false,
    }

    return details
end

return Scoring
