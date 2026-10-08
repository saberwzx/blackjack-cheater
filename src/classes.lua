-- ============================================================
-- Classes.lua — 阶段 3 职阶系统
-- 职阶只在通关阶段 2 → 进入阶段 3 时选择一次
-- ============================================================

local Classes = {}

Classes.ALL = {
    saber = {
        id    = "saber",
        name  = "Saber",
        color = { 0.85, 0.2, 0.2 },
        icon  = "S",
        desc  = "结算前斩断庄家最小的一张牌。\n庄家手牌 -1（去掉点数最小的那张），重新比点。",
        triggers = { "on_score_calc" },
        effect = function(ctx)
            -- 如果 endRound 已启动过斩击动画并手动 remove，这里跳过（防止重复斩）
            if ctx.game and ctx.game._saberConsumed then return end
            local Blackjack = require("src.blackjack")
            local dHand = ctx.dealer_hand or {}
            if #dHand < 2 then return end

            -- 找最小点数的那张（用 cardValue 保证和 calculateHand 一致）
            local chopped, worstVal = nil, 999
            for _, c in ipairs(dHand) do
                local v = Blackjack.cardValue(c)
                if v < worstVal then worstVal = v; chopped = c end
            end
            if not chopped then return end

            -- 重装机手牌（去掉最小那张）
            local newHand = {}
            for _, c in ipairs(dHand) do
                if c ~= chopped then table.insert(newHand, c) end
            end
            ctx.dealer_hand  = newHand
            ctx.dealer_total = Blackjack.calculateHand(newHand)
            ctx.dealer_bust  = Blackjack.isBust(newHand)
            -- 注意：不在这里调 determineWinner，留给 calculate() 统一处理 result
        end,
    },

    lancer = {
        id    = "lancer",
        name  = "Lancer",
        color = { 0.2, 0.4, 0.9 },
        icon  = "L",
        desc  = "发牌时初始发三张（合计不超过 21 点），玩家仍可继续要牌。",
        -- 实现位置：game_state.dealInitial 里直接判定 state.class.id == "lancer"
        -- （发三张的时机在发牌前，没法用 on_score_calc 效果表达）
    },

    archer = {
        id    = "archer",
        name  = "Archer",
        color = { 0.85, 0.6, 0.15 },
        icon  = "A",
        desc  = "下注时就能看到自己被发的第一张牌。\n（发牌前左上角会闪一张预览卡）",
        triggers = { "on_bet" },
        effect = function(ctx)
            ctx.game._archer_preview = true
        end,
    },

    rider = {
        id    = "rider",
        name  = "Rider",
        color = { 0.2, 0.75, 0.5 },
        icon  = "R",
        desc  = "要牌阶段按 [R] 可直接跳过这一局（可发动 3 次），跳过的话下注归还。",
        charges = 3,
        triggers = { "on_round_start" },
        -- 主动效果 — 玩家在 UI 上点 "跳过本回合" 按钮触发
    },

    caster = {
        id    = "caster",
        name  = "Caster",
        color = { 0.55, 0.2, 0.85 },
        icon  = "C",
        desc  = "每连胜 3 次，从 3 个随机遗物中挑 1 个替换 1 个现有遗物（也可以不换）。",
        -- 实现位置：game_state._doScoring 末尾判定连胜 → GameState.openClassOffer 开替换面板
        -- （需要"本局最终胜负"和连胜数，只有算分结束后才知道）
    },

    assassin = {
        id    = "assassin",
        name  = "Assassin",
        color = { 0.3, 0.3, 0.35 },
        icon  = "X",
        desc  = "庄家无法看到你的所有牌。\n（庄家作弊 AI 不会把你的牌算进去，也不会看你的手牌出千）",
        -- 实现位置：game_state.dealerAction（不把玩家点数交给庄家 AI）+ dealInitial 的作弊 Type A 拦截
    },

    berserker = {
        id    = "berserker",
        name  = "Berserker",
        color = { 0.9, 0.15, 0.1 },
        icon  = "B",
        desc  = "你直到 25 点都不会爆牌，最后只要你比庄家大则判胜。\n（67 组合技触发时不覆盖，67 始终优先）",
        triggers = { "on_score_calc" },
        effect = function(ctx)
            -- 67 组合技已经 force_win + 不爆，Berserker 不覆盖
            if ctx.force_win then return end
            local pTotal = ctx.player_total
            -- 把 player_bust 放宽到 >25
            if pTotal <= 25 and pTotal > 21 then
                ctx.player_bust = false
                -- 只要比庄家大 → 判赢
                if pTotal > ctx.dealer_total then
                    ctx.result = "player"
                end
            elseif pTotal > 25 then
                ctx.player_bust = true
            end
        end,
    },
}

Classes.LIST_ORDER = { "saber", "lancer", "archer", "rider", "caster", "assassin", "berserker" }

function Classes.get(id)
    return Classes.ALL[id]
end

-- 返回职阶定义的运行时副本（浅拷贝）
-- 运行时标记（如 saber 的 _consumed）只能写在副本上，
-- 否则会污染 Classes.ALL 里的全局定义，跨局/跨周目残留
function Classes.getRuntime(id)
    local def = Classes.ALL[id]
    if not def then return nil end
    local copy = {}
    for k, v in pairs(def) do copy[k] = v end
    return copy
end

function Classes.allIds()
    return Classes.LIST_ORDER
end

-- 随机选一个职阶
-- 统一使用 love.math.random（全工程唯一随机源，已在 main.lua 显式播种）
function Classes.random()
    local n = #Classes.LIST_ORDER
    return Classes.getRuntime(Classes.LIST_ORDER[love.math.random(1, n)])
end

-- 随机选一个和 existing 不一样的职阶（existing=nil 等价于 random()）
function Classes.randomAnother(existing)
    if not existing then return Classes.random() end
    local existingId = type(existing) == "string" and existing or existing.id
    local pool = {}
    for _, id in ipairs(Classes.LIST_ORDER) do
        if id ~= existingId then table.insert(pool, id) end
    end
    if #pool == 0 then return Classes.getRuntime(Classes.LIST_ORDER[love.math.random(1, #Classes.LIST_ORDER)]) end
    return Classes.getRuntime(pool[love.math.random(1, #pool)])
end

return Classes
