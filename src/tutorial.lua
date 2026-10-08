-- ============================================================
-- Tutorial.lua — 教程系统（叠加层模式）
--
-- 设计原则：
--   1. 先介绍规则（纯文字），再让玩家实际操作 — 不突兀
--   2. requireAction=true 的阶段：玩家必须实际操作，onClickContinue 拒绝推进
--   3. 所有 body 严格 ≤ 5 行，每行 ≤ 22 字 — 防止 UI 卡片溢出
--   4. manualAdvance=true 的阶段：纯文字介绍，点继续即可
-- ============================================================

local Tutorial = {}

-- 阶段定义
-- 键必须是连续的 [1..N]（GDD §22.4 #17：旧版 [10]/[11] 重复键导致后写覆盖前写，
-- 「激活你的遗物」「手牌上限」两步被静默吞掉 —— 现在按顺序连续编号，尾部总结带 finalPhase）
Tutorial.PHASES = {
    -- ========== 第一轮：热身 ==========
    [1] = {
        title = "欢迎来到 21 点赌场",
        body  = "先玩一局最普通的 21 点热热身。\n\n操作：拖下注滑条 -> 点【确认下注】\n\n[警告] 输光筹码会被踢出游戏！",
        requireAction = "bet_placed",
        actionHint    = "需要你先下注",
    },
    [2] = {
        title = "发牌",
        body  = "发了两张牌。\n庄家一张明牌一张暗牌盖着。\n\n操作：【Hit 要牌】或【Stand 停牌】",
        requireAction = "round_finished",
        actionHint    = "需要完成这一局",
    },

    -- ========== 规则介绍 ==========
    [3] = {
        title = "胜负规则",
        body  = "规则：\n  . 不爆且比庄大 -> 赢 2 倍\n  . 21 点 -> 赢 3:2\n  . 爆了 -> 输\n  . 平手 -> 退回下注",
        manualAdvance = true,
    },

    -- ========== 牌堆 + 情报层 ==========
    [4] = {
        title = "牌堆是什么",
        body  = "牌堆就是一叠牌。\n每局开始前会重洗。\n商店可买牌组永久注入。\n\n点左上角小牌堆图标\n或按 D 键查看全部牌。",
        manualAdvance = true,
        pos = "left_top",
    },
    [5] = {
        title = "打开牌堆",
        body  = "现在请你打开牌堆看看。\n\n点左上角的小牌堆图标，\n或者按 D 键。",
        requireAction = "deck_opened",
        actionHint    = "需要你打开牌堆",
    },
    [6] = {
        title = "关闭牌堆",
        body  = "好，现在再把它关掉。\n\n按 D 键或 ESC 即可关闭。",
        requireAction = "deck_closed",
        actionHint    = "需要你关闭牌堆",
    },
    [7] = {
        title = "情报层：牌靴不是黑箱",
        body  = "庄家的牌靴不是黑箱。\n\n点左上角【情报】按钮（或按 I）：\n看牌靴成分、庄家爆牌率、\n标记费余额 —— 算准再动手。",
        requireAction = "shoe_info_opened",
        actionHint    = "需要你打开牌靴情报 (I)",
    },

    -- ========== 遗物 ==========
    [8] = {
        title = "遗物系统",
        body  = "遗物给你特殊能力。\n  加筹码、加倍率、改规则...\n上限 5 个，多了只能丢。\n\n遗物怎么来：\n  每局开始前 3 选 1",
        manualAdvance = true,
    },
    [9] = {
        title = "选一个遗物",
        body  = "现在轮到你选第一个遗物了。\n\n看下面弹出来的 3 个，\n点一个你喜欢的。",
        requireAction           = "relic_picked",
        needsManualRelicOffer   = true,
        actionHint              = "需要选一个遗物",
        pos = "left_top",
    },

    -- ========== 激活 ==========
    [10] = {
        title = "遗物怎么生效",
        body  = "遗物不是拿到就自动生效！\n\n右侧遗物栏：灰色 = 未激活。\n你需要手动点击激活它。\n\n激活上限 = 你的手牌数。",
        manualAdvance = true,
    },
    [11] = {
        title = "激活你的遗物",
        body  = "现在你有 2 张牌了。\n\n右侧遗物栏是灰色的。\n点它让它弹出来变彩色！",
        requireAction = "relic_activated",
        actionHint    = "需要激活一个遗物",
        pos = "left_top",
    },

    -- ========== 标记（情报 → 行动）==========
    [12] = {
        title = "标记：给明牌做记号",
        body  = "看中的明牌可以花标记费做记号。\n\n玩家回合点桌上任意一张明牌\n试试（阶段 1 费用 $50/张）。\n\n记号永久可见：牌回到牌靴里\n你也认得它。",
        requireAction = "card_marked",
        actionHint    = "需要给一张明牌做记号",
    },

    -- ========== 手牌上限 ==========
    [13] = {
        title = "手牌上限 12 张",
        body  = "玩家和庄家的手牌\n最多只能有 12 张。\n\n达到上限后继续要牌：\n  提示【手牌已满】\n  这张牌不会被消耗。",
        manualAdvance = true,
    },

    -- ========== 爆注 ==========
    [14] = {
        title = "爆注：押庄家爆牌",
        body  = "下注时可加押【爆注】边注：\n赌庄家爆牌，注码=主注一半。\n赔率按牌靴实时报价、发牌锁定。\n\n下一局下注时按 B 开启试试。",
        requireAction = "bust_bet_toggled",
        actionHint    = "需要切换爆注开关 (B)",
    },

    -- ========== 后期知识 ==========
    [15] = {
        title = "商店与阶段",
        body  = "每 5 轮进入商店，5 个遗物可选。\n阶段越高价格越贵。\n\n3 阶段 x 15 轮：\n  阶段 1 正常 $2000\n  阶段 2 出千 $10000\n  阶段 3 高频出千 $20000",
        manualAdvance = true,
    },
    [16] = {
        title = "铸造：消耗品永久化",
        body  = "窥牌 / 标记类很强，但限次？\n\n商店隔几店出现【铸造】位：\n花 $10000 把一件限次遗物\n或特种标记升级成永久。",
        manualAdvance = true,
    },
    [17] = {
        title = "庄家会出千",
        body  = "阶段 2+ 庄家会作弊：痕迹\n画在被动过的那张牌上，三招\n各不相同；也可能只是「像」\n而已（干扰项）。按 C 指认：\n猜对赢 3 倍下注，猜错罚 $50",
        manualAdvance = true,
    },

    -- ========== 牌组进阶 + 职阶 ==========
    [18] = {
        title = "进阶牌组",
        body  = "商店可买到特殊牌组（永久注入牌堆）：\n  . 67 卡组：一半 6 一半 7，同时持有 → 直接填满 12 张 + ×67 倍率\n  . RPS 石头剪刀布：双方各恰好一张 → 跳过 BJ 用 RPS 判赢\n  . 删除牌组：删固有扑克套数（不能删到 0）",
        manualAdvance = true,
    },
    [19] = {
        title = "7 种职阶",
        body  = "通关阶段 2 后进入黑暗赌场前，你要选一个职阶（永久 30 回合）：\n  . Saber：结算前斩断庄家最小一张牌\n  . Lancer：初始发 3 张（≤21），仍可继续要牌\n  . Archer：下注时看到第一张被发的牌\n  . Rider：按 [R] 跳过本回合 ×3，下注归还\n  . Caster：连胜 3 次 → 3 选 1 替换遗物\n  . Assassin：庄家作弊看不到你的牌\n  . Berserker：25 点才爆，比庄家大直接赢",
        manualAdvance = true,
    },

    -- ========== 总结 ==========
    [20] = {
        title = "准备好你的赌场之旅了吗",
        body  = "你已学会：\n  . 21点 + 牌堆(D) + 情报(I)\n  . 遗物 / 标记 / 爆注(B) / 铸造\n  . 指认出千(C) + 牌组 + 职阶\n\n祝好运，赌徒！",
        manualAdvance = true,
        finalPhase    = true,
    },
}

-- 初始化
function Tutorial.init(state)
    state.tutorial = {
        phase           = 1,
        active          = true,
        phaseReady      = true,
        actionCompleted = false,
    }
end

function Tutorial.currentPhase(state)
    if not state.tutorial or not state.tutorial.active then return nil end
    return Tutorial.PHASES[state.tutorial.phase]
end

-- main.lua 检测到玩家操作后调用
function Tutorial.onPlayerAction(state, actionType)
    local t = state.tutorial
    if not t or not t.active then return false end
    local p = Tutorial.PHASES[t.phase]
    if not p or not p.requireAction then return false end

    if p.requireAction == actionType then
        t.actionCompleted = true
        Tutorial.advance(state)
        return true
    end
    return false
end

-- onClickContinue（叠加层的"继续"按钮）
function Tutorial.onClickContinue(state)
    local t = state.tutorial
    if not t or not t.active then return false end
    local p = Tutorial.PHASES[t.phase]
    if not p then return false end

    -- requireAction 阶段且玩家还没完成 → 拒绝
    if p.requireAction and not t.actionCompleted then
        return false
    end

    Tutorial.advance(state)
    return true
end

function Tutorial.advance(state)
    local t = state.tutorial
    if not t then return end

    t.phase = t.phase + 1

    if t.phase > #Tutorial.PHASES then
        t.active = false
        return
    end

    local nextP = Tutorial.PHASES[t.phase]
    t.actionCompleted = false
    t.phaseReady      = true

    -- 如果新阶段需要手动弹遗物选择
    if nextP and nextP.needsManualRelicOffer then
        -- 先清上一局残留的手牌（Phase 2 round_finished 后一直没清）
        state.player.hand = {}
        state.dealer.hand = {}
        state.player.bet = 0
        state.result = nil
        state.state = "relic_select"

        local Relics = require("src.relics")
        state.pendingRelics = Relics.drawRandom(3, {
            common    = 40,
            uncommon  = 35,
            rare      = 18,
            legendary = 5,
        })
    end
end

function Tutorial.isActive(state)
    return state.tutorial and state.tutorial.active == true
end

-- 当前阶段是否需要阻止 onClickContinue（给 UI 按钮显示提示）
function Tutorial.isBlockedContinue(state)
    local t = state.tutorial
    if not t or not t.active then return false end
    local p = Tutorial.PHASES[t.phase]
    if not p then return false end
    if p.requireAction and not t.actionCompleted then
        return true, p.actionHint
    end
    return false
end

return Tutorial
