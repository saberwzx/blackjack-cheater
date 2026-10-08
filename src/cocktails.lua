-- ============================================================
-- Cocktails — 酒吧模式：34 款酒
--
-- 职责：
--   * 34 款酒的权威定义（id / 中文名 / 技能说明 / 酒杯配色 / ability 主动技能；
--     立绘 = assets/bar/cocktails/<id>.png）
--   * 「当前生效的酒」判定（state.bar.buffs[id] > 0 即生效）
--   * 醉酒倒计时：喝一口 → refreshBuff 刷回 5；每小局 tickDown 无条件递减一次
--   * 回填（迈泰 / 泛银河系漱口酒）：只在「栏内且未满」的杯子上进行，
--     绝不复活一杯已经喝空并被移除的酒
--
-- 依赖：只读 state.bar.{buffs, cups}，不持有 state
-- 调用方：src/game_state.lua（酒吧分支）、ui/ui.lua（调酒栏 / tooltip）
-- 禁区：不改基础/困难模式任何行为；不新增遗物；随机源只用 love.math.random
-- ============================================================

local Cocktails = {}

-- 喝一口 → 该酒被动持续 5 小局（同类不叠层，只刷新倒计时）
local BUFF_TURNS = 5
-- 1 杯 = 5 口；每次喝 1/5 杯 = 1 口
local POURS_PER_CUP = 5
-- 回填量 = 1 口（= 1/5 杯），与「喝一口」对称
local BACKFILL_POURS = 1

Cocktails.BUFF_TURNS     = BUFF_TURNS
Cocktails.POURS_PER_CUP  = POURS_PER_CUP
Cocktails.BACKFILL_POURS = BACKFILL_POURS

-- ============================================================
-- 34 款酒的权威定义（顺序即侧栏 / 图鉴顺序，不得重排）。
-- 后 22 款技能全部立即生效（pick = nil），方向：
--   A = 改变庄家明牌数量（1/2/3/4/7/19/20/22）、
--   B = 强制庄家抽牌（5/6/8/12/13/14/16/17）、
--   C = 改变牌库构成（9/10/11/15/18/21）。
-- ============================================================
Cocktails.LIBRARY = {
    {
        id = "mercury", name = "莫斯科骡子",
        color = { 0.86, 0.55, 0.24 },
        desc = "主动技「重洗」：弃掉你全部手牌，再抽等量张新牌",
        ability = { key = "reshuffle", name = "重洗", desc = "弃掉你全部手牌，再抽等量张新牌", pick = nil },
    },
    {
        id = "venus", name = "大都会",
        color = { 0.95, 0.36, 0.46 },
        desc = "主动技「换牌」：把你的一张手牌换成同种牌组的任意另一张",
        ability = { key = "swap", name = "换牌", desc = "把你的一张手牌换成同种牌组的任意另一张", pick = "two_step" },
    },
    {
        id = "earth", name = "古典鸡尾酒",
        color = { 0.80, 0.42, 0.16 },
        desc = "主动技「透牌」：查看牌堆顶 3 张，可把其中任意张沉到牌堆底",
        ability = { key = "peek3", name = "透牌", desc = "查看牌堆顶 3 张，可把其中任意张沉到牌堆底", pick = "list_toggle" },
    },
    {
        id = "mars", name = "血腥玛丽",
        color = { 0.90, 0.20, 0.15 },
        desc = "主动技「着火」：烧掉本局牌堆的一半，只留下随机一半",
        ability = { key = "burn", name = "着火", desc = "烧掉本局牌堆的一半，只留下随机一半", pick = nil },
    },
    {
        id = "jupiter", name = "迈泰",
        color = { 0.95, 0.62, 0.20 },
        desc = "主动技「双份」：复制你点数最低的一张手牌，多拿一张",
        ability = { key = "dup", name = "双份", desc = "复制你点数最低的一张手牌，多拿一张", pick = nil },
    },
    {
        id = "saturn", name = "新加坡司令",
        color = { 0.95, 0.42, 0.42 },
        desc = "主动技「封口」：酒保本局立即停牌，不再要牌",
        ability = { key = "seal", name = "封口", desc = "酒保本局立即停牌，不再要牌", pick = nil },
    },
    {
        id = "uranus", name = "蓝色泻湖",
        color = { 0.20, 0.62, 0.95 },
        desc = "主动技「加冰」：弃掉你点数最高的一张手牌",
        ability = { key = "chill", name = "加冰", desc = "弃掉你点数最高的一张手牌", pick = nil },
    },
    {
        id = "neptune", name = "尼格罗尼",
        color = { 0.72, 0.16, 0.22 },
        desc = "主动技「掉包」：用你的一张手牌换走酒保的一张明牌",
        ability = { key = "snatch", name = "掉包", desc = "用你的一张手牌换走酒保的一张明牌", pick = "two_step" },
    },
    {
        id = "pluto", name = "黑暗风暴",
        color = { 0.42, 0.22, 0.56 },
        desc = "主动技「弃牌」：随机弃掉你的一张手牌",
        ability = { key = "discard", name = "弃牌", desc = "随机弃掉你的一张手牌", pick = nil },
    },
    {
        id = "planetx", name = "泛银河系漱口酒",
        color = { 0.45, 0.76, 1.00 },
        desc = "主动技「错乱」：从冠军牌组里挑一张，直接打进你的手牌",
        ability = { key = "chaos", name = "错乱", desc = "从冠军牌组里挑一张，直接打进你的手牌", pick = "card_pick" },
    },
    {
        id = "ceres", name = "收获之月",
        color = { 0.86, 0.72, 0.32 },
        desc = "主动技「移花」：抽走酒保点数最大的一张明牌，沉到牌堆底",
        ability = { key = "take", name = "移花", desc = "抽走酒保点数最大的一张明牌，沉到牌堆底", pick = nil },
    },
    {
        id = "eris", name = "金色黎明",
        color = { 0.95, 0.82, 0.28 },
        desc = "主动技「弹走」：把你点数最小的一张手牌弹给酒保",
        ability = { key = "flick", name = "弹走", desc = "把你点数最小的一张手牌弹给酒保", pick = nil },
    },
    {
        id = "fool", name = "长岛冰茶",
        color = { 0.82, 0.74, 0.55 },
        desc = "主动技「胡闹」：把庄家最后一张明牌沉到牌堆底，并立即补发 1 张新明牌",
        ability = { key = "foolish", name = "胡闹", desc = "把庄家最后一张明牌沉到牌堆底，并立即补发 1 张新明牌", pick = nil },
    },
    {
        id = "magician", name = "马天尼",
        color = { 0.88, 0.80, 0.60 },
        desc = "主动技「戏法」：为庄家额外发 1 张明牌",
        ability = { key = "magic", name = "戏法", desc = "为庄家额外发 1 张明牌", pick = nil },
    },
    {
        id = "high_priestess", name = "白色佳人",
        color = { 0.45, 0.62, 0.88 },
        desc = "主动技「低语」：把庄家点数最小的一张明牌沉到牌堆底，并立即补发 1 张新明牌",
        ability = { key = "hush", name = "低语", desc = "把庄家点数最小的一张明牌沉到牌堆底，并立即补发 1 张新明牌", pick = nil },
    },
    {
        id = "empress", name = "贝里尼",
        color = { 0.93, 0.78, 0.35 },
        desc = "主动技「加冕」：若庄家明牌不足 2 张，补发到 2 张（只补不收）",
        ability = { key = "crown", name = "加冕", desc = "若庄家明牌不足 2 张，补发到 2 张（只补不收）", pick = nil },
    },
    {
        id = "emperor", name = "教父",
        color = { 0.72, 0.50, 0.30 },
        desc = "主动技「律令」：强制庄家立即抽 1 张明牌",
        ability = { key = "decree", name = "律令", desc = "强制庄家立即抽 1 张明牌", pick = nil },
    },
    {
        id = "hierophant", name = "曼哈顿",
        color = { 0.77, 0.56, 0.35 },
        desc = "主动技「布道」：强制庄家立即抽 2 张明牌",
        ability = { key = "sermon", name = "布道", desc = "强制庄家立即抽 2 张明牌", pick = nil },
    },
    {
        id = "lovers", name = "含羞草",
        color = { 0.94, 0.72, 0.66 },
        desc = "主动技「结对」：复制庄家的最后一张明牌，作为新的明牌（明牌 +1）",
        ability = { key = "pairing", name = "结对", desc = "复制庄家的最后一张明牌，作为新的明牌（明牌 +1）", pick = nil },
    },
    {
        id = "chariot", name = "边车",
        color = { 0.86, 0.28, 0.30 },
        desc = "主动技「冲锋」：强制庄家立即抽 2 张明牌，然后本局庄家停牌",
        ability = { key = "charge", name = "冲锋", desc = "强制庄家立即抽 2 张明牌，然后本局庄家停牌", pick = nil },
    },
    {
        id = "justice", name = "萨泽拉克",
        color = { 0.55, 0.66, 0.68 },
        desc = "主动技「清算」：把本局牌堆按点数从小到大排序",
        ability = { key = "reckon", name = "清算", desc = "把本局牌堆按点数从小到大排序", pick = nil },
    },
    {
        id = "hermit", name = "高球",
        color = { 0.36, 0.52, 0.38 },
        desc = "主动技「独酌」：把牌堆顶 5 张沉到牌堆底（不足 5 张就沉现有的全部）",
        ability = { key = "solitude", name = "独酌", desc = "把牌堆顶 5 张沉到牌堆底（不足 5 张就沉现有的全部）", pick = nil },
    },
    {
        id = "wheel", name = "玛格丽特",
        color = { 0.92, 0.58, 0.25 },
        desc = "主动技「轮转」：用模板重灌整副牌堆并重新洗牌",
        ability = { key = "revolve", name = "轮转", desc = "用模板重灌整副牌堆并重新洗牌", pick = nil },
    },
    {
        id = "strength", name = "白俄罗斯",
        color = { 0.80, 0.24, 0.26 },
        desc = "主动技「蛮力」：强制庄家抽 1 张明牌，同时从你手牌里随机抽 1 张塞给庄家当明牌",
        ability = { key = "brute", name = "蛮力", desc = "强制庄家抽 1 张明牌，同时从你手牌里随机抽 1 张塞给庄家当明牌", pick = nil },
    },
    {
        id = "hanged", name = "僵尸",
        color = { 0.33, 0.46, 0.35 },
        desc = "主动技「悬挂」：把庄家点数最小的一张明牌与牌堆顶那张交换，不补牌",
        ability = { key = "hang", name = "悬挂", desc = "把庄家点数最小的一张明牌与牌堆顶那张交换，不补牌", pick = nil },
    },
    {
        id = "death", name = "黑色俄罗斯",
        color = { 0.45, 0.14, 0.16 },
        desc = "主动技「终末」：强制庄家立即抽 3 张明牌",
        ability = { key = "doom", name = "终末", desc = "强制庄家立即抽 3 张明牌", pick = nil },
    },
    {
        id = "temperance", name = "龙舌兰日出",
        color = { 0.95, 0.52, 0.22 },
        desc = "主动技「调和」：从本局牌堆里随机删掉 10 张（不足则删到保底张数为止）",
        ability = { key = "temper", name = "调和", desc = "从本局牌堆里随机删掉 10 张（不足则删到保底张数为止）", pick = nil },
    },
    {
        id = "devil", name = "飓风",
        color = { 0.55, 0.17, 0.19 },
        desc = "主动技「诱引」：强制庄家抽 1 张明牌，且该张必为牌堆中点数最大的那张",
        ability = { key = "tempt", name = "诱引", desc = "强制庄家抽 1 张明牌，且该张必为牌堆中点数最大的那张", pick = nil },
    },
    {
        id = "tower", name = "巴黎之花",
        color = { 0.60, 0.50, 0.70 },
        desc = "主动技「崩塌」：强制庄家连续抽牌，直到其点数达到或超过 21（有张数上限防护）",
        ability = { key = "collapse", name = "崩塌", desc = "强制庄家连续抽牌，直到其点数达到或超过 21（有张数上限防护）", pick = nil },
    },
    {
        id = "star", name = "汤姆柯林斯",
        color = { 0.93, 0.76, 0.62 },
        desc = "主动技「祈愿」：往本局牌堆插入 5 张 10 点牌",
        ability = { key = "wish", name = "祈愿", desc = "往本局牌堆插入 5 张 10 点牌", pick = nil },
    },
    {
        id = "moon", name = "莫吉托",
        color = { 0.42, 0.58, 0.85 },
        desc = "主动技「潮汐」：为庄家补牌，直到明牌数与你的手牌数相同（只补不收）",
        ability = { key = "tide", name = "潮汐", desc = "为庄家补牌，直到明牌数与你的手牌数相同（只补不收）", pick = nil },
    },
    {
        id = "sun", name = "巴哈马妈妈",
        color = { 0.95, 0.82, 0.42 },
        desc = "主动技「炽热」：为庄家每一张明牌各补 1 张（明牌数翻倍）",
        ability = { key = "blaze", name = "炽热", desc = "为庄家每一张明牌各补 1 张（明牌数翻倍）", pick = nil },
    },
    {
        id = "judgement", name = "代基里",
        color = { 0.50, 0.63, 0.65 },
        desc = "主动技「末日」：把本局牌堆压缩为点数最大的一半",
        ability = { key = "verdict", name = "末日", desc = "把本局牌堆压缩为点数最大的一半", pick = nil },
    },
    {
        id = "world", name = "皮斯科酸",
        color = { 0.35, 0.68, 0.60 },
        desc = "主动技「环球」：若庄家明牌不足 3 张，补发到 3 张（只补不收）",
        ability = { key = "globe", name = "环球", desc = "若庄家明牌不足 3 张，补发到 3 张（只补不收）", pick = nil },
    },
}

Cocktails.COUNT = #Cocktails.LIBRARY

-- ============================================================
-- 查询
-- ============================================================
function Cocktails.getById(id)
    for _, def in ipairs(Cocktails.LIBRARY) do
        if def.id == id then return def end
    end
    return nil
end

function Cocktails.indexOf(id)
    for i, def in ipairs(Cocktails.LIBRARY) do
        if def.id == id then return i end
    end
    return nil
end

-- 该酒的主动技能当前是否可用（倒计时 > 0）
function Cocktails.isActive(state, id)
    local bar = state and state.bar
    if not bar or not bar.buffs then return false end
    return (bar.buffs[id] or 0) > 0
end

function Cocktails.turnsLeft(state, id)
    local bar = state and state.bar
    if not bar or not bar.buffs then return 0 end
    return bar.buffs[id] or 0
end

-- 按 LIBRARY 顺序返回当前生效的酒（侧栏倒计时区 / tooltip 用，顺序稳定）
function Cocktails.activeList(state)
    local out = {}
    for _, def in ipairs(Cocktails.LIBRARY) do
        local n = Cocktails.turnsLeft(state, def.id)
        if n > 0 then
            table.insert(out, { def = def, turns = n })
        end
    end
    return out
end

-- ============================================================
-- 醉酒倒计时
-- ============================================================
-- 喝一口：同 id 只刷新回 5，不加层；不同 id 各存一份（互不干扰）
function Cocktails.refreshBuff(state, id)
    if not (state and state.bar and state.bar.buffs) then return end
    state.bar.buffs[id] = BUFF_TURNS
end

-- 每小局无条件递减一次（旧版「金色黎明只在输局递减」的被动已随主动技能改版废除）。
-- 返回：本小局「刚刚到期」（递减到 0 被清除）的酒 id 列表，已按 Cocktails.indexOf 升序排序
--       （内部用 pairs 遍历 buffs，顺序不确定，不排序会让同种子下多杯同时到期的颜色漂移）。
-- 无 bar / 无 buffs 时一律返回空表 {}（调用方直接取 #expired，不得返回 nil）。
-- 递减不再看胜负、也不看 state.bar.lastResult（该字段保留仅为兼容，不再参与判定）。
function Cocktails.tickDown(state)
    local bar = state and state.bar
    if not (bar and bar.buffs) then return {} end

    local expired = {}
    for id, n in pairs(bar.buffs) do
        local left = (n or 0) - 1
        if left <= 0 then
            bar.buffs[id] = nil
            expired[#expired + 1] = id
        else
            bar.buffs[id] = left
        end
    end
    table.sort(expired, function(a, b)
        return (Cocktails.indexOf(a) or math.huge) < (Cocktails.indexOf(b) or math.huge)
    end)
    return expired
end

-- 混合若干款酒的颜色（算术平均），作为宿醉全屏滤镜色。
-- 返回 { r, g, b }；列表为空、或一款都查不到时返回 nil（调用方按「无颜色」处理）。
function Cocktails.blendColors(ids)
    if type(ids) ~= "table" then return nil end
    local r, g, b, n = 0, 0, 0, 0
    for _, id in ipairs(ids) do
        local def = Cocktails.getById(id)
        local col = def and def.color
        if col then
            r = r + (col[1] or 0)
            g = g + (col[2] or 0)
            b = b + (col[3] or 0)
            n = n + 1
        end
    end
    if n == 0 then return nil end
    return { r / n, g / n, b / n }
end

-- ============================================================
-- 回填（迈泰 / 泛银河系漱口酒）
-- ============================================================
-- 栏内随机一个「未满」的杯子下标；全部满杯（没被喝过）或栏为空时返回 nil
-- 口径：mouth = 已喝口数，mouth == 0 即满杯，回填无从可填
function Cocktails.randomUnfilledCup(state)
    local cups = state and state.bar and state.bar.cups
    if not cups then return nil end
    local pool = {}
    for i, cup in ipairs(cups) do
        local mouth = cup.mouth or 0
        if mouth > 0 and mouth < POURS_PER_CUP then table.insert(pool, i) end
    end
    if #pool == 0 then return nil end
    return pool[love.math.random(#pool)]
end

-- 回填指定口数（把喝掉的补回来）；返回被回填的杯 id（无可用杯时返回 nil）
function Cocktails.backfill(state, amount)
    amount = amount or BACKFILL_POURS
    local idx = Cocktails.randomUnfilledCup(state)
    if not idx then return nil end
    local cup = state.bar.cups[idx]
    local mouth = (cup.mouth or 0) - amount
    if mouth < 0 then mouth = 0 end
    cup.mouth = mouth
    cup.wobble = love.timer.getTime()   -- 视觉：回填时杯子晃一下
    return cup.id
end

-- 一杯还剩几口（0 = 空；杯内 1 杯 = POURS_PER_CUP 口）
function Cocktails.poursLeft(cup)
    if not cup then return 0 end
    local left = POURS_PER_CUP - (cup.mouth or 0)
    if left < 0 then left = 0 end
    return left
end

-- 调酒栏剩余总量（口）；EmptyBar = 0，只剩一口 = 1
function Cocktails.totalPours(state)
    local cups = state and state.bar and state.bar.cups
    if not cups then return 0 end
    local total = 0
    for _, cup in ipairs(cups) do total = total + Cocktails.poursLeft(cup) end
    return total
end

return Cocktails
