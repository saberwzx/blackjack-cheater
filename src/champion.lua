-- ============================================================
-- champion.lua — 冠军牌组数据模型 + 编辑器牌池
--
-- 职责:
--   1. 冠军牌组的容量规则（最多 36 张 / 必须满 36 张才算完成）
--   2. 牌面深拷贝（含黑洞 / RPS / 67 / 牢笼等词条判定值字段）
--   3. 编辑器的牌池枚举（按牌组种类折叠展示，自动包含 DeckTypes.TYPES 里的新牌组）
--   4. 注入牌堆时的尺寸展开（小 = 36，中 = 复制一遍 72，大 = 复制两遍 108）
--   5. 解锁判定（通关困难模式）与「可上架」判定（已解锁 + 已满 36 张）
--
-- 依赖: src/deck_types（TYPES 的 name/color 与牌面种类定义）
-- 调用方:
--   main.lua / ui/ui.lua —— 编辑器牌池与牌组栏展示
--   src/game_state.lua   —— 商店购买时展开成实际牌张（buildDeck）
--
-- 公共 API:
--   Champion.SIZE                容量上限 36
--   Champion.cloneCard(card)     深拷贝一张牌
--   Champion.count(cards)        当前张数
--   Champion.canAdd(cards)       还能不能加（上限拦截）
--   Champion.isComplete(cards)   是否已满 36（完成度拦截保存）
--   Champion.addCard(cards, c)   加入一张（会深拷贝；满则拒绝）
--   Champion.removeCard(cards,i) 移除第 i 张
--   Champion.isUnlocked(state)   是否已解锁（通关困难模式）
--   Champion.isAvailable(state)  是否可上架（已解锁 + 已满 36）
--   Champion.buildDeck(cards,k)  按尺寸展开成实际注入用的牌（已深拷贝）
--   Champion.buildPool()         编辑器牌池（按种类分组的模板，含副本）
--
-- 禁止事项:
--   - 绝不写入 DeckTypes.TYPES / 全局模板（所有返回值都是新表）
--   - 不写 emoji 或 U+1F000 以上字符（字体不支持，会乱码）
--
-- 已踩过的坑:
--   - 复制一张牌只拷 rank/suit 会让黑洞牌、RPS 牌、67 词条全部失效：
--     必须连判定值副本（rps_symbol / s67_rank）一起拷
--   - 冠军牌组里拷自「固有牌堆」的普牌是 isSpecial=false，Deck:reset() 重建牌堆时
--     只保留 isSpecial / is_67 / is_rps / is_blackhole 的牌，会把它们丢掉。
--     因此这里给这类牌统一打 isSpecial=true（它们本来就是「注入的特殊牌组」身份）
-- ============================================================

local DeckTypes = require("src.deck_types")

local Champion = {}

Champion.SIZE = 36

-- 尺寸 → 复制遍数（与 DeckTypes.SIZES 的小/中/大 对齐：36 / 72 / 108）
Champion.COPIES = { small = 1, medium = 2, large = 3 }

-- 深拷贝白名单：所有影响玩法判定的字段，少一个就会让对应词条失效
-- dice_token：骰子牌的本小局令牌（掷骰冻结依据），漏拷会让克隆后的骰子牌每小局被重复掷骰。
-- 骰子面数不另存字段，一律由 kind（"dice6" / "dice20"）推导，见 Blackjack.diceSides。
Champion.CARD_FIELDS = {
    "suit", "rank", "value", "kind", "mult_bonus", "original_rank",
    "isSpecial", "is_67", "is_rps", "is_blackhole", "is_cage", "is_chip", "is_champion",
    "rps_symbol", "s67_rank", "dice_token",
}

local SUITS = { "\u{2660}", "\u{2665}", "\u{2666}", "\u{2663}" }
local RANKS = { 'A', 2, 3, 4, 5, 6, 7, 8, 9, 10, 'J', 'Q', 'K' }

-- ============================================================
-- 深拷贝 / 容量
-- ============================================================
function Champion.cloneCard(card)
    local c = { faceUp = false }
    if type(card) ~= "table" then return c end
    for _, f in ipairs(Champion.CARD_FIELDS) do
        if card[f] ~= nil then c[f] = card[f] end
    end
    return c
end

function Champion.count(cards)
    if type(cards) ~= "table" then return 0 end
    return #cards
end

-- 上限拦截：已满 36 张时不允许再加
function Champion.canAdd(cards)
    return Champion.count(cards) < Champion.SIZE
end

-- 完成度拦截：只有满 36 张才允许保存 / 上架
function Champion.isComplete(cards)
    return Champion.count(cards) == Champion.SIZE
end

function Champion.addCard(cards, card)
    if type(cards) ~= "table" or type(card) ~= "table" then return false end
    if not Champion.canAdd(cards) then return false end
    table.insert(cards, Champion.cloneCard(card))
    return true
end

function Champion.removeCard(cards, index)
    if type(cards) ~= "table" or type(index) ~= "number" then return false end
    if index < 1 or index > #cards then return false end
    table.remove(cards, index)
    return true
end

-- ============================================================
-- 解锁 / 可上架
-- ============================================================
function Champion.isUnlocked(state)
    return type(state) == "table"
       and type(state.progress) == "table"
       and state.progress.hardCleared == true
end

function Champion.isAvailable(state)
    return Champion.isUnlocked(state)
       and Champion.isComplete(state.championCards)
end

-- ============================================================
-- 尺寸展开（注入牌堆用；返回的全是新表，不改冠军牌组本体）
-- ============================================================
function Champion.buildDeck(cards, sizeKey)
    local copies = Champion.COPIES[sizeKey] or 1
    local out = {}
    if type(cards) ~= "table" then return out end
    for _ = 1, copies do
        for _, c in ipairs(cards) do
            table.insert(out, Champion.cloneCard(c))
        end
    end
    return out
end

-- ============================================================
-- 编辑器牌池
-- ============================================================
-- 每种牌组的「牌面种类」定义。新增牌组时在 DeckTypes.TYPES 里加一条即可出现在牌池里，
-- 若这里没有对应 spec，则退化为 52 张标准扑克面（kind 记为该牌组 key）。
local FACE_SPEC = {
    normal     = { ranks = RANKS },
    decimal    = { values = { 0.5, 1.5, 2.5, 3.5, 4.5, 5.5, 6.5, 7.5, 8.5, 9.5, 10.5 } },
    negative   = { values = { -1, -2, -3, -4, -5, -6, -7, -8, -9, -10 } },
    multiplier = { values = { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 }, mult_bonus = 0.5 },
    s67        = { values = { 6, 7 } },
    rps        = { symbols = { "石", "剪", "布" }, noSuits = true },
    blackhole  = { ranks = RANKS },
    cage       = { ranks = RANKS },
    chip       = { ranks = RANKS },
    -- 骰子牌组：整副只有一个牌面（不是 52 个扑克面）；dice = 面数
    dice6      = { dice = 6 },
    dice20     = { dice = 20 },
}

-- 展示顺序（未列出的新牌组会按 DeckTypes.TYPES 的键名排序追加到末尾）
Champion.POOL_ORDER = {
    "normal", "decimal", "negative", "multiplier", "s67", "rps", "blackhole", "cage", "chip",
    "dice6", "dice20",
}

-- 造一张模板牌（与 DeckTypes.generate 的产物保持同样的词条语义）
local function makePoolCard(typeKey, spec, suit, face)
    if spec.dice then
        -- 骰子面：与 DeckTypes.generate 的骰子牌同规格（value = nil 未掷、rank/suit 空串占位）
        return {
            suit = "", rank = "", faceUp = false,
            value = nil, kind = typeKey, isSpecial = true,
            is_champion = true, dice_token = nil, mult_bonus = 0,
        }
    end
    if spec.ranks then
        -- 扑克面：固有 / 黑洞 / 牢笼
        local card = {
            suit = suit, rank = face, faceUp = false,
            value = nil, kind = typeKey, isSpecial = true,
            is_champion = true, mult_bonus = 0,
        }
        if typeKey == "blackhole" then card.is_blackhole = true end
        if typeKey == "cage" then card.is_cage = true end
        if typeKey == "chip" then card.is_chip = true end
        return card
    end
    if spec.symbols then
        -- RPS：3 张，点数 0
        return {
            suit = suit, rank = face, faceUp = false,
            value = 0, kind = typeKey, isSpecial = true,
            is_champion = true, is_rps = true, mult_bonus = 0,
        }
    end
    -- 数值面：小数 / 负数 / 倍率 / 67
    local disp = tostring(face)
    return {
        suit = suit, rank = disp, faceUp = false,
        value = face, kind = typeKey, isSpecial = true,
        is_champion = true, original_rank = disp,
        is_67 = (typeKey == "s67"), is_rps = false,
        mult_bonus = spec.mult_bonus or 0,
    }
end

-- 某一种牌组的全部牌面（返回模板列表，调用方拿到的总是新表）
function Champion.buildGroupCards(typeKey)
    local out = {}
    local spec = FACE_SPEC[typeKey]
    if typeKey == "remove" then return out end        -- 删除牌组不产牌
    if typeKey == "champion" then return out end      -- 冠军牌组自身不进牌池

    if not spec then
        -- 未来新增的牌组：退化为基础 52 个扑克面
        for _, suit in ipairs(SUITS) do
            for _, rank in ipairs(RANKS) do
                table.insert(out, makePoolCard(typeKey, {}, suit, rank))
            end
        end
        return out
    end

    if spec.noSuits then
        -- RPS 例外：不分花色，一共 3 张
        for i, sym in ipairs(spec.symbols) do
            table.insert(out, makePoolCard(typeKey, spec, SUITS[(i - 1) % 4 + 1], sym))
        end
        return out
    end

    if spec.dice then
        -- 骰子例外：不分花色，整副只有 1 个牌面（绝不是 52 张扑克面）
        table.insert(out, makePoolCard(typeKey, spec, "", ""))
        return out
    end

    local faces = spec.ranks or spec.values
    for _, suit in ipairs(SUITS) do
        for _, face in ipairs(faces) do
            table.insert(out, makePoolCard(typeKey, spec, suit, face))
        end
    end
    return out
end

-- 编辑器牌池：按牌组种类分组（供折叠展示 + 下拉菜单）
function Champion.buildPool()
    local order = {}
    for _, k in ipairs(Champion.POOL_ORDER) do table.insert(order, k) end
    -- 自动带上 DeckTypes.TYPES 里未在展示顺序中列出的新牌组
    local extra = {}
    for k in pairs(DeckTypes.TYPES) do
        local listed = false
        for _, k2 in ipairs(order) do if k2 == k then listed = true break end end
        if not listed then table.insert(extra, k) end
    end
    table.sort(extra)
    for _, k in ipairs(extra) do table.insert(order, k) end

    local groups = {}
    -- 「固有牌堆」不是 DeckTypes.TYPES 的成员，但必须作为第一组出现
    table.insert(groups, {
        key   = "normal",
        name  = "固有牌堆",
        desc  = "6 套标准扑克里的牌（52 种牌面）",
        color = { 0.85, 0.85, 0.85 },
        cards = Champion.buildGroupCards("normal"),
    })
    for _, k in ipairs(order) do
        if k ~= "normal" then
            local tpl = DeckTypes.TYPES[k]
            if tpl and not tpl.is_remove and not tpl.is_champion then
                table.insert(groups, {
                    key   = k,
                    name  = tpl.name or k,
                    desc  = tpl.desc or "",
                    color = tpl.color or { 1, 1, 1 },
                    cards = Champion.buildGroupCards(k),
                })
            end
        end
    end
    return groups
end

return Champion