-- ============================================================
-- DeckTypes — 特殊牌组系统
--
-- 3 种牌组类型:
--   decimal  — 小数牌组（点数 X.5，更容易凑 21）
--   negative — 负整数牌组（负数点数，可以减小爆牌风险）
--   multiplier — 倍率牌组（正常点数 + 结算时附加倍率加成）
--
-- 3 种大小: small(6张), medium(12张), large(18张)
-- 价格: small=$900, medium=$1800, large=$3600  (原价格 x3)
--       阶段倍率 x stageMult (1.0 / 1.5 / 2.0)
-- ============================================================

local DeckTypes = {}

DeckTypes.SIZES = {
    small  = { count = 6,   label = "小", priceBase = 900,  removeDecks = 1 },
    medium = { count = 12,  label = "中", priceBase = 1800, removeDecks = 2 },
    large  = { count = 18,  label = "大", priceBase = 3600, removeDecks = 3 },
}

DeckTypes.TYPES = {
    decimal = {
        name  = "小数牌组",
        desc  = "带有 .5 的牌（如 2.5, 7.5）。更容易精确凑 21。",
        color = { 0.3, 0.8, 0.3 },   -- 绿色
    },
    negative = {
        name  = "负整数牌组",
        desc  = "带负号的牌（如 -2, -5）。可以减小你的点数避免爆牌。",
        color = { 0.9, 0.3, 0.3 },   -- 红色
    },
    multiplier = {
        name  = "倍率牌组",
        desc  = "正常点数，但每张结算时附加 +0.5 倍率。",
        color = { 0.9, 0.7, 0.2 },   -- 金色
    },
    s67 = {
        name  = "67 卡组",
        desc  = "一半是 6，一半是 7。\n同时持有 67 卡组的 6 和 7 → 填满到 12 张且不会爆。",
        color = { 0.6, 0.3, 0.9 },   -- 紫色
    },
    rps = {
        name  = "石头剪刀布牌组",
        desc  = "三等分石头/剪刀/布，默认点数都是 0。\n触发规则：玩家和庄家各有且仅有一张 RPS 牌 → 用石头剪刀布判定输赢，跳过 21 点规则。\n胜负：石头胜剪刀 / 剪刀胜布 / 布胜石头；平局算玩家赢。",
        color = { 0.25, 0.65, 0.9 }, -- 天蓝色
    },
    remove = {
        name  = "删除牌组",
        desc  = "从固有牌堆中删除若干套标准扑克牌（减少总牌数）。\n固有牌堆套数有限（新局通常 1 套起），删完即止。\n注意：不能删到 0 套，至少保留 1 套。",
        color = { 0.5, 0.5, 0.5 }, -- 灰色
        is_remove = true,
    },
    blackhole = {
        name  = "黑洞牌组",
        desc  = "点数与花色与扑克牌无异，整副都是黑洞牌（黑色边框）。\n黑洞牌：抽到后会吸收上一张手牌（使上一张消失，不计入点数），\n但继承其特性（倍率/RPS属性/67词条/牢笼等）。\n若被吸收的牌是 67 词条，吸收后黑洞牌会再包一层紫色边框。",
        color = { 0.0, 0.0, 0.0 }, -- 黑色边框
        rarity = "legendary",
    },
    cage = {
        name  = "牢笼牌组",
        desc  = "整副都是牢笼牌：点数与花色与扑克牌无异，牌面带铁色竖杠。\n牢笼：若牢笼牌位于该方「明牌最末尾」，该方不能继续要牌。\n（玩家与庄家同样生效；黑洞牌继承牢笼特性后自身也算牢笼牌）",
        color = { 0.45, 0.42, 0.40 }, -- 铁色
        rarity = "legendary",
    },
    chip = {
        name  = "筹码牌组",
        desc  = "整副都是筹码牌：点数与花色与扑克牌无异，牌面带红黑相间边框。\n筹码：结算时，手牌里每张筹码牌额外提供「点数 × 100」的筹码加成，\n并入下注筹码之后再乘倍率。",
        color = { 0.85, 0.18, 0.18 }, -- 红色系（牌面边框为红黑相间图形）
        rarity = "rare",
    },
    -- 骰子牌组（六面 / 二十面）：整副是完全相同的骰子牌，回合中不显示点数，
    -- 只在摊牌结算时每张各掷一次；基准价与尺寸无关（600 / 200），仍乘阶段倍率
    dice6 = {
        name  = "六面骰子牌组",
        desc  = "整副都是同一颗六面骰：回合中不显示点数，只在摊牌结算时各掷一次（1~6）。",
        color = { 0.95, 0.95, 0.92 }, -- 象牙白
        rarity = "rare",
        priceBase = 600,
    },
    dice20 = {
        name  = "二十面骰子牌组",
        desc  = "整副都是同一颗二十面骰：回合中不显示点数，只在摊牌结算时各掷一次（1~20）。",
        color = { 0.20, 0.75, 0.70 }, -- 青玉色
        rarity = "rare",
        priceBase = 200,
    },
    -- 冠军牌组：内容由玩家在「冠军牌组编辑」里自选（36 张），固定售价 21
    -- 只在「通关困难模式解锁 + 已凑满 36 张」时才进入商店池（见 generateShopOffer 第 3 参）
    champion = {
        name  = "冠军牌组",
        desc  = "你自己编辑的 36 张冠军牌组。\n通关困难模式后可在主界面「冠军牌组」里编辑，售价固定 $21。",
        color = { 1.0, 0.85, 0.2 }, -- 金色
        is_champion = true,
    },
}

local SUITS = { "\u{2660}", "\u{2665}", "\u{2666}", "\u{2663}" }

-- 生成一张骰子牌（六面 / 二十面完全相同）
-- 锁定项：未掷骰时 value 必须为 nil（不得给 0 或任何默认值），否则会被当成真实点数参与胜负。
-- rank/suit 用空串占位：骰子牌没有扑克花色，占位可保证任何 `rank .. suit` 拼接或按键查表都不拿到 nil。
-- 面数一律由 kind 推导（"dice6" -> 6，"dice20" -> 20），见 Blackjack.diceSides。
local function makeDiceCard(kind)
    return {
        suit       = "",
        rank       = "",
        faceUp     = false,
        value      = nil,          -- 未掷骰：不产生任何点数贡献
        kind       = kind,         -- "dice6" / "dice20"（面数的唯一依据）
        isSpecial  = true,
        dice_token = nil,          -- 本小局令牌：nil = 未掷；结算掷出时写入当前令牌
        mult_bonus = 0,
    }
end

-- 为指定牌组生成一张特殊牌
local function makeSpecialCard(suit, kind, value, displayRank, extra)
    return {
        suit         = suit,
        rank         = displayRank,    -- 显示用
        value        = value,          -- 算分用的真实数值
        faceUp       = false,
        kind         = kind,           -- "decimal" / "negative" / "multiplier" / "s67"
        isSpecial    = true,
        mult_bonus   = extra and extra.mult_bonus or 0,
        original_rank = displayRank,
        is_67        = (kind == "s67"), -- 67 卡组标识
        is_rps       = (kind == "rps"), -- 石头剪刀布标识
    }
end

-- 生成指定类型+大小的牌组
function DeckTypes.generate(typeKey, sizeKey)
    local tpl  = DeckTypes.TYPES[typeKey]
    local size = DeckTypes.SIZES[sizeKey]
    if not tpl or not size then return {} end

    local cards = {}
    local count = size.count

    for i = 1, count do
        local suit = SUITS[(i - 1) % 4 + 1]

        if typeKey == "dice6" or typeKey == "dice20" then
            -- 骰子牌组：整副完全相同；不消耗随机源（点数只在结算时掷出）
            table.insert(cards, makeDiceCard(typeKey))

        elseif typeKey == "decimal" then
            -- 小数牌: 从 0.5 到 10.5，步长 1.0（共 11 种）
            local decimals = { 0.5, 1.5, 2.5, 3.5, 4.5, 5.5, 6.5, 7.5, 8.5, 9.5, 10.5 }
            local value = decimals[love.math.random(#decimals)]
            local disp  = tostring(value)
            table.insert(cards, makeSpecialCard(suit, "decimal", value, disp))

        elseif typeKey == "negative" then
            -- 负数牌: -1 到 -10
            local negs = { -1, -2, -3, -4, -5, -6, -7, -8, -9, -10 }
            local value = negs[love.math.random(#negs)]
            local disp  = tostring(value)
            table.insert(cards, makeSpecialCard(suit, "negative", value, disp))

        elseif typeKey == "multiplier" then
            -- 倍率牌: 正常点数 + mult_bonus +0.5
            local normals = { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 }
            local value = normals[love.math.random(#normals)]
            local disp  = tostring(value)
            table.insert(cards, makeSpecialCard(suit, "multiplier", value, disp, { mult_bonus = 0.5 }))

        elseif typeKey == "s67" then
            -- 67 卡组: 一半全是 6，一半全是 7
            local value = (i % 2 == 1) and 6 or 7
            local disp  = tostring(value)
            table.insert(cards, makeSpecialCard(suit, "s67", value, disp))

        elseif typeKey == "rps" then
            -- 石头剪刀布牌组: 三等分石头/剪刀/布，默认点数 0
            local symbols = { "石", "剪", "布" }
            local disp = symbols[(i - 1) % 3 + 1]
            table.insert(cards, makeSpecialCard(suit, "rps", 0, disp))

        elseif typeKey == "remove" then
            -- 删除牌组: 不生成任何牌（靠 state 记录删除数量，rebuildDeck 时减 numDecks）
            return {}

        elseif typeKey == "blackhole" then
            -- 黑洞牌组：整副都是黑洞牌（点数与花色照常按扑克算，抽到吸收上一张）
            local ranks = { 'A', 2, 3, 4, 5, 6, 7, 8, 9, 10, 'J', 'Q', 'K' }
            local rank = ranks[love.math.random(#ranks)]
            local card = {
                suit = suit, rank = rank, faceUp = false,
                kind = "blackhole", isSpecial = true,
                is_blackhole = true,
                mult_bonus = 0,
            }
            table.insert(cards, card)

        elseif typeKey == "cage" then
            -- 牢笼牌组：整副都是牢笼牌（普通扑克点数/花色 + 牢笼 tag）
            local ranks = { 'A', 2, 3, 4, 5, 6, 7, 8, 9, 10, 'J', 'Q', 'K' }
            local rank = ranks[love.math.random(#ranks)]
            table.insert(cards, {
                suit = suit, rank = rank, faceUp = false,
                value = nil,                 -- nil = 照常算扑克点数
                kind = "cage", isSpecial = true,
                is_cage = true,              -- 牢笼 tag（判定「明牌最末尾是否牢笼」的唯一依据）
                mult_bonus = 0,
            })

        elseif typeKey == "chip" then
            -- 筹码牌组：整副都是筹码牌（普通扑克点数/花色 + 筹码 tag）
            local ranks = { 'A', 2, 3, 4, 5, 6, 7, 8, 9, 10, 'J', 'Q', 'K' }
            local rank = ranks[love.math.random(#ranks)]
            table.insert(cards, {
                suit = suit, rank = rank, faceUp = false,
                value = nil,                 -- nil = 照常算扑克点数（A 按 1 计）
                kind = "chip", isSpecial = true,
                is_chip = true,              -- 筹码 tag（结算「点数 × 100」的唯一依据）
                mult_bonus = 0,
            })
        end
    end

    return cards
end

-- 计算牌组价格（阶段缩放）
function DeckTypes.getPrice(typeKey, sizeKey, stage)
    -- 冠军牌组固定售价 21（不随阶段缩放，小/中/大三档同价）
    if typeKey == "champion" then return 21 end
    local size = DeckTypes.SIZES[sizeKey]
    if not size then return 0 end
    local tpl  = DeckTypes.TYPES[typeKey]
    -- 骰子牌组自带基准价（600 / 200），与尺寸无关；其余牌组沿用尺寸基准价（900 / 1800 / 3600）
    local base = (tpl and tpl.priceBase) or size.priceBase
    local stageMult = 1 + ((stage or 1) - 1) * 0.5   -- 1.0 / 1.5 / 2.0
    return math.floor(base * stageMult)
end

-- 商店里生成随机牌组 offer（遗物 4 + 牌组 1，牌组池包含 remove）
-- championAvailable: 冠军牌组是否已解锁且凑满 36 张（为真时才把它加进抽取池）
-- currentDecks: 固有牌堆当前剩余套数（可省略）；≤1 时把 remove 剔出商品池（不能再删）
function DeckTypes.generateShopOffer(count, stage, championAvailable, currentDecks)
    count = count or 2
    stage = stage or 1
    local offers = {}
    local types  = { "decimal", "negative", "multiplier", "s67", "rps", "remove", "blackhole", "cage", "chip", "dice6", "dice20" }
    if championAvailable then table.insert(types, "champion") end
    if currentDecks ~= nil and currentDecks <= 1 then
        local kept = {}
        for _, t in ipairs(types) do
            if t ~= "remove" then kept[#kept + 1] = t end
        end
        types = kept
    end
    local sizes  = { "small", "medium", "large" }

    for i = 1, count do
        local tKey = types[love.math.random(#types)]
        local sKey = sizes[love.math.random(#sizes)]
        local tpl  = DeckTypes.TYPES[tKey]
        local size = DeckTypes.SIZES[sKey]

        local label, desc
        if tKey == "remove" then
            label = size.label .. " " .. tpl.name
            desc  = tpl.desc .. "\n" .. "删除 " .. size.removeDecks .. " 套标准扑克"
        else
            label = size.label .. " " .. tpl.name
            desc  = tpl.desc .. "\n" .. "数量: " .. size.count .. " 张"
        end

        table.insert(offers, {
            typeKey = tKey,
            sizeKey = sKey,
            name    = label,
            desc    = desc,
            color   = tpl.color,
            price   = DeckTypes.getPrice(tKey, sKey, stage),
            count   = tKey == "remove" and 0 or size.count,
            removeDecks = size.removeDecks,  -- 给 remove 用
            isRemove = tpl.is_remove,
        })
    end

    return offers
end

return DeckTypes
