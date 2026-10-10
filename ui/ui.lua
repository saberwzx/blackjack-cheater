-- ============================================================
-- ui/ui.lua — 全部画面渲染（表现层：只读 state + 写热区，不改游戏规则）
--
-- 与 game_state 的契约：绘制时把可点热区写入 UI._xxxBtns / UI._shopCards 等
-- 固定命名的表，main.lua 的点击分发读同一份数据 —— 绘制与点击永远同源。
--
-- 文件分区（自上而下）:
--   1.  布局与资源     refreshLayout / loadResources / 字体加载
--   2.  卡牌绘制原语   drawCard / 牢笼·筹码记号 / 黑洞边框 / 入场 tween
--   3.  drawAll        每帧总调度（按 state 分发到下面各 draw*）
--   4.  牌桌与作弊     drawGameTable / drawCheatTell / drawCheatFx
--   5.  遗物栏与标记   drawRelics / hitTestRelicBar / 特种标记区 / drawMarkFx
--   6.  酒吧模式 UI    drawBar*（brief / shelf / cup / gift / ending / 主动技能）
--   7.  手牌与庄家     drawHands / drawDealer / drawBarDealer
--   8.  下注与控制     drawBetSlider / drawControls
--   9.  商店与铸造     drawShop / drawForgeSelect / drawClassOffer
--   10. 结算与通关     drawResults / drawStageClear / drawVictory / Saber 斩击
--   11. 选单画面       drawTitleScreen / drawModeSelect / drawClassSelect / drawStarterSelect
--   12. 浮层弹窗       tooltip / settings / deckOverview / shoeInfo / stage2Brief / tutorial
--   13. 冠军牌组编辑   deckEditorLayout / drawDeckEditor
-- ============================================================

local Relics = require("src.relics")
local Blackjack = require("src.blackjack")
local GameState = require("src.game_state")
local Tween = require("src.tween")
local Champion = require("src.champion")
local Persist = require("src.persist")
local Cocktails = require("src.cocktails")
local ShoeInfo = require("src.shoe_info")

local UI = {}

UI.card = { width = 80, height = 120, spacing = 20 }

-- 分辨率预设（ESC 设置页用）
-- 包含 Love 默认窗口尺寸 800×600 + 3 个常用标准
UI.RESOLUTIONS = {
    { label = "800 x 600",   w = 800,  h = 600 },
    { label = "1280 x 720",  w = 1280, h = 720 },
    { label = "1600 x 900",  w = 1600, h = 900 },
    { label = "1920 x 1080", w = 1920, h = 1080 },
}

-- 统一刷新全局布局坐标（resize 回调 / setMode 后 / load 时都必须调这里）
-- 任何 UI 都不许直接改 window_width / window_height / sidebar_width / sidebar_x
function UI.refreshLayout()
    window_width  = love.graphics.getWidth()
    window_height = love.graphics.getHeight()
    sidebar_width = window_width * 0.12
    sidebar_x     = window_width - sidebar_width

    -- 下注滑条动态尺寸（按窗口比例）
    local padLeft = 80
    local padBottom = 70
    local sliderW = math.min(window_width - sidebar_width - padLeft - 180, 600)  -- 上限 600
    sliderW = math.max(sliderW, 280)  -- 最小 280
    UI.slider = {
        x = padLeft,
        y = window_height - padBottom,
        w = sliderW,
        h = 28,
        confirmBtn = { w = 120, h = 36 },
    }

    -- ========== 按钮热区（全部按窗口比例算，绘制和点击共用同一份数据）==========
    local desktopW = window_width - sidebar_width
    local H = window_height

    -- 玩家两行手牌的行高（和 UI.drawHands 的 HAND_SCALE / TINY_GAP 保持一致）
    local HAND_SCALE = 0.625
    local rowH = math.floor(UI.card.height * HAND_SCALE + 12)

    -- 下注快捷按钮：bet 状态下玩家手牌为空，放在点数区下方（空区域），绝不压住滑条
    local qbW = math.floor(desktopW * 0.15)
    local qbH = math.max(28, math.floor(H * 0.058))
    local qbGap = math.floor(qbW * 0.14)
    local qbY = math.floor(H * 0.5) + 72
    UI.buttons.bet = {
        { id = "bet50",  x = 30,                            y = qbY, w = qbW, h = qbH, label = "下注 $50" },
        { id = "bet100", x = 30 + (qbW + qbGap),            y = qbY, w = qbW, h = qbH, label = "下注 $100" },
        { id = "bet200", x = 30 + (qbW + qbGap) * 2,        y = qbY, w = qbW, h = qbH, label = "下注 $200" },
    }

    -- 要牌/结束/指认：锚定在玩家第二行手牌的下方，任何分辨率都不会压到手牌
    local btnW  = math.floor(desktopW * 0.142)
    local btnGap = math.floor(desktopW * 0.021)
    local accW  = math.floor(desktopW * 0.17)
    local accX  = desktopW - math.floor(desktopW * 0.023) - accW   -- 右对齐，留边距不进 sidebar
    local standX = accX - btnGap - btnW
    local hitX   = standX - btnGap - btnW
    local dblX   = hitX - btnGap - btnW
    local btnY   = math.floor(H * 0.5) + 32 + rowH * 2 + math.max(12, math.floor(H * 0.025))
    local btnH   = math.max(34, math.floor(H * 0.075))

    UI.buttons.game = {
        { id = "double", x = dblX,   y = btnY, w = btnW, h = btnH, label = "加倍(B)" },
        { id = "hit",    x = hitX,   y = btnY, w = btnW, h = btnH, label = "要牌(H)" },
        { id = "stand",  x = standX, y = btnY, w = btnW, h = btnH, label = "结束(S)" },
    }
    UI.buttons.accuse = { x = accX, y = btnY, w = accW, h = btnH }

    -- 投降按钮（遗物"后期投降"）：和要牌/结束同一行，靠最左放，宽度更窄，绝不影响其他按钮
    UI.buttons.surrender = {
        x = math.floor(desktopW * 0.02),
        y = btnY,
        w = math.floor(btnW * 0.8),
        h = btnH,
    }

    -- 调酒键（酒吧模式主动技能）：要牌键左侧同一行 —— 酒吧模式下「指认/投降」都不绘制，
    -- 左侧本来就是空的，绝不重叠。宽度取 btnW 的 1.1 倍，才放得下「调酒 N」。
    -- 热区单一数据源：绘制写这张表，main.lua 点击读同一张表。
    local alcW = math.floor(btnW * 1.1)
    UI._alcBtn = {
        x = hitX - btnGap - alcW,
        y = btnY,
        w = alcW,
        h = btnH,
        enabled = false,   -- 每帧由 UI.drawBarAlcButton 写入（无生效酒 / 全用过时灰显不可点）
    }
end

UI.splash = {
    text = "Press Any Key to Start",
    textYratio = 0.85, textColor = {1, 0.8, 0},
    blinkSpeed = 2.5, textAlpha = 1,
    titleFont = nil, titleFontSize = 38,
}

UI.dealer = {
    images = {},
    position = { x = 470, y = 30 },
    bounceVel = 260, gravity = 400, groundY = 30,
    currY = 30, damp = 0.82,
}

-- ============================================================
-- 酒吧模式（gameMode == "bar"）资源与主题配色
--   素材全部在 assets/bar/（不动 assets/art 的既有 dealer 四态）
--   UI.png 仅作配色/描边参考，不做图集切片
-- ============================================================
UI.bar = {
    bg         = nil,   -- assets/bar/bg.png（桌面背景，铺满窗口）
    ui         = nil,   -- assets/bar/UI.png（配色参考，不切片）
    drinks     = {},    -- [酒 id] = assets/bar/cocktails/<id>.png
    dealer     = {},    -- { normal=, focus=, lost=, win= }
}

-- 酒吧模式专用配色（深色木质侧栏 + 暖金描边）
UI.barTheme = {
    sidebarFill = { 0.13, 0.10, 0.08 },
    sidebarEdge = { 0.74, 0.56, 0.26 },
    panelFill   = { 0.12, 0.10, 0.09 },
    panelEdge   = { 0.80, 0.64, 0.30 },
    headerFill  = { 0.24, 0.17, 0.09 },
    accent      = { 0.92, 0.74, 0.32 },
    text        = { 0.95, 0.91, 0.81 },
    textDim     = { 0.70, 0.64, 0.52 },
    glassFill   = { 0.18, 0.15, 0.12 },
    probFill    = { 0.86, 0.56, 0.20 },
    cupEmpty    = { 0.30, 0.24, 0.18 },
    btnFill     = { 0.34, 0.26, 0.13 },
    btnHover    = { 0.52, 0.40, 0.19 },
}

-- 按钮热区（坐标全部由 UI.refreshLayout 按窗口比例写入，绘制与点击共用同一份数据）
UI.buttons = {
    bet = {},        -- 下注快捷按钮（bet 状态）
    game = {},       -- 要牌 / 结束（player 状态）
    accuse = nil,    -- 指认出千（player 状态）
    surrender = nil, -- 后期投降（player 状态，小于 18 点且有已激活的 late_surrender 时出现）
}

-- 滑条区域（动态尺寸，由 refreshLayout 计算）
UI.slider = { x = 80, y = 510, w = 550, h = 28, confirmBtn = { w = 120, h = 36 } }

-- ============================================================
-- 资源加载
-- ============================================================
function UI.loadResources()
    local cjkPath = "fonts/SourceHanSansHC-Bold.otf"
    local cjkPathFallback = "资源/SourceHanSansHC/OTF/TraditionalChineseHK/SourceHanSansHC-Bold.otf"

    -- 加载 CJK 字体（中文必需）
    local function loadCJK(size)
        local ok, f = pcall(love.graphics.newFont, cjkPath, size)
        if ok then return f end
        local ok2, f2 = pcall(love.graphics.newFont, cjkPathFallback, size)
        if ok2 then return f2 end
        return love.graphics.newFont(size)  -- 最后兜底（中文会变豆腐块，但不崩溃）
    end

    -- 预加载所有 UI 需要的尺寸（避免 draw 时反复 newFont）
    UI.cjkFontSmall = loadCJK(14)
    UI.cjkFont      = loadCJK(18)
    UI.cjkFontMid   = loadCJK(24)
    UI.cjkFontLarge = loadCJK(32)
    UI.cjkFontXL    = loadCJK(48)
    UI.cjkFontTitle = loadCJK(80)

    -- 英文装饰字体（Blackjack.otf）
    local okEn, enFont = pcall(love.graphics.newFont, "fonts/Blackjack.otf", 24)
    UI.font = okEn and enFont or UI.cjkFont

    local okTitle, titleFont = pcall(love.graphics.newFont, "fonts/Blackjack.otf", UI.splash.titleFontSize)
    UI.splash.titleFont = okTitle and titleFont or UI.cjkFontMid

    local names = {"dealer_normal", "dealer_focus", "dealer_lost", "dealer_win"}
    for _, n in ipairs(names) do
        local ok7, di = pcall(love.graphics.newImage, "assets/art/" .. n .. ".png")
        if ok7 then UI.dealer.images[n:gsub("dealer_", "")] = di end
    end
    UI.dealer.currentImage = UI.dealer.images.focus or UI.dealer.images.normal

    -- ===== 酒吧模式素材（assets/bar/，不改动上面既有的 assets/art dealer 四态）=====
    UI.bar = UI.bar or {}
    UI.bar.dealer = UI.bar.dealer or {}
    UI.bar.drinks = {}

    local okBg, barBg = pcall(love.graphics.newImage, "assets/bar/bg.png")
    if okBg then UI.bar.bg = barBg end
    local okBarUi, barUi = pcall(love.graphics.newImage, "assets/bar/UI.png")
    if okBarUi then UI.bar.ui = barUi end

    -- 每款酒一张立绘（assets/bar/cocktails/<id>.png）；缺图的酒由绘制函数退回色块占位
    for _, def in ipairs(Cocktails.LIBRARY) do
        local okImg, img = pcall(love.graphics.newImage, "assets/bar/cocktails/" .. def.id .. ".png")
        if okImg then UI.bar.drinks[def.id] = img end
    end

    for _, n in ipairs({"normal", "focus", "lost", "win"}) do
        local okD, di = pcall(love.graphics.newImage, "assets/bar/dealer_" .. n .. ".png")
        if okD then UI.bar.dealer[n] = di end
    end

    -- 每件遗物一张图标（assets/relics/<id>.png）；缺图的遗物由绘制函数退回色块占位
    UI.relicIcons = {}
    for _, def in ipairs(Relics.LIBRARY) do
        local okIcon, rimg = pcall(love.graphics.newImage, "assets/relics/" .. def.id .. ".png")
        if okIcon then UI.relicIcons[def.id] = rimg end
    end
end

-- ============================================================
-- 遗物图标（assets/relics/<id>.png 原创图标或纯色方块兜底）
-- ============================================================
function UI.drawRelicIcon(relic, x, y, w, h, greyTint)
    w = w or 70; h = h or 95
    -- 特殊标记遗物：白底 + 纯色小点（颜色 = 标记类型）
    if relic.markDot then
        love.graphics.setColor(0.96, 0.96, 0.94, 0.98)
        love.graphics.rectangle("fill", x, y, w, h, 6)
        local dr, dg, db = relic.markDot[1], relic.markDot[2], relic.markDot[3]
        if greyTint then dr, dg, db = 0.45, 0.45, 0.45 end
        love.graphics.setColor(dr, dg, db, 1)
        love.graphics.circle("fill", x + w / 2, y + h / 2, math.min(w, h) * 0.22)
        love.graphics.setColor(0.78, 0.78, 0.75, 1)
        love.graphics.rectangle("line", x, y, w, h, 6)
        return
    end
    local r, g, b = unpack(Relics.getRarityColor(relic.rarity))

    if greyTint then
        -- 灰度模式: 边框和背景用灰色
        local gr = 0.32; local gg = 0.32; local gb = 0.32
        love.graphics.setColor(0.18, 0.18, 0.18, 0.95)
        love.graphics.rectangle("fill", x, y, w, h, 6)
        love.graphics.setColor(gr, gg, gb)
        love.graphics.rectangle("line", x, y, w, h, 6)
    else
        love.graphics.setColor(r * 0.3, g * 0.3, b * 0.3, 0.95)
        love.graphics.rectangle("fill", x, y, w, h, 6)
        love.graphics.setColor(r, g, b)
        love.graphics.rectangle("line", x, y, w, h, 6)
    end

    local iconImg = UI.relicIcons and UI.relicIcons[relic.id]
    if iconImg then
        local sx = w / iconImg:getWidth(); local sy = h / iconImg:getHeight()
        love.graphics.setColor(1, 1, 1)
        love.graphics.draw(iconImg, x, y, 0, sx, sy)
        if greyTint then
            -- 灰度（未解锁/锁定态）: 半透明黑罩压暗图标
            love.graphics.setColor(0.6, 0.6, 0.6, 0.65)
            love.graphics.rectangle("fill", x, y, w, h, 6)
        end
    else
        if greyTint then
            love.graphics.setColor(0.55, 0.55, 0.55)
        else
            love.graphics.setColor(r, g, b)
        end
        love.graphics.setFont(UI.cjkFont)
        -- 无图标遗物的兜底：名字首字符（UTF-8 安全，中文取整个字而不是半个字节）
        local nm = relic.name or "?"
        local b = nm:byte(1)
        local len = 1
        if b and b >= 0xF0 then len = 4 elseif b and b >= 0xE0 then len = 3 elseif b and b >= 0xC0 then len = 2 end
        love.graphics.printf(nm:sub(1, len), x, y + h / 2 - 10, w, "center")
    end
end

-- ============================================================
-- drawCard — 支持 tween 动画的卡牌绘制
-- card.visual.x / card.visual.y 控制位置，支持翻牌 scaleX
-- ============================================================
function UI.drawCard(card, logicalX, logicalY, faceUp, targetScale)
    -- 初始化 visual（如果没有）
    if not card.visual then
        card.visual = { x = logicalX, y = logicalY, scaleX = 1, scaleY = 1, flipInProgress = false }
    end

    local cx = card.visual.x or logicalX
    local cy = card.visual.y or logicalY
    local vScaleX = card.visual.scaleX or 1
    local vScaleY = card.visual.scaleY or 1

    -- 独立目标缩放（手牌区专用，不影响总览）
    local s = targetScale or 1
    local scaleX = vScaleX * s
    local scaleY = vScaleY * s

    -- 如果是第一次从 deck 飞来：开始一个 tween
    if card._needTweenTo and card.visual.x == nil then
        -- 已有逻辑
    end

    -- 翻牌动画中：scaleX 会从 1 → 0 → 1，中间时切换 faceUp
    local effectiveFace = faceUp
    if card.visual.flipInProgress and scaleX < 0.1 then
        -- 中点切换
        effectiveFace = not faceUp
        card._faceUpFlipHold = not effectiveFace
    end

    local w = UI.card.width; local h = UI.card.height

    love.graphics.push()
    love.graphics.translate(cx + w/2, cy + h/2)
    love.graphics.scale(scaleX, scaleY)
    love.graphics.translate(-w/2, -h/2)

    love.graphics.setColor(1, 1, 1)
    love.graphics.rectangle("fill", 0, 0, w, h, 5)

    local show = effectiveFace
    if show == nil then show = faceUp end

    if show and Blackjack.diceSides(card) then
        -- ===== 骰子牌（六面 / 二十面）：牌面绝不拼接 `rank .. suit` =====
        -- 未掷骰 -> 持续旋转的骰子（旋转角由 love.timer.getTime() 驱动，不显示任何点数）
        -- 已掷骰 -> 静止显示本小局冻结的结果数字（1~6 / 1~20）
        -- 绘制细节：圆角方形骰身 + 点阵，颜色沿用 TYPES 里的识别色；全部按牌身比例算，无硬编码像素。
        local isTwenty = (card.kind == "dice20")
        local bodyCol  = isTwenty and { 0.20, 0.75, 0.70 } or { 0.95, 0.95, 0.92 }
        local pipCol   = isTwenty and { 0.04, 0.22, 0.20 } or { 0.16, 0.16, 0.16 }
        local numCol   = isTwenty and { 0.10, 0.45, 0.42 } or { 0.20, 0.20, 0.22 }

        if card.value ~= nil then
            -- 已掷骰：静止的结果数字（居中，不与牌面其它元素重叠）
            love.graphics.setColor(unpack(numCol))
            love.graphics.setFont(UI.font)
            love.graphics.printf(tostring(card.value), 0,
                h * 0.5 - UI.font:getHeight() * 0.5, w, "center")
        else
            -- 未掷骰：旋转的骰子
            local ds  = math.min(w, h) * 0.54
            local r   = ds * 0.16
            local ang = love.timer.getTime() * 1.6
            love.graphics.push()
            love.graphics.translate(w * 0.5, h * 0.5)
            love.graphics.rotate(ang)
            love.graphics.translate(-ds * 0.5, -ds * 0.5)
            love.graphics.setColor(unpack(bodyCol))
            love.graphics.rectangle("fill", 0, 0, ds, ds, r)
            love.graphics.setColor(unpack(pipCol))
            love.graphics.setLineWidth(2)
            love.graphics.rectangle("line", 1, 1, ds - 2, ds - 2, r)
            -- 点阵（四角 + 中心，一眼可辨认为骰子；不用任何 emoji / 图片素材）
            local pip = math.max(2, ds * 0.11)
            local off = ds * 0.26
            for _, p in ipairs({ { off, off }, { ds - off, off },
                                 { off, ds - off }, { ds - off, ds - off },
                                 { ds * 0.5, ds * 0.5 } }) do
                love.graphics.circle("fill", p[1] - pip * 0.5, p[2] - pip * 0.5, pip * 0.5)
            end
            love.graphics.setLineWidth(1)
            love.graphics.pop()
        end

        -- 骰子面数标注（底部小字，说明这是几面骰；不是点数）
        love.graphics.setColor(unpack(numCol))
        love.graphics.setFont(UI.cjkFontSmall)
        love.graphics.printf(isTwenty and "二十面骰" or "六面骰", 0, h - 18, w, "center")
    elseif show then
        local displayText = card.rank .. card.suit
        -- 特殊牌颜色区分
        if card.kind == "negative" then
            love.graphics.setColor(0.85, 0.15, 0.15)  -- 负数牌：血红
        elseif card.kind == "decimal" then
            love.graphics.setColor(0.15, 0.75, 0.2)   -- 小数牌：翠绿
        elseif card.kind == "multiplier" then
            love.graphics.setColor(0.9, 0.65, 0.1)    -- 倍率牌：金黄
        elseif card.kind == "s67" then
            love.graphics.setColor(0.6, 0.3, 0.9)     -- 67 卡组：紫色
        elseif card.suit == "\u{2665}" or card.suit == "\u{2666}" then
            love.graphics.setColor(0.8, 0, 0)          -- 红心方块红
        else
            love.graphics.setColor(0, 0, 0)            -- 正常黑色
        end
        love.graphics.setFont(UI.font)
        love.graphics.print(displayText, 10, 10)

        -- 倍率牌加小星星标记（右下角）
        if card.kind == "multiplier" and card.mult_bonus > 0 then
            love.graphics.setColor(0.9, 0.65, 0.1)
            love.graphics.setFont(UI.cjkFontSmall)
            love.graphics.printf("+" .. card.mult_bonus .. "x", 0, h - 16, w - 6, "right")
        end
    else
        love.graphics.setColor(0.3, 0.3, 0.8)
        for i = 0, h, 8 do love.graphics.line(0, i, w, i) end
    end
    love.graphics.pop()
end

-- 牢笼牌标识：铁色边框 + 牌面铁色竖杠（象征铁栅栏，无 emoji）
-- 约定：首参 (x, y) 是「卡身左上角」，调用方不得传卡中心坐标（传中心会整体偏半张卡身）。
function UI.drawCageMarks(x, y, w, h)
    love.graphics.setColor(0.45, 0.42, 0.40)
    love.graphics.setLineWidth(3)
    love.graphics.rectangle("line", x - 4, y - 4, w + 8, h + 8, 4)
    love.graphics.setColor(0.36, 0.34, 0.32)
    love.graphics.setLineWidth(2)
    for i = 1, 3 do
        local bx = x + w * i / 4
        love.graphics.line(bx, y + 2, bx, y + h - 2)
    end
    love.graphics.setLineWidth(1)
    love.graphics.setColor(1, 1, 1, 1)
end

-- 筹码牌：红黑相间边框（四条边各切 6 段，红/黑交替）
-- 约定：首参 (x, y) 是「卡身左上角」，调用方不得传卡中心坐标（传中心会整体偏半张卡身）。
function UI.drawChipMarks(x, y, w, h, inset)
    local pad = inset or 4
    local lx, ly = x - pad, y - pad
    local lw, lh = w + pad * 2, h + pad * 2
    local RED   = { 0.85, 0.15, 0.15 }
    local BLACK = { 0.05, 0.05, 0.05 }
    love.graphics.setLineWidth(3)
    local segs = 6
    local function edge(x1, y1, x2, y2)
        for i = 1, segs do
            local t1 = (i - 1) / segs
            local t2 = i / segs
            love.graphics.setColor(i % 2 == 1 and RED or BLACK)
            love.graphics.line(x1 + (x2 - x1) * t1, y1 + (y2 - y1) * t1,
                               x1 + (x2 - x1) * t2, y1 + (y2 - y1) * t2)
        end
    end
    edge(lx, ly, lx + lw, ly)
    edge(lx + lw, ly, lx + lw, ly + lh)
    edge(lx + lw, ly + lh, lx, ly + lh)
    edge(lx, ly + lh, lx, ly)
    love.graphics.setLineWidth(1)
    love.graphics.setColor(1, 1, 1, 1)
end

-- 覆盖层基准矩形：算出「卡身实际渲染出来的左上角」，供所有贴在卡上的边框 / 光晕 / 遮罩共用。
-- 为什么不能直接用 card.visual.x/y：UI.drawCard 是以「卡中心为原点」变换的
-- （translate(cx + w/2, cy + h/2) → scale(scaleX, scaleY) → translate(-w/2, -h/2)），
-- 缩放不移动中心，所以渲染左上角 = (cx + w/2 - w*scaleX/2, cy + h/2 - h*scaleY/2)，
-- 其中 scaleX = card.visual.scaleX * handScale；把 visual.x/y 当左上角会整体偏 (15, 22.5)。
-- 返回 { x, y, w, h }；w/h 与旧写法 TINY_W * scaleX 等价（本次只修位置、不修尺寸）。
-- 禁区：只做坐标换算，不得改写 card.visual、不得启动 tween、不得登记热区。
function UI.cardOverlayRect(card, lx, ly, handScale)
    local s  = handScale or 1
    local v  = card and card.visual
    local vx = (v and v.scaleX) or 1
    local vy = (v and v.scaleY) or 1
    local x0 = (v and v.x) or lx or 0
    local y0 = (v and v.y) or ly or 0
    local ow = UI.card.width  * s * vx
    local oh = UI.card.height * s * vy
    local ox = x0 + UI.card.width  / 2 - ow / 2
    local oy = y0 + UI.card.height / 2 - oh / 2
    return { x = ox, y = oy, w = ow, h = oh }
end

-- 宿醉兜底（canvas 不可用时）：用手牌底色把 rank + suit 压到不可辨认，再叠 3 条浅灰横纹模拟失焦拉丝。
-- 只画遮罩本身，边框由调用方在这层之上继续画，保证轮廓仍可辨。
local function drawFaceMaskRect(r)
    love.graphics.setColor(0.92, 0.92, 0.92, 0.86)
    love.graphics.rectangle("fill", r.x, r.y, r.w, r.h, 5)
    love.graphics.setColor(0.78, 0.78, 0.78, 0.45)
    local n = 3
    for i = 1, n do
        local y = r.y + r.h * i / (n + 1)
        love.graphics.rectangle("fill", r.x, y, r.w, math.max(1, r.h * 0.02))
    end
    love.graphics.setColor(1, 1, 1, 1)
end

-- 启动一张卡的入场 tween（从 deck 位置 → hand 位置）
function UI.tweenCardIn(card, logicalX, logicalY, deckX, deckY, delay)
    if not card.visual then card.visual = {} end
    card.visual.x = deckX or 20; card.visual.y = deckY or 10
    card.visual.scaleX = 0.1; card.visual.scaleY = 0.1
    Tween.new(card.visual, { x = logicalX, y = logicalY, scaleX = 1, scaleY = 1 }, 0.35 + (delay or 0), "outBack")
end

-- ============================================================
-- drawAll — 主绘制
-- ============================================================
function UI.drawAll(state)
    UI.beginHoverTargets()

    -- 酒吧模式：模态弹窗打开时清掉残留浮层（独占输入，不许点穿到设置页/牌堆总览）
    if state._barBriefOpen or state._barGiftOpen or state._barDrinkOpen
       or state.state == "bar_ending" or state.state == "bar_alcpick" then
        state.settingsOpen = false
        state.deckOverviewOpen = false
        state._shoeInfoOpen = false
    end

    -- 主菜单
    if state.state == "title" then
        UI.drawTitleScreen(state)
        UI.drawFlashMessage(state)   -- 未解锁时点击冠军牌组按钮的提示要能在主界面看到
        return
    end

    -- 冠军牌组编辑界面（全屏模态）
    if state.state == "deckEditor" then
        UI.drawDeckEditor(state)
        UI.drawFlashMessage(state)
        return
    end

    if state.state == "relic_select" and state.pendingRelics then
        UI.drawStarterSelect(state)
        -- 入口按钮在选遗物界面同样可点 → 浮层必须画出来，否则不可见却独占吃点击
        UI.drawDeckOverviewOverlay(state)
        UI.drawShoeInfoOverlay(state)
        UI.drawSettingsOverlay(state)
        -- 教程阶段 9「选一个遗物」落在本状态：不画教程卡，教学指引就整个消失
        UI.drawTutorialOverlay(state)
        UI.drawTooltip(state); return
    end

    UI.drawGameTable(state)
    UI.drawRelics(state)

    if state.state == "shop" then
        UI.drawHands(state)
        UI.drawControls(state)
        UI.drawShop(state)
        -- 牌堆总览 / 牌靴情报 / 设置页：入口按钮在商店内同样可点 → 必须画在商店之上，
        -- 否则点开后不可见却独占吃点击（玩家会以为游戏卡死）
        UI.drawDeckOverviewOverlay(state)
        UI.drawShoeInfoOverlay(state)
        UI.drawSettingsOverlay(state)
        UI.drawTooltip(state)
        UI.drawFlashMessage(state)   -- 商店内的临时提示（铸造/买牌组等），此前商店分支不渲染
        UI.drawTutorialOverlay(state)  -- 教程叠加层
        UI.drawStage2Brief(state)      -- 阶段 2 说明弹窗（模态）
        return
    end

    UI.drawHands(state)
    -- Saber 斩击动画（覆盖在牌上面）
    if state._saberAnim then UI.drawSaberSlash(state) end
    -- 出千华丽演出（彩晕+扩散环+字形，真/假 Tell 都触发，防凭演出反推）
    UI.drawCheatFx(state)
    -- 特殊标记效果动画（消失/虚空/爆炸/火焰）
    UI.drawMarkFx(state)
    -- UI.drawPeekPreview(state) — 已废弃：peek 效果内嵌到 drawHands 里（手牌[1] 半透明预览态）
    UI.drawDealer(state)         -- 庄家 + 困难模式职阶 icon
    UI.drawBarDealerStatBox(state)   -- 酒吧模式：悬停荷官立绘的统计框（必须在立绘之后、模态之前）
    UI.drawControls(state)
    UI.drawHangoverFilter(state)   -- 宿醉全屏滤镜：在按钮之上、结算面板之下
    UI.drawResults(state)
    UI.drawStageClear(state)
    UI.drawModeSelect(state)
    UI.drawClassSelect(state)
    UI.drawVictory(state)
    UI.drawClassOffer(state)      -- Caster 遗物替换面板（模态，盖在牌桌之上）
    UI.drawClassIcon(state)       -- 右上角职阶 icon（hover 显示详情）
    -- 出千痕迹已内嵌到 drawHands 的庄家手牌循环里（逐张牌调用 UI.drawCheatTell）
    UI.drawTooltip(state)
    UI.drawFlashMessage(state)    -- 临时提示（"手牌已满"等）

    -- 牌堆总览弹窗（随时可开）
    UI.drawDeckOverviewOverlay(state)

    -- 牌靴情报面板（随时可开，与总览同级互斥）
    UI.drawShoeInfoOverlay(state)

    -- 设置页（topmost）
    UI.drawSettingsOverlay(state)

    -- 教程叠加层
    UI.drawTutorialOverlay(state)

    -- 阶段 2 说明弹窗（模态，topmost）
    UI.drawStage2Brief(state)

    -- ===== 酒吧模式弹窗（模态，topmost）=====
    UI.drawBarBrief(state)    -- 开局说明
    UI.drawBarGift(state)     -- 赠酒三选一
    UI.drawBarDrink(state)    -- 喝酒选择
    UI.drawBarAlcPick(state)  -- 主动技能选牌模态
    UI.drawBarEnding(state)   -- 结局画面
end

-- ============================================================
-- 桌面
-- ============================================================
function UI.drawGameTable(state)
    -- ===== 酒吧模式：assets/bar/bg.png 铺满 + 深色木质侧栏（暖金描边）=====
    if state and state.gameMode == "bar" then
        local th = UI.barTheme
        if UI.bar and UI.bar.bg then
            local bw, bh = UI.bar.bg:getDimensions()
            love.graphics.setColor(1, 1, 1)
            love.graphics.draw(UI.bar.bg, 0, 0, 0, window_width / bw, window_height / bh)
        else
            love.graphics.setColor(th.panelFill)
            love.graphics.rectangle("fill", 0, 0, window_width, window_height)
        end
        -- 侧栏（深色木质 + 暖金描边）
        love.graphics.setColor(th.sidebarFill[1], th.sidebarFill[2], th.sidebarFill[3], 0.94)
        love.graphics.rectangle("fill", sidebar_x, 0, sidebar_width, window_height)
        love.graphics.setColor(th.sidebarEdge)
        love.graphics.rectangle("fill", sidebar_x - 3, 0, 3, window_height)
        love.graphics.setColor(1, 1, 1)
        return
    end

    love.graphics.setColor(0.1, 0.5, 0.2)
    love.graphics.rectangle("fill", 0, 0, window_width, window_height)
    love.graphics.setColor(1, 1, 1)
    love.graphics.rectangle("line", 5, 5, window_width - sidebar_width - 10, window_height - 10)

    love.graphics.setColor(0.3, 0.2, 0.1)
    love.graphics.rectangle("fill", sidebar_x, 0, sidebar_width, window_height)
    love.graphics.setColor(0.6, 0.5, 0.4)
    love.graphics.rectangle("fill", sidebar_x - 3, 0, 3, window_height)
end

-- ============================================================
-- 出千痕迹渲染（与招式一一对应；干扰项复用同色但「缺一环」，细节上可区分）
--   "A"  : 暗牌位（位置 1）白描边 + 循环抖动        ← 招式 A 的记号
--   "B"  : 新抽到的那张牌 金色【双线】描边 + 单次脉冲 ← 招式 B 的记号
--   "C"  : 被换掉的牌     青绿【双线】描边 + 旧牌残影 ← 招式 C 的记号
--   "dA" : 明牌位（位置 2）白描边但【不抖动】        ← 位置错
--   "dB" : 金色【单线】常亮（没有脉冲峰值）          ← 形态错
--   "dC" : 青绿【单线】且【无残影】                  ← 形态错
-- 由 drawHands 的庄家手牌循环逐张调用，坐标与该牌实际渲染坐标同源
-- 不复用 scorePopups / screenShake（那两个通道属于结算与爆牌反馈）
-- ============================================================
function UI.drawCheatTell(card, x, y, w, h)
    local kind = card and card._tell
    if not kind then return end

    local t   = love.timer.getTime()
    local age = t - (card._tellT or t)

    if kind == "A" then
        -- 真 A：描边 + 抖动（抖动让它与干扰项「静止的白框」永远可区分）
        local jx = math.sin(t * 14) * 2
        love.graphics.setColor(1, 1, 1, 0.55 + 0.25 * math.sin(t * 5))
        love.graphics.setLineWidth(2)
        love.graphics.rectangle("line", x - 6 + jx, y - 6, w + 12, h + 12, 4)
    elseif kind == "dA" then
        -- 干扰项：同样的白描边，但在明牌位且不抖动
        love.graphics.setColor(1, 1, 1, 0.55)
        love.graphics.setLineWidth(2)
        love.graphics.rectangle("line", x - 6, y - 6, w + 12, h + 12, 4)
    elseif kind == "B" then
        -- 真 B：双线金框 + 单次脉冲（衰减后仍留双线，结构上区别于单线的干扰项）
        local p = math.max(0, 1 - age / 1.2)
        love.graphics.setColor(1, 0.85, 0.25, 0.75 + 0.25 * p)
        love.graphics.setLineWidth(2 + 4 * p)
        love.graphics.rectangle("line", x - 7, y - 7, w + 14, h + 14, 4)
        love.graphics.setLineWidth(1)
        love.graphics.rectangle("line", x - 12, y - 12, w + 24, h + 24, 4)
    elseif kind == "dB" then
        -- 干扰项：单线金框、常亮，永远不出峰值
        love.graphics.setColor(1, 0.85, 0.25, 0.55)
        love.graphics.setLineWidth(2)
        love.graphics.rectangle("line", x - 7, y - 7, w + 14, h + 14, 4)
    elseif kind == "C" then
        -- 真 C：双线青绿 + 旧牌残影（残影表示「原来那张牌被换走了」）
        love.graphics.setColor(0.3, 1, 0.8, 0.85)
        love.graphics.setLineWidth(3)
        love.graphics.rectangle("line", x - 7, y - 7, w + 14, h + 14, 4)
        love.graphics.setLineWidth(1)
        love.graphics.rectangle("line", x - 12, y - 12, w + 24, h + 24, 4)
        love.graphics.setColor(0.65, 0.65, 0.65, 0.5)
        love.graphics.rectangle("line", x - 17, y - 17, w + 34, h + 34, 4)
    elseif kind == "dC" then
        -- 干扰项：单线青绿、无残影
        love.graphics.setColor(0.3, 1, 0.8, 0.55)
        love.graphics.setLineWidth(2)
        love.graphics.rectangle("line", x - 7, y - 7, w + 14, h + 14, 4)
    elseif kind == "D" then
        -- 真 D 神抽：紫色双线 + 单次脉冲
        local p = math.max(0, 1 - age / 1.2)
        love.graphics.setColor(0.75, 0.4, 1, 0.8 + 0.2 * p)
        love.graphics.setLineWidth(2 + 4 * p)
        love.graphics.rectangle("line", x - 7, y - 7, w + 14, h + 14, 4)
        love.graphics.setLineWidth(1)
        love.graphics.rectangle("line", x - 12, y - 12, w + 24, h + 24, 4)
    elseif kind == "dD" then
        -- 干扰项：单线紫、常亮
        love.graphics.setColor(0.75, 0.4, 1, 0.55)
        love.graphics.setLineWidth(2)
        love.graphics.rectangle("line", x - 7, y - 7, w + 14, h + 14, 4)
    elseif kind == "E" then
        -- 真 E 镜影：蓝色双线（暗牌与你的明牌同点）
        love.graphics.setColor(0.4, 0.7, 1, 0.85)
        love.graphics.setLineWidth(3)
        love.graphics.rectangle("line", x - 7, y - 7, w + 14, h + 14, 4)
        love.graphics.setLineWidth(1)
        love.graphics.rectangle("line", x - 12, y - 12, w + 24, h + 24, 4)
    elseif kind == "dE" then
        -- 干扰项：单线蓝、常亮
        love.graphics.setColor(0.4, 0.7, 1, 0.55)
        love.graphics.setLineWidth(2)
        love.graphics.rectangle("line", x - 7, y - 7, w + 14, h + 14, 4)
    end

    -- 镜影副标记：你的明牌左上角蓝色小菱形（与庄家暗牌同点的"镜子"）
    if card._tellE then
        love.graphics.setColor(0.4, 0.7, 1, 0.9)
        love.graphics.push()
        love.graphics.translate(x + 10, y + 10)
        love.graphics.rotate(math.rad(45))
        love.graphics.rectangle("fill", -4, -4, 8, 8)
        love.graphics.pop()
    end

    love.graphics.setLineWidth(1)
    love.graphics.setColor(1, 1, 1, 1)
end

-- ============================================================
-- 出千华丽演出层：视觉Tell触发时（真/假皆然，防止凭演出直接反推）全屏彩晕
-- + 扩散环 + 字形闪现。颜色与字形按招式区分：换/十/压/神/影。
-- ============================================================
local CHEAT_FX = {
    A = { "换", { 1, 1, 1 } },       B = { "十", { 1, 0.8, 0.2 } },
    C = { "压", { 0.3, 0.9, 0.85 } }, D = { "神", { 0.75, 0.4, 1 } },
    E = { "影", { 0.4, 0.7, 1 } },
    dA = { "换", { 1, 1, 1 } },      dB = { "十", { 1, 0.8, 0.2 } },
    dC = { "压", { 0.3, 0.9, 0.85 } }, dD = { "神", { 0.75, 0.4, 1 } },
    dE = { "影", { 0.4, 0.7, 1 } },
}

function UI.drawCheatFx(state)
    local cs = state.cheatState
    if not (cs and cs.visualTell and cs.cheatTellKind and CHEAT_FX[cs.cheatTellKind]) then return end
    if cs.wasAccused then return end
    if state.state ~= "player" and state.state ~= "dealer" and state.state ~= "result" then return end

    if not cs._fxStart then cs._fxStart = love.timer.getTime() end
    local el = love.timer.getTime() - cs._fxStart
    if el > 1.4 then return end

    local fx = CHEAT_FX[cs.cheatTellKind]
    local cr, cg, cb = fx[2][1], fx[2][2], fx[2][3]
    local a = 1 - el / 1.4
    local w, h = love.graphics.getWidth(), love.graphics.getHeight()

    -- 全屏彩晕（呼吸脉冲）
    love.graphics.setColor(cr, cg, cb, 0.09 * a * (0.7 + 0.3 * math.sin(el * 10)))
    love.graphics.rectangle("fill", 0, 0, w, h)
    -- 扩散环
    love.graphics.setColor(cr, cg, cb, 0.45 * a)
    love.graphics.setLineWidth(3)
    love.graphics.circle("line", w / 2, h * 0.40, 36 + el * 300)
    love.graphics.setLineWidth(1)
    -- 字形闪现（放大淡出）
    love.graphics.setFont(UI.splash.titleFont)
    love.graphics.setColor(cr, cg, cb, 0.85 * a)
    love.graphics.print(fx[1], w / 2 - 19, h * 0.40 - 22, 0, 1 + el * 0.8, 1 + el * 0.8)
    love.graphics.setColor(1, 1, 1)
end

-- ============================================================
-- 侧边栏：玩家持有遗物
-- ============================================================
function UI.drawRelics(state)
    -- 酒吧模式：遗物区位改为「调酒栏」+ 局数进度 + 醉酒倒计时（见 UI.drawBarShelf）
    if state.gameMode == "bar" then return UI.drawBarShelf(state) end

    local sx = sidebar_x + 4

    -- ========== 无标题文字：icon 直接从 sidebar 最顶开始 ==========
    -- 严格分两块：遗物区 (topPadding ~ bottomReserved) + 阶段进度区 (window_height - bottomReserved)
    -- 两块绝不重叠，中间 bottomReserved 是完全独立的区域高度

    local topPadding = 10          -- icon 起点，sidebar 最顶
    -- 阶段进度区实际需要 5 行（阶段/名称/进度条/回合/最低+商店）≈ 91px，
    -- 78 会让最后一行"商店: N 轮后"被窗口底边裁掉 → 96 保证完整显示
    local bottomReserved = 96      -- 阶段进度区高度（从 window_height - bottomReserved 开始）
    local infoH = 34               -- 出千情报区高度（遗物区与阶段进度区之间的独立区域）
    local MAX_SLOTS = 5
    local gap = 4
    local nameH = 14
    local marksH = 58              -- 特种标记区高度（标题 16 + 图标 28 + 次数标签 14）
    -- 遗物可用高度 = 总高 - 顶部留白 - 阶段区 - 情报区 - 特种标记区 - 三处间隔
    -- （情报区从遗物区下方独立切出，绝不挤占 bottomReserved = 96）
    local availH = window_height - topPadding - bottomReserved - infoH - marksH - gap * 3
    local perSlotH = math.floor((availH - gap * (MAX_SLOTS - 1)) / MAX_SLOTS)
    local icon_h = math.max(30, perSlotH - nameH - 2)
    local icon_size = math.min(sidebar_width - 8, math.floor(icon_h * 0.74))
    local iconStartY = topPadding

    for i, relic in ipairs(state.relics) do
        local iy = iconStartY + (i - 1) * (icon_h + gap)
        local isPreGame = Relics.isPreGame(relic)
        local isActive = relic.active == true
        local popY = 0
        local greyTint = false

        if isPreGame then
            popY = 0
        elseif isActive then
            popY = -8
        else
            popY = 0; greyTint = true
        end

        UI.drawRelicIcon(relic, sx + (sidebar_width - icon_size) / 2, iy + popY, icon_size, icon_h, greyTint)

        -- 反制遗物「本小局是否已生效」：图标左上角金色圆点（resetRound 每小局清空）
        if relic._roundActive then
            local dotX = sx + (sidebar_width - icon_size) / 2 + 6
            local dotY = iy + popY + 6
            love.graphics.setColor(1, 0.85, 0.2)
            love.graphics.circle("fill", dotX, dotY, 4)
            love.graphics.setColor(0.35, 0.25, 0)
            love.graphics.circle("line", dotX, dotY, 4)
        end

        local markX = sx + sidebar_width - 14
        local markY = iy + popY - 2
        love.graphics.setFont(UI.cjkFontSmall)
        if isPreGame then
            love.graphics.setColor(0.4, 0.8, 1, 0.9)
            love.graphics.circle("fill", markX, markY, 9)
            love.graphics.setColor(0, 0, 0); love.graphics.printf("P", markX - 5, markY - 7, 10, "center")
        elseif isActive then
            love.graphics.setColor(0.3, 1, 0.3, 0.9)
            love.graphics.circle("fill", markX, markY, 9)
            love.graphics.setColor(0, 0, 0); love.graphics.printf("+", markX - 5, markY - 7, 10, "center")
        end

        love.graphics.setFont(UI.cjkFontSmall)
        if relic._roundActive then love.graphics.setColor(1, 0.85, 0.2)
        elseif greyTint then love.graphics.setColor(0.5, 0.5, 0.5)
        else love.graphics.setColor(1, 1, 1) end
        local displayName = relic.name
        if relic._forged then
            displayName = relic.name .. "(永久)"
        elseif relic._consumable then
            displayName = relic.name .. "(" .. (relic._usesLeft or 0) .. ")"
        end
        -- 名称只占布局留给名字的那一行（nameH），放不下则截断并以 "..." 结尾
        local shownName = UI.fitTextEllipsis(displayName, UI.cjkFontSmall, sidebar_width - 8, nameH)
        love.graphics.printf(shownName, sx + 2, iy + icon_h + 2 + popY, sidebar_width - 8, "center")

        UI.addHoverTarget(relic, sx + 2, iy + popY, sidebar_width - 8, icon_h + 18)
    end

    -- 连胜
    if state.streak and state.streak >= 2 then
        local ly = iconStartY + #state.relics * (icon_h + gap) + 10
        love.graphics.setFont(UI.font); love.graphics.setColor(1, 0.8, 0.2)
        love.graphics.printf("[连胜] x" .. state.streak, sx, ly, sidebar_width - 8, "center")
    end

    -- ========== 特种标记区（遗物栏专属区域：不占 5 格，显示当前标记与使用情况）==========
    -- 布局数字必须与 UI.hitTestRelicBar 保持一致（marksH）
    local marksY = iconStartY + availH + gap
    love.graphics.setFont(UI.cjkFontSmall)
    love.graphics.setColor(0.75, 0.65, 0.92)
    love.graphics.print("特种标记", sx + 4, marksY)

    local marks = state.specialMarks or {}
    local markIconY = marksY + 17
    local markIconW, markIconH = 26, 28
    local markGap = 3
    if #marks == 0 then
        love.graphics.setFont(UI.cjkFontSmall)
        love.graphics.setColor(0.42, 0.42, 0.48)
        love.graphics.printf("（无）", sx, markIconY + 8, sidebar_width - 8, "center")
    else
        local roundUsed = state._specialMarkUsedRound == true
        for mi, m in ipairs(marks) do
            local lib = Relics.getById(m.id)
            if lib and mi <= 5 then
                local mxp = sx + 4 + (mi - 1) * (markIconW + markGap)
                -- 本回合标记已用（未铸造）→ 置灰
                UI.drawRelicIcon({ markDot = lib.markDot }, mxp, markIconY, markIconW, markIconH, roundUsed and not m.forged)
                -- 剩余次数标签（∞ = 铸造后的永久标记），挂在图标正下方
                love.graphics.setFont(UI.cjkFontSmall)
                love.graphics.setColor(m.forged and {0.75, 0.55, 1} or {1, 0.9, 0.55})
                love.graphics.printf(m.forged and "∞" or ("x" .. (m.uses or 0)), mxp, markIconY + markIconH + 1,
                                     markIconW, "center")
                -- 悬停：显示具体功能说明
                UI.addHoverTarget({ _markTip = true, markId = m.id, uses = m.uses, forged = m.forged },
                                   mxp - 1, markIconY - 1, markIconW + 2, markIconH + 13)
            end
        end
    end

    -- ========== 出千情报区（遗物区与阶段进度区之间，独立区域，绝不重叠）==========
    -- 只公开「本阶段作弊概率」这一固定信息；不给「本局是否已作弊 / 痕迹有无」任何提示
    local infoY = marksY + marksH + gap
    local chance = (state.cheatChance and state.cheatChance[state.stage]) or 0
    local infoW = sidebar_width - 8
    local pBarW = sidebar_width - 12
    love.graphics.setFont(UI.cjkFontSmall); love.graphics.setColor(0.72, 0.72, 0.72)
    love.graphics.printf("出千概率", sx, infoY, infoW, "center")
    love.graphics.setColor(0.2, 0.2, 0.2)
    love.graphics.rectangle("fill", sx + 6, infoY + 15, pBarW, 4, 2)
    love.graphics.setColor(0.85, 0.35, 0.3)
    love.graphics.rectangle("fill", sx + 6, infoY + 15, pBarW * math.min(1, chance), 4, 2)
    love.graphics.setColor(1, 0.85, 0.6)
    love.graphics.printf(math.floor(chance * 100 + 0.5) .. "%", sx, infoY + 19, infoW, "center")
    love.graphics.setColor(1, 1, 1)

    -- ========== 底部阶段进度区（独立区域，绝不和遗物重叠）==========
    local stageColors = { [1] = {0.3, 0.8, 0.3}, [2] = {0.8, 0.6, 0.2}, [3] = {0.9, 0.2, 0.2} }
    local sc = stageColors[state.stage] or {1, 1, 1}
    local bottomY = window_height - bottomReserved

    love.graphics.setFont(UI.cjkFont); love.graphics.setColor(sc[1], sc[2], sc[3])
    love.graphics.printf("阶段 " .. state.stage .. "/3", sx, bottomY, sidebar_width - 8, "center")
    love.graphics.setFont(UI.cjkFontSmall); love.graphics.setColor(0.85, 0.85, 0.85)
    love.graphics.printf(state.stageName and state.stageName[state.stage] or "", sx, bottomY + 18, sidebar_width - 8, "center")

    local barY = bottomY + 34; local barW = sidebar_width - 12; local barH = 5
    local rounds = state.roundsInStage or 0; local total = (state.stageEveryN and state.stageEveryN[state.stage]) or 15
    love.graphics.setColor(0.2, 0.2, 0.2); love.graphics.rectangle("fill", sx + 6, barY, barW, barH, 2)
    love.graphics.setColor(sc[1], sc[2], sc[3])
    love.graphics.rectangle("fill", sx + 6, barY, barW * math.min(1, rounds/total), barH, 2)
    love.graphics.setColor(1, 1, 1); love.graphics.setFont(UI.cjkFontSmall)
    love.graphics.printf(rounds .. "/" .. total, sx, barY + 7, sidebar_width - 8, "center")

    local minChips = state.stageMinChips and state.stageMinChips[state.stage] or 0
    if minChips > 0 then
        love.graphics.setColor(state.player.chips >= minChips and {0.3, 1, 0.3} or {1, 0.3, 0.3})
        love.graphics.printf("最低: $" .. minChips, sx, barY + 23, sidebar_width - 8, "center")
    end

    if state.state ~= "shop" and state.shopEveryN and state.roundsSinceShop then
        local rem = math.max(0, state.shopEveryN - state.roundsSinceShop)   -- 刚好21的提前量可把余额打到 0
        love.graphics.setColor(1, 0.8, 0.3)
        love.graphics.printf("商店: " .. rem .. " 轮后", sx, barY + 41, sidebar_width - 8, "center")
    end
end

-- ============================================================
-- 酒吧模式：调酒栏 / 局数进度 / 醉酒倒计时（替换遗物区 + 出千情报区 + 阶段进度区）
--   调酒栏最多 6 杯；每杯 = 酒杯容器 + 酒立绘 + 剩余口数
--   热区写入 UI._barCupsBtns（main.lua 读取，绘制与点击同一份坐标）
-- ============================================================

-- 画一款酒的立绘（assets/bar/cocktails/<id>.png，等比缩放居中；缺图退回酒杯配色块）
function UI.barDrawDrink(id, x, y, w, h)
    local def = Cocktails.getById(id)
    love.graphics.setColor(def and def.color or { 0.3, 0.3, 0.3 })
    love.graphics.rectangle("fill", x, y, w, h, 3)
    local img = UI.bar and UI.bar.drinks and UI.bar.drinks[id]
    if img then
        local iw, ih = img:getDimensions()
        local scale = math.min(w / iw, h / ih)
        love.graphics.setColor(1, 1, 1)
        love.graphics.draw(img, x + (w - iw * scale) / 2, y + (h - ih * scale) / 2, 0, scale, scale)
    end
    love.graphics.setColor(0.9, 0.82, 0.6, 0.9)
    love.graphics.rectangle("line", x, y, w, h, 3)
    love.graphics.setColor(1, 1, 1)
end

-- 酒的立绘按 40:58 比例由高定宽（超宽则由宽定高），返回实际绘制的宽、高
function UI.barDrinkIconSize(w, h, maxW)
    local imgW = h * (40 / 58)
    local imgH = h
    if imgW > (maxW or w) then imgW = maxW or w; imgH = imgW * (58 / 40) end
    return imgW, imgH
end

-- 单杯（酒杯容器 + 酒立绘 + 剩余口数），并登记悬停目标
function UI.drawBarCup(state, cup, x, y, w, h)
    local th = UI.barTheme
    local def = Cocktails.getById(cup.id)
    local left = Cocktails.poursLeft(cup)

    local wob = 0
    if cup.wobble and cup.wobble > 0 then
        local age = love.timer.getTime() - cup.wobble
        if age >= 0 and age < 0.6 then wob = math.sin(age * 30) * 3 end
    end

    love.graphics.setColor(th.glassFill[1], th.glassFill[2], th.glassFill[3], 0.95)
    love.graphics.rectangle("fill", x + wob, y, w, h, 4)
    love.graphics.setColor(th.accent[1], th.accent[2], th.accent[3], 0.85)
    love.graphics.rectangle("line", x + wob, y, w, h, 4)

    local imgW, imgH = UI.barDrinkIconSize(w * 0.5, h - 4)
    UI.barDrawDrink(cup.id, x + wob + 2, y + (h - imgH) / 2, imgW, imgH)

    local tx = x + wob + imgW + 5
    local tw = w - imgW - 9
    love.graphics.setFont(UI.cjkFontSmall)
    love.graphics.setColor(def and def.color or th.text)
    local shown = UI.fitTextEllipsis(def and def.name or cup.id, UI.cjkFontSmall, tw, math.floor(h * 0.5))
    love.graphics.printf(shown, tx, y + 2, tw, "left")
    love.graphics.setColor(th.text)
    love.graphics.printf("剩余 " .. left .. " / " .. Cocktails.POURS_PER_CUP .. " 口", tx, y + h * 0.5, tw, "left")

    UI.addHoverTarget({ kind = "barCup", barId = cup.id, cup = cup }, x, y, w, h)
end

function UI.drawBarShelf(state)
    local th = UI.barTheme
    local bar = state.bar
    if not bar then return end

    local sx = sidebar_x + 4
    local sw = sidebar_width - 8
    local MAX_CUPS = 6
    local topPadding = 10
    local bottomReserved = 96      -- 底部「局数」区高度（沿用工程硬约束：数值不动，保证局数行原地保留、文字不溢出窗口底）
    local gap = 4
    local headerH = 16
    local cupTop = topPadding + headerH
    local cdH = math.max(66, math.floor(window_height * 0.16))   -- 醉酒倒计时区
    local availH = window_height - cupTop - bottomReserved - gap * 2 - cdH
    local perSlotH = math.floor((availH - gap * (MAX_CUPS - 1)) / MAX_CUPS)
    if perSlotH < 22 then perSlotH = 22 end

    UI._barCupsBtns = {}

    love.graphics.setFont(UI.cjkFontSmall); love.graphics.setColor(th.accent)
    love.graphics.printf("调酒栏 " .. #bar.cups .. " / " .. MAX_CUPS, sx, topPadding, sw, "center")

    for i = 1, MAX_CUPS do
        local y = cupTop + (i - 1) * (perSlotH + gap)
        local cup = bar.cups[i]
        if cup then
            UI.drawBarCup(state, cup, sx, y, sw, perSlotH)
            UI._barCupsBtns[#UI._barCupsBtns + 1] = { x = sx, y = y, w = sw, h = perSlotH, _index = i }
        else
            love.graphics.setColor(th.cupEmpty[1], th.cupEmpty[2], th.cupEmpty[3], 0.35)
            love.graphics.rectangle("line", sx, y, sw, perSlotH, 3)
        end
    end

    -- ===== 醉酒倒计时区（替换原「出千情报区」）=====
    local cdTop = window_height - bottomReserved - cdH
    love.graphics.setFont(UI.cjkFontSmall); love.graphics.setColor(th.accent)
    love.graphics.printf("醉酒倒计时", sx, cdTop, sw, "center")

    local active = Cocktails.activeList(state)
    local lineH = math.max(16, math.min(20, math.floor(cdH / 5)))
    local rowY = cdTop + 17
    local rowsBottom = window_height - bottomReserved
    if #active == 0 then
        love.graphics.setColor(th.textDim)
        love.graphics.printf("无", sx, rowY, sw, "center")
    else
        -- 容量预算：可完整容纳的行数上限（超出的条目不再静默吞掉，改显式溢出提示，
        -- 且提示行预先留位 —— 保证它自己也不越界、不与底部局数行重叠）
        local maxRows = math.floor((rowsBottom - rowY) / lineH)
        if maxRows < 1 then maxRows = 1 end
        local shownRows, hiddenRows = #active, 0
        if #active > maxRows then
            hiddenRows = #active - maxRows + 1     -- 最后一行让给溢出提示
            shownRows = maxRows - 1
            if shownRows < 0 then shownRows = 0 end
        end
        for i, item in ipairs(active) do
            if i > shownRows then break end
            local iconH = lineH - 2
            local iconW = iconH * (40 / 58)
            UI.barDrawDrink(item.def.id, sx + 2, rowY, iconW, iconH)
            love.graphics.setFont(UI.cjkFontSmall); love.graphics.setColor(th.text)
            local label = item.def.name .. " " .. item.turns .. " 回合"
            local shown = UI.fitTextEllipsis(label, UI.cjkFontSmall, sw - iconW - 6, lineH)
            love.graphics.printf(shown, sx + iconW + 4, rowY, sw - iconW - 6, "left")
            UI.addHoverTarget({ kind = "barCup", barId = item.def.id, cup = nil },
                              sx, rowY, sw, lineH)
            rowY = rowY + lineH
        end
        if hiddenRows > 0 then
            love.graphics.setFont(UI.cjkFontSmall); love.graphics.setColor(th.textDim)
            love.graphics.printf("另有 " .. hiddenRows .. " 款生效中", sx + 2, rowY, sw - 4, "left")
        end
    end

    -- ===== 底部：只要局数进度 =====
    -- 赠酒概率条与「胜 X 负 Y」已迁到悬停荷官立绘的统计框（UI.drawBarDealerStatBox）；
    -- 局数行的位置与数值原地不变。
    local bottomY = window_height - bottomReserved
    love.graphics.setFont(UI.cjkFont); love.graphics.setColor(th.accent)
    love.graphics.printf("第 " .. (bar.round or 0) .. " / 100 局", sx, bottomY, sw, "center")
    love.graphics.setColor(1, 1, 1)
end

-- ============================================================
-- 酒吧模式：喝酒选择弹窗（模态，独占输入）
--   热区写入 UI._barDrinkBtns（main.lua 读取）
-- ============================================================
function UI.drawBarDrink(state)
    if state.state ~= "bar_drink" then return end
    local th = UI.barTheme
    local bar = state.bar
    local w, h = love.graphics.getWidth(), love.graphics.getHeight()

    love.graphics.setColor(0, 0, 0, 0.80)
    love.graphics.rectangle("fill", 0, 0, w, h)

    local n = bar and #bar.cups or 0
    if n == 0 then UI._barDrinkBtns = nil; return end

    local title = (bar.drinkReason == "loss") and "输了一局 —— 选一杯喝掉 1/5" or "选一杯来喝"
    love.graphics.setColor(th.accent); love.graphics.setFont(UI.cjkFontMid)
    love.graphics.printf(title, 0, h * 0.15, w, "center")

    local gap = math.max(12, math.floor(w * 0.02))
    local cardW = math.min(200, math.floor((w - 80 - gap * (n - 1)) / n))
    local cardH = math.min(260, math.floor(h * 0.44))
    local totalW = cardW * n + gap * (n - 1)
    local startX = (w - totalW) / 2
    local cardY = h / 2 - cardH / 2 + 10

    UI._barDrinkBtns = {}
    local mx, my = love.mouse.getPosition()
    for i, cup in ipairs(bar.cups) do
        local def = Cocktails.getById(cup.id)
        local x = startX + (i - 1) * (cardW + gap)
        local hover = mx >= x and mx <= x + cardW and my >= cardY and my <= cardY + cardH
        love.graphics.setColor(hover and th.btnHover or th.panelFill)
        love.graphics.rectangle("fill", x, cardY, cardW, cardH, 8)
        love.graphics.setColor(th.panelEdge)
        love.graphics.setLineWidth(2)
        love.graphics.rectangle("line", x + 1, cardY + 1, cardW - 2, cardH - 2, 8)
        love.graphics.setLineWidth(1)

        local imgW, imgH = UI.barDrinkIconSize(cardW * 0.6, math.floor(cardH * 0.42))
        UI.barDrawDrink(cup.id, x + (cardW - imgW) / 2, cardY + 12, imgW, imgH)

        love.graphics.setFont(UI.cjkFont); love.graphics.setColor(def and def.color or th.text)
        love.graphics.printf(def and def.name or cup.id, x, cardY + 18 + imgH, cardW, "center")
        love.graphics.setFont(UI.cjkFontSmall); love.graphics.setColor(th.text)
        love.graphics.printf("剩余 " .. Cocktails.poursLeft(cup) .. " / " .. Cocktails.POURS_PER_CUP .. " 口",
                             x, cardY + 52 + imgH, cardW, "center")
        love.graphics.setColor(th.accent)
        love.graphics.printf("喝 1 口", x, cardY + cardH - 26, cardW, "center")

        UI._barDrinkBtns[#UI._barDrinkBtns + 1] = { x = x, y = cardY, w = cardW, h = cardH, _index = i }
    end
    love.graphics.setColor(1, 1, 1)
end

-- ============================================================
-- 酒吧模式：赠酒三选一弹窗（模态，独占输入）
--   热区写入 UI._barGiftBtns（main.lua 读取）
-- ============================================================
function UI.drawBarGift(state)
    if state.state ~= "bar_gift" then return end
    local th = UI.barTheme
    local bar = state.bar
    local ids = bar and bar.giftOfferIds
    if not ids or #ids == 0 then UI._barGiftBtns = nil; return end
    local w, h = love.graphics.getWidth(), love.graphics.getHeight()

    love.graphics.setColor(0, 0, 0, 0.80)
    love.graphics.rectangle("fill", 0, 0, w, h)

    love.graphics.setColor(th.accent); love.graphics.setFont(UI.cjkFontMid)
    love.graphics.printf("酒保请客 —— 三选一", 0, h * 0.10, w, "center")

    local n = #ids
    local gap = math.max(14, math.floor(w * 0.025))
    local cardW = math.min(240, math.floor((w * 0.8 - gap * (n - 1)) / n))
    local cardH = math.min(300, math.floor(h * 0.52))
    local totalW = cardW * n + gap * (n - 1)
    local startX = (w - totalW) / 2
    local cardY = h / 2 - cardH / 2 + 12

    UI._barGiftBtns = {}
    local mx, my = love.mouse.getPosition()
    for i, id in ipairs(ids) do
        local def = Cocktails.getById(id)
        local x = startX + (i - 1) * (cardW + gap)
        local hover = mx >= x and mx <= x + cardW and my >= cardY and my <= cardY + cardH
        love.graphics.setColor(hover and th.btnHover or th.panelFill)
        love.graphics.rectangle("fill", x, cardY, cardW, cardH, 8)
        love.graphics.setColor(th.panelEdge)
        love.graphics.setLineWidth(2)
        love.graphics.rectangle("line", x + 1, cardY + 1, cardW - 2, cardH - 2, 8)
        love.graphics.setLineWidth(1)

        local imgW, imgH = UI.barDrinkIconSize(cardW * 0.5, math.floor(cardH * 0.36))
        UI.barDrawDrink(id, x + (cardW - imgW) / 2, cardY + 12, imgW, imgH)

        love.graphics.setFont(UI.cjkFont); love.graphics.setColor(def and def.color or th.text)
        love.graphics.printf(def and def.name or id, x, cardY + 18 + imgH, cardW, "center")

        love.graphics.setColor(th.text)
        UI.drawWrappedText(def and def.desc or "", UI.cjkFontSmall, x + 10, cardY + 68 + imgH,
                           cardW - 20, math.max(15, math.floor(h * 0.022)), nil, "center")

        UI._barGiftBtns[#UI._barGiftBtns + 1] = { x = x, y = cardY, w = cardW, h = cardH, _index = i }
    end
    love.graphics.setColor(1, 1, 1)
end

-- ============================================================
-- 酒吧模式：说明弹窗（两页，模态；热区 UI._barBriefBtn 单一数据源）
-- 第 1 页「怎么玩」/ 第 2 页「醉酒」；最后一页按钮关闭。
-- 前进方式：点按钮 或 ESC/空格/回车（不得「点任意处关闭」跳过第 1 页）。
-- ============================================================
function UI.drawBarBrief(state)
    if state.state ~= "bar_brief" then return end
    local th = UI.barTheme
    local w, h = love.graphics.getWidth(), love.graphics.getHeight()

    -- 页码（由 game_state.barStartNewGame / barBriefNext 维护；这里只做防御性夹取）
    local page = state._barBriefPage or 1
    if page < 1 then page = 1 elseif page > 2 then page = 2 end
    local isLast = (page == 2)

    love.graphics.setColor(0, 0, 0, 0.80)
    love.graphics.rectangle("fill", 0, 0, w, h)

    local pw = math.min(660, w - 60)
    local ph = math.min(470, h - 60)
    local px = (w - pw) / 2
    local py = (h - ph) / 2

    love.graphics.setColor(th.panelFill[1], th.panelFill[2], th.panelFill[3], 0.98)
    love.graphics.rectangle("fill", px, py, pw, ph, 10)
    love.graphics.setColor(th.panelEdge)
    love.graphics.setLineWidth(2); love.graphics.rectangle("line", px, py, pw, ph, 10); love.graphics.setLineWidth(1)

    local headerH = 42
    love.graphics.setColor(th.headerFill)
    love.graphics.rectangle("fill", px, py, pw, headerH, 10, 10, 0, 0)
    love.graphics.setColor(th.accent); love.graphics.setFont(UI.cjkFontMid)
    local title = (page == 1) and "酒吧模式 · 怎么玩" or "酒吧模式 · 醉酒"
    love.graphics.printf(title, px, py + 11, pw, "center")

    local lx = px + 26
    local lw = pw - 52
    local ly = py + headerH + 18

    -- 按钮几何（先算好，用于给正文留出安全下边界）
    local btnW, btnH = 160, 30
    local btnX = px + pw / 2 - btnW / 2
    local btnY = py + ph - btnH - 18
    local bodyBottom = btnY - 10                     -- 正文不得压到按钮

    -- ===== 两页文案（CJK 逐条；chars 为原文，不翻译）=====
    local blocks
    if page == 1 then
        blocks = {
            { font = UI.cjkFont, color = th.accent, gap = 8, lines = {
                "点酒就是喝酒 —— 在调酒栏点一杯酒，等于主动喝掉它的 1/5，同一杯要喝 5 次才空，不是直接发动效果。",
            } },
            { font = UI.cjkFontSmall, color = th.textDim, gap = 5, lines = {
                "这里没有筹码、下注、破产、商店、遗物与职阶；固定 100 小局，每小局直接发牌比大小。",
                "每输一局必须喝 1/5 杯；调酒栏最多同时放 6 杯。",
                "一杯酒喝空就出栏；调酒栏空了，你就会被酒保请出去。",
                "每赢一局，酒保赠酒的概率会上升；每满 20 局，必请你从三款新酒里三选一。",
                "想随时重看这份说明，点顶栏右侧的「说明」。",
            } },
            { font = UI.cjkFontSmall, color = th.text, gap = 5, lines = {
                "牌组构成规则：从全部 10 种特殊牌组里各随机挑一张样牌，样牌点数尽量互不相同（没有点数的牌组就随机）；",
                "每种复制 10 张，合计 10 种 / 100 张，构成本模式唯一牌组。",
            } },
        }
    else
        blocks = {
            { font = UI.cjkFont, color = th.text, gap = 8, lines = {
                "喝一口 = 该酒进入 5 小局「醉酒」状态。多款可同时生效；同一款只刷新剩余回合，不叠层。",
            } },
            { font = UI.cjkFontSmall, color = th.textDim, gap = 5, lines = {
                "要牌键左侧的「调酒」键：点开选一项，就能发动对应技能；每款酒每小局最多用 1 次。",
                "侧栏能看到每款酒还剩几小局（剩余回合）。",
                "倒计时结束时，下一小局是该酒的「宿醉」：手牌模糊，数字看不清只留轮廓，",
                "整屏再叠一层该酒颜色的淡色滤镜；再下一小局恢复正常。",
            } },
        }
    end

    -- ===== 溢出保护：先量总高，超了就压缩行距，仍超就丢掉末尾条目 =====
    local function blockHeight(b)
        local total = 0
        for _, s in ipairs(b.lines) do
            local _, wrapped = b.font:getWrap(s, lw)
            total = total + #wrapped * b.font:getHeight()
        end
        return total + b.gap
    end
    local availH = bodyBottom - ly
    local gapScale = 1
    local totalH = 0
    for _, b in ipairs(blocks) do totalH = totalH + blockHeight(b) end
    if totalH > availH then
        gapScale = 0                                  -- 先挤掉所有条目间距
        totalH = 0
        for _, b in ipairs(blocks) do totalH = totalH + blockHeight(b) - b.gap end
        while #blocks > 1 and totalH > availH do      -- 仍放不下就丢末尾条目
            local last = table.remove(blocks)
            totalH = totalH - (blockHeight(last) - last.gap)
        end
    end

    love.graphics.setScissor(px, py + headerH, pw, bodyBottom - (py + headerH))
    for _, b in ipairs(blocks) do
        love.graphics.setFont(b.font); love.graphics.setColor(b.color)
        for _, s in ipairs(b.lines) do
            local _, wrapped = b.font:getWrap(s, lw)
            love.graphics.printf(s, lx, ly, lw, "left")
            ly = ly + #wrapped * b.font:getHeight()
            if ly > bodyBottom then break end
        end
        ly = ly + b.gap * gapScale
    end
    love.graphics.setScissor()

    -- ===== 页脚：页码 + 前进提示 =====
    love.graphics.setFont(UI.cjkFontSmall); love.graphics.setColor(th.textDim)
    love.graphics.printf("第 " .. page .. " / 2 页", lx, btnY + 8, lw, "left")
    love.graphics.printf("ESC 或点按钮继续", lx, btnY + 8, lw, "right")

    -- ===== 按钮：第 1 页「下一页」/ 第 2 页「开始」 =====
    local mx, my = love.mouse.getPosition()
    local hover = mx >= btnX and mx <= btnX + btnW and my >= btnY and my <= btnY + btnH
    love.graphics.setColor(hover and th.btnHover or th.btnFill)
    love.graphics.rectangle("fill", btnX, btnY, btnW, btnH, 5)
    love.graphics.setColor(th.panelEdge)
    love.graphics.rectangle("line", btnX, btnY, btnW, btnH, 5)
    love.graphics.setFont(UI.cjkFontSmall); love.graphics.setColor(1, 1, 1)
    love.graphics.printf(isLast and "开始" or "下一页", btnX, btnY + 7, btnW, "center")

    UI._barBriefBtn = { x = btnX, y = btnY, w = btnW, h = btnH }
    love.graphics.setColor(1, 1, 1)
end

-- ============================================================
-- 酒吧模式：结局画面（热区 UI._barEndingBtn）
-- ============================================================
function UI.drawBarEnding(state)
    if state.state ~= "bar_ending" then return end
    local th = UI.barTheme
    local w, h = love.graphics.getWidth(), love.graphics.getHeight()

    love.graphics.setColor(0, 0, 0, 0.90)
    love.graphics.rectangle("fill", 0, 0, w, h)

    local map = {
        date  = { title = "与酒保的约会", sub = "全场只剩一口酒 —— 他把最后一口留给了你。" },
        fish  = { title = "养鱼",         sub = "六杯都还有剩 —— 酒保说你更适合回去养鱼。" },
        buddy = { title = "好酒友",       sub = "还有酒没喝完 —— 你们成了天长地久的好酒友。" },
    }
    local info = map[state.barEnding] or map.buddy

    love.graphics.setColor(th.accent); love.graphics.setFont(UI.cjkFontTitle)
    love.graphics.printf(info.title, 0, h * 0.26, w, "center")
    love.graphics.setFont(UI.cjkFontMid); love.graphics.setColor(th.text)
    love.graphics.printf(info.sub, 0, h * 0.42, w, "center")

    local total = Cocktails.totalPours(state)
    local cups = (state.bar and state.bar.cups) and #state.bar.cups or 0
    love.graphics.setFont(UI.cjkFontSmall); love.graphics.setColor(th.textDim)
    love.graphics.printf("剩余酒量 " .. total .. " 口 · 剩余酒杯 " .. cups .. " 杯", 0, h * 0.50, w, "center")

    local btnW, btnH = 220, 44
    local btnX = w / 2 - btnW / 2
    local btnY = h * 0.64
    local mx, my = love.mouse.getPosition()
    local hover = mx >= btnX and mx <= btnX + btnW and my >= btnY and my <= btnY + btnH
    love.graphics.setColor(hover and th.btnHover or th.btnFill)
    love.graphics.rectangle("fill", btnX, btnY, btnW, btnH, 6)
    love.graphics.setColor(th.panelEdge)
    love.graphics.setLineWidth(2); love.graphics.rectangle("line", btnX, btnY, btnW, btnH, 6); love.graphics.setLineWidth(1)
    love.graphics.setFont(UI.cjkFont); love.graphics.setColor(1, 1, 1)
    love.graphics.printf("回到主界面", btnX, btnY + 12, btnW, "center")

    UI._barEndingBtn = { x = btnX, y = btnY, w = btnW, h = btnH }
    love.graphics.setColor(1, 1, 1)
end

-- ============================================================
-- 酒吧模式：主动技能 —— 调酒键 / 展开列表 / 通用选牌模态
--   热区：UI._alcBtn（调酒键）、UI._alcMenuBtns（列表项）、UI._barAlcPickBtns（选牌项）、
--         UI._barAlcPickCancel / UI._barAlcPickConfirm（选牌模态按钮）
--   一律由绘制写入，main.lua 读同一份（单一数据源）
-- ============================================================

-- 调酒键：只在「酒吧模式 + 玩家回合」绘制；enabled 写回热区供点击判定
function UI.drawBarAlcButton(state)
    local b = UI._alcBtn
    if not b then return end
    local list = GameState.barAbilityList(state)
    local enabled = false
    for _, it in ipairs(list) do if it.usable then enabled = true break end end
    b.enabled = enabled

    local mx, my = love.mouse.getPosition()
    local hover = mx >= b.x and mx <= b.x + b.w and my >= b.y and my <= b.y + b.h
    if enabled then
        love.graphics.setColor(hover and { 0.30, 0.55, 0.75 } or { 0.18, 0.38, 0.58 })
    else
        love.graphics.setColor(0.28, 0.28, 0.30)
    end
    love.graphics.rectangle("fill", b.x, b.y, b.w, b.h, 5)
    love.graphics.setColor(enabled and { 1, 1, 1 } or { 0.60, 0.60, 0.60 })
    love.graphics.setFont(UI.cjkFont)
    love.graphics.printf("回味 " .. #list, b.x, b.y + b.h / 2 - 12, b.w, "center")
end

-- 展开列表：锚定在调酒键「上方」（键在屏幕下半部，向下展出会出窗），绝不进 sidebar
function UI.drawBarAlcMenu(state)
    if not state._barAlcOpen then
        UI._alcMenuBtns = nil
        UI._alcMenuRect = nil
        UI._alcMenuScroll = nil
        UI._alcMenuMaxScroll = nil
        return
    end
    -- 设置页 / 牌堆总览抢了前台 → 展开列表自动收起，避免两层叠在一起
    if state.settingsOpen or state.deckOverviewOpen then
        state._barAlcOpen = nil
        UI._alcMenuBtns = nil
        UI._alcMenuRect = nil
        UI._alcMenuScroll = nil
        UI._alcMenuMaxScroll = nil
        return
    end
    local b = UI._alcBtn
    local list = GameState.barAbilityList(state)
    if not b or #list == 0 then
        state._barAlcOpen = nil            -- 无生效酒 → 自动关掉，不留空壳
        UI._alcMenuBtns = nil
        UI._alcMenuRect = nil
        UI._alcMenuScroll = nil
        UI._alcMenuMaxScroll = nil
        return
    end

    local th = UI.barTheme
    local W = window_width - sidebar_width      -- 桌面有效宽度（sidebar 左侧）
    local H = window_height
    local pad = math.max(8, math.floor(H * 0.012))
    local menuW = math.min(math.floor(W * 0.52), math.floor(b.w * 3.8))
    if menuW < b.w then menuW = b.w end
    local rowH = math.max(48, math.floor(H * 0.088))
    -- 限高：面板绝不长出窗口顶部，也绝不压住按键 —— 高度以「键上方可用空间」封顶，
    -- 条目放不下时滚轮滚动（main.lua wheelmoved 的酒吧段读 _alcMenuMaxScroll），
    -- 不再静默长出窗口或遮挡其他元素。
    local maxH = b.y - pad * 2
    local fullH = rowH * #list + pad * 2
    local menuH = math.min(fullH, maxH)
    if menuH < rowH + pad * 2 then menuH = rowH + pad * 2 end   -- 至少露出 1 行
    local footerH = 0
    local maxScroll = 0
    if fullH > menuH then
        maxScroll = #list - math.floor((menuH - pad * 2) / rowH)
        if maxScroll < 1 then maxScroll = 1 end
        footerH = math.max(16, math.floor(H * 0.022))
    end
    local visibleRows = math.max(1, math.floor((menuH - pad * 2 - footerH) / rowH))
    if UI._alcMenuScroll == nil then UI._alcMenuScroll = 0 end
    if UI._alcMenuScroll > maxScroll then UI._alcMenuScroll = maxScroll end
    if UI._alcMenuScroll < 0 then UI._alcMenuScroll = 0 end
    UI._alcMenuMaxScroll = maxScroll
    local first = 1 + UI._alcMenuScroll         -- 首个可见行（1 起）
    local last = math.min(#list, first + visibleRows - 1)

    local x = b.x
    if x + menuW > W - pad then x = W - pad - menuW end
    if x < pad then x = pad end
    local y = b.y - menuH - pad                  -- 上方
    if y < pad then y = pad end

    UI._alcMenuRect = { x = x, y = y, w = menuW, h = menuH }
    UI._alcMenuBtns = {}

    love.graphics.setColor(th.panelFill[1], th.panelFill[2], th.panelFill[3], 0.97)
    love.graphics.rectangle("fill", x, y, menuW, menuH, 8)
    love.graphics.setColor(th.panelEdge)
    love.graphics.setLineWidth(2)
    love.graphics.rectangle("line", x + 1, y + 1, menuW - 2, menuH - 2, 8)
    love.graphics.setLineWidth(1)

    local mx, my = love.mouse.getPosition()
    for i = first, last do
        local it = list[i]
        local ry = y + pad + (i - first) * rowH
        local rh = rowH - pad
        local enabled = it.usable and not it.used
        local innerX = x + pad
        local innerW = menuW - pad * 2
        local hover = mx >= innerX and mx <= innerX + innerW
                      and my >= ry and my <= ry + rh
        if enabled and hover then
            love.graphics.setColor(th.btnHover)
        else
            love.graphics.setColor(th.glassFill)
        end
        love.graphics.rectangle("fill", innerX, ry, innerW, rh, 5)

        -- 酒的立绘图标（40:58 比例）
        local iconH = rh - 6
        local iconW = iconH * (40 / 58)
        UI.barDrawDrink(it.id, innerX + 4, ry + 3, iconW, iconH)

        local tx = innerX + 10 + iconW
        local tw = innerW - iconW - 22
        local textY = ry + 4
        love.graphics.setFont(UI.cjkFont)
        love.graphics.setColor(enabled and (it.def.color or th.text) or th.textDim)
        love.graphics.printf(it.def.name .. "  「" .. it.ability.name .. "」", tx, textY, tw, "left")

        love.graphics.setFont(UI.cjkFontSmall)
        love.graphics.setColor(enabled and th.text or th.textDim)
        local descY = ry + rh - math.max(18, math.floor(rh * 0.44))
        local shown = UI.fitTextEllipsis(it.ability.desc, UI.cjkFontSmall, tw,
                                         math.max(14, ry + rh - 4 - descY))
        love.graphics.printf(shown, tx, descY, tw, "left")

        -- 状态标记（右对齐，与酒名同一行）
        love.graphics.setFont(UI.cjkFontSmall)
        love.graphics.setColor(th.textDim)
        love.graphics.printf(it.used and "本局已用" or (enabled and "" or "暂不可用"),
                             innerX, textY + 2, innerW - 8, "right")

        UI._alcMenuBtns[#UI._alcMenuBtns + 1] =
            { x = innerX, y = ry, w = innerW, h = rh, id = it.id, enabled = enabled }
    end
    if maxScroll > 0 then
        -- 显式滚动提示（footer 预留位，不与任何行重叠）：另有 N 款，滚轮查看
        love.graphics.setFont(UI.cjkFontSmall)
        love.graphics.setColor(th.textDim)
        love.graphics.printf("另有 " .. maxScroll .. " 项，滚轮查看", x + pad,
                             y + menuH - footerH - 2, menuW - pad * 2, "right")
    end
    love.graphics.setColor(1, 1, 1)
end

-- 通用选牌模态（swap / snatch / chaos / peek3）：独占输入的弹窗，必须有取消入口
-- 每项热区 { x, y, w, h, arg, toggle }；arg 的含义由技能自己解释
function UI.drawBarAlcPick(state)
    if state.state ~= "bar_alcpick" then
        UI._barAlcPickBtns   = nil
        UI._barAlcPickCancel = nil
        UI._barAlcPickConfirm= nil
        UI._barAlcPickMaxScroll = 0
        return
    end
    local pick = state._barAlcPick
    local th = UI.barTheme
    local w, h = love.graphics.getWidth(), love.graphics.getHeight()

    love.graphics.setColor(0, 0, 0, 0.82)
    love.graphics.rectangle("fill", 0, 0, w, h)

    UI._barAlcPickBtns = {}
    UI._barAlcPickCancel = nil
    UI._barAlcPickConfirm = nil
    UI._barAlcPickMaxScroll = 0
    if not pick then return end

    local def = Cocktails.getById(pick.id)
    local title
    if pick.key == "peek3" then
        title = "透牌 — 点一张切换「沉底」（可多选）"
    elseif pick.key == "swap" then
        title = pick.step == 1 and "换牌 — 选你自己的一张手牌" or "换牌 — 选一张新牌面"
    elseif pick.key == "snatch" then
        title = pick.step == 1 and "掉包 — 选你自己的一张手牌" or "掉包 — 选酒保的一张明牌"
    elseif pick.key == "chaos" then
        title = "错乱 — 从冠军牌组选一张"
    else
        title = (def and def.name) or "调酒"
    end

    local pw = math.min(920, w - 60)
    local ph = math.min(560, h - 60)
    local px = (w - pw) / 2
    local py = (h - ph) / 2
    love.graphics.setColor(th.panelFill[1], th.panelFill[2], th.panelFill[3], 0.98)
    love.graphics.rectangle("fill", px, py, pw, ph, 10)
    love.graphics.setColor(th.panelEdge)
    love.graphics.setLineWidth(2)
    love.graphics.rectangle("line", px + 1, py + 1, pw - 2, ph - 2, 10)
    love.graphics.setLineWidth(1)

    love.graphics.setColor(th.accent); love.graphics.setFont(UI.cjkFontMid)
    love.graphics.printf(title, px, py + 14, pw, "center")

    -- 候选条目：{ card = 牌, arg = 传给技能的选择值, toggle = 是否勾选式 }
    local entries = {}
    if pick.key == "peek3" then
        for i, c in ipairs(pick.cards or {}) do entries[#entries + 1] = { card = c, arg = i, toggle = true } end
    elseif pick.key == "chaos" or (pick.key == "swap" and pick.step == 2) then
        for i, c in ipairs(pick.options or {}) do entries[#entries + 1] = { card = c, arg = i } end
    elseif pick.key == "snatch" and pick.step == 2 then
        for i = 2, #state.dealer.hand do
            entries[#entries + 1] = { card = state.dealer.hand[i], arg = i }
        end
    else
        for i, c in ipairs(state.player.hand) do entries[#entries + 1] = { card = c, arg = i } end
    end

    -- 网格布局（列数固定，纵向可滚）：滚动状态挂在 pick.scroll 上
    local cols = 7
    local gx = px + 20
    local gw = pw - 40
    local cellW = gw / cols
    local slotW = math.floor(cellW * 0.74)
    local slotScale = slotW / UI.card.width
    local cellH = math.floor(UI.card.height * slotScale) + 26
    local gridY = py + 56
    local gridH = ph - 56 - 62
    local rowsVisible = math.max(1, math.floor(gridH / cellH))
    local rowsTotal = math.max(1, math.ceil(#entries / cols))
    UI._barAlcPickMaxScroll = math.max(0, rowsTotal - rowsVisible)
    local scroll = pick.scroll or 0
    if scroll < 0 then scroll = 0 end
    if scroll > UI._barAlcPickMaxScroll then scroll = UI._barAlcPickMaxScroll end
    pick.scroll = scroll

    local mx, my = love.mouse.getPosition()
    local empty = (#entries == 0)
    for idx = 1, math.min(#entries, rowsVisible * cols) do
        local slot = (idx - 1) + scroll * cols
        local e = entries[slot + 1]
        if not e then break end
        local col = (idx - 1) % cols
        local row = math.floor((idx - 1) / cols)
        local sx = math.floor(gx + col * cellW + (cellW - slotW) / 2)
        local sy = math.floor(gridY + row * cellH)
        local hover = mx >= sx and mx <= sx + slotW and my >= sy and my <= sy + UI.card.height * slotScale

        love.graphics.setColor(hover and th.btnHover or th.glassFill)
        love.graphics.rectangle("fill", sx - 3, sy - 3, slotW + 6, UI.card.height * slotScale + 6, 4)

        -- 用克隆牌绘制：绝不把真实手牌交给 drawCard（它会写 card.visual）
        UI.drawCard(GameState.barCloneCard(e.card), sx, sy, true, slotScale)

        if e.toggle and pick.marked and pick.marked[e.arg] then
            love.graphics.setColor(0.95, 0.55, 0.15)
            love.graphics.setLineWidth(3)
            love.graphics.rectangle("line", sx - 4, sy - 4, slotW + 8, UI.card.height * slotScale + 8, 4)
            love.graphics.setLineWidth(1)
            love.graphics.setFont(UI.cjkFontSmall)
            love.graphics.printf("沉底", sx - 4, sy + UI.card.height * slotScale + 6, slotW + 8, "center")
        end

        UI._barAlcPickBtns[#UI._barAlcPickBtns + 1] =
            { x = sx, y = sy, w = slotW, h = UI.card.height * slotScale, arg = e.arg, toggle = e.toggle }
    end
    if empty then
        love.graphics.setColor(th.textDim); love.graphics.setFont(UI.cjkFont)
        love.graphics.printf("没有可选的牌", px, gridY + 40, pw, "center")
    end

    -- 底部按钮：取消（恒有）/ 确认（仅勾选式的透牌需要）
    local btnW2, btnH2 = 140, 40
    local by = py + ph - btnH2 - 14
    local cancelX = px + pw / 2 - btnW2 - 10
    if pick.key == "peek3" then cancelX = px + pw / 2 - btnW2 * 1.5 - 10 end
    local chover = mx >= cancelX and mx <= cancelX + btnW2 and my >= by and my <= by + btnH2
    love.graphics.setColor(chover and th.btnHover or th.btnFill)
    love.graphics.rectangle("fill", cancelX, by, btnW2, btnH2, 6)
    love.graphics.setColor(1, 1, 1); love.graphics.setFont(UI.cjkFont)
    love.graphics.printf("取消(ESC)", cancelX, by + 10, btnW2, "center")
    UI._barAlcPickCancel = { x = cancelX, y = by, w = btnW2, h = btnH2 }

    if pick.key == "peek3" then
        local okX = px + pw / 2 + 10
        local ohover = mx >= okX and mx <= okX + btnW2 and my >= by and my <= by + btnH2
        love.graphics.setColor(ohover and th.btnHover or th.btnFill)
        love.graphics.rectangle("fill", okX, by, btnW2, btnH2, 6)
        love.graphics.setColor(1, 1, 1); love.graphics.setFont(UI.cjkFont)
        love.graphics.printf("确认", okX, by + 10, btnW2, "center")
        UI._barAlcPickConfirm = { x = okX, y = by, w = btnW2, h = btnH2 }
    end
    love.graphics.setColor(1, 1, 1)
end

-- ============================================================
-- 手牌
-- ============================================================
function UI.drawHands(state)
    love.graphics.setFont(UI.font); love.graphics.setColor(1, 1, 1)

    -- ==== 手牌区独立参数（与总览完全隔离） ====
    local HAND_SCALE = 0.625          -- 80×0.625=50, 120×0.625=75，保持 2:3
    local TINY_W = UI.card.width * HAND_SCALE     -- 50
    local TINY_H = UI.card.height * HAND_SCALE    -- 75
    local TINY_GAP = 12              -- 卡间距
    local ROW2_Y_OFFSET = TINY_H + TINY_GAP       -- 第二行 Y 偏移

    -- 基准 800×600 下坐标：庄家起始(50,120/160)，玩家(50,300/340)，点数在 x=400/500
    -- 按 H 等比缩放，保证不同窗口下布局结构一致
    local H = window_height
    local LEFT_PAD = 50
    local DEALER_LABEL_Y  = H * 0.15      -- 120/600 = 0.2 → 0.15 往上拉点
    local DEALER_ROW0_Y   = DEALER_LABEL_Y + 32
    local PLAYER_LABEL_Y  = H * 0.50
    local PLAYER_ROW0_Y   = PLAYER_LABEL_Y + 32
    local SIDE_INFO_X     = window_width - sidebar_width - 240   -- 点数文字靠右但在 sidebar 左边
    -- 玩家点数基准 Y（函数级作用域：卡包提示等后续元素都以它为锚点，不能只声明在 if 里）
    local PLAYER_PT_Y     = PLAYER_ROW0_Y + 30   -- 下移 +30px（避开庄家职阶 icon 视觉区）

    -- ========== 庄家区 / 玩家区（两行六张） ==========
    love.graphics.print("庄家手牌", LEFT_PAD, DEALER_LABEL_Y)
    love.graphics.print("你的手牌", LEFT_PAD, PLAYER_LABEL_Y)
    local DEALER_ROW1_Y = DEALER_ROW0_Y + ROW2_Y_OFFSET
    local PLAYER_ROW1_Y = PLAYER_ROW0_Y + ROW2_Y_OFFSET
    -- Assassin 庄家：玩家看不到任何明牌
    local dealerAssassin = state.gameMode == "hard" and state.dealerClass
                          and state.dealerClass.id == "assassin"
                          and state.state ~= "result"   -- 结算时翻开

    -- 标记表（uid → mark）：paintHands 闭包内逐张牌查玩家标记
    local markMap = GameState.markUidMap(state)

    -- 牌桌明牌标记热区（仅玩家阶段、非酒吧）：点击桌面上的牌 = 花标记费做记号
    UI._handMarkBtns = nil
    if state.state == "player" and state.gameMode ~= "bar" then UI._handMarkBtns = {} end

    -- 纯绘制函数：只画牌身与所有覆盖层（黑洞 / 67 / 牢笼 / 筹码 / peek 光晕 / 出千痕迹 / 遮罩）。
    -- 禁区：绝不启动 tween、绝不写 card._tweened、绝不登记热区 —— 宿醉模糊会把这份绘制重跑一次，
    --     任何一次性副作用都只能在下面的 tween 预扫里做一次。
    -- 黑洞牌公共覆盖层：黑框 + 67 再套一层紫框（庄家/玩家手牌共用，r 为 cardOverlayRect 结果）
    local function drawBlackholeFrame(r, card)
        love.graphics.setColor(0.05, 0.05, 0.05)
        love.graphics.setLineWidth(3)
        love.graphics.rectangle("line", r.x - 4, r.y - 4, r.w + 8, r.h + 8, 4)
        love.graphics.setLineWidth(1)
        if card.is_67 then
            love.graphics.setColor(0.75, 0.5, 1, 0.85)
            love.graphics.setLineWidth(2)
            love.graphics.rectangle("line", r.x - 8, r.y - 8, r.w + 16, r.h + 16, 4)
            love.graphics.setLineWidth(1)
        end
        love.graphics.setColor(1, 1, 1, 1)
    end

    local function paintHands(maskFace)
        for i, card in ipairs(state.dealer.hand) do
            local col = (i - 1) % 6
            local row = math.floor((i - 1) / 6)
            local lx = LEFT_PAD + col * (TINY_W + TINY_GAP)
            local ly = row == 0 and DEALER_ROW0_Y or DEALER_ROW1_Y

            local faceUp = card.faceUp and not dealerAssassin
            UI.drawCard(card, lx, ly, faceUp, HAND_SCALE)
            -- 覆盖层基准：卡身实际渲染左上角（card.visual.x/y 是缩放原点，不是左上角）
            local r = UI.cardOverlayRect(card, lx, ly, HAND_SCALE)
            if maskFace then drawFaceMaskRect(r) end
            -- 黑洞牌也显示边框（67 再套一层紫框）
            if faceUp and card.is_blackhole then drawBlackholeFrame(r, card) end
            -- ===== 牢笼牌：铁色边框 + 竖杠 =====
            if faceUp and card.is_cage then UI.drawCageMarks(r.x, r.y, r.w, r.h) end
            -- ===== 筹码牌：红黑相间边框 =====
            if faceUp and card.is_chip then UI.drawChipMarks(r.x, r.y, r.w, r.h) end
            -- ===== 出千痕迹（真痕迹 / 干扰项）：逐张牌画在该牌实际渲染坐标上 =====
            UI.drawCheatTell(card, r.x, r.y, r.w, r.h)
            -- ===== 玩家标记（墨水记号）：暗牌上也只有玩家看得懂 =====
            local mk = markMap[card.uid]
            if mk then UI.drawCardMark(card, r, mk) end
            -- ===== 点击标记热区（明牌可点做记号；悬停金框提示）=====
            if UI._handMarkBtns and faceUp then
                local hmx, hmy = love.mouse.getPosition()
                local hov = hmx >= r.x and hmx <= r.x + r.w and hmy >= r.y and hmy <= r.y + r.h
                if hov and not mk then
                    love.graphics.setColor(1, 0.72, 0.25, 0.8)
                    love.graphics.setLineWidth(2)
                    love.graphics.rectangle("line", r.x - 2, r.y - 2, r.w + 4, r.h + 4, 4)
                    love.graphics.setLineWidth(1)
                end
                UI._handMarkBtns[#UI._handMarkBtns + 1] = {
                    side = "dealer", index = i, x = r.x, y = r.y, w = r.w, h = r.h, enabled = not mk,
                }
            end
        end

        for i, card in ipairs(state.player.hand) do
            local col = (i - 1) % 6
            local row = math.floor((i - 1) / 6)
            local lx = LEFT_PAD + col * (TINY_W + TINY_GAP)
            local ly = row == 0 and PLAYER_ROW0_Y or PLAYER_ROW1_Y

            -- peek 标记 → 半透明 + 暗紫边框（提前预览态）
            if card._peek then
                love.graphics.push()
                love.graphics.setColor(1, 1, 1, 0.55)
                UI.drawCard(card, lx, ly, true, HAND_SCALE)
                love.graphics.pop()
            else
                UI.drawCard(card, lx, ly, true, HAND_SCALE)
            end
            local r = UI.cardOverlayRect(card, lx, ly, HAND_SCALE)
            if maskFace then drawFaceMaskRect(r) end
            -- 暗紫色光晕边框（与同一张卡上的其它覆盖层共用一个基准）
            if card._peek then
                love.graphics.setColor(0.6, 0.4, 0.9, 0.35)
                love.graphics.rectangle("fill", r.x - 5, r.y - 5, r.w + 10, r.h + 10, 5)
                love.graphics.setColor(0.75, 0.55, 1, 0.75)
                love.graphics.setLineWidth(2)
                love.graphics.rectangle("line", r.x - 5, r.y - 5, r.w + 10, r.h + 10, 5)
                love.graphics.setLineWidth(1); love.graphics.setColor(1, 1, 1, 1)
            end

            -- ===== 黑洞牌：黑色边框（67 再套一层紫框）=====
            if card.is_blackhole then drawBlackholeFrame(r, card) end

            -- ===== 牢笼牌：铁色边框 + 竖杠 =====
            if card.is_cage then UI.drawCageMarks(r.x, r.y, r.w, r.h) end

            -- ===== 筹码牌：红黑相间边框 =====
            if card.is_chip then UI.drawChipMarks(r.x, r.y, r.w, r.h) end

            -- ===== 玩家标记（墨水记号） =====
            local mk = markMap[card.uid]
            if mk then UI.drawCardMark(card, r, mk) end

            -- ===== 点击标记热区（玩家手牌）=====
            if UI._handMarkBtns then
                local hmx, hmy = love.mouse.getPosition()
                local hov = hmx >= r.x and hmx <= r.x + r.w and hmy >= r.y and hmy <= r.y + r.h
                if hov and not mk then
                    love.graphics.setColor(1, 0.72, 0.25, 0.8)
                    love.graphics.setLineWidth(2)
                    love.graphics.rectangle("line", r.x - 2, r.y - 2, r.w + 4, r.h + 4, 4)
                    love.graphics.setLineWidth(1)
                end
                UI._handMarkBtns[#UI._handMarkBtns + 1] = {
                    side = "player", index = i, x = r.x, y = r.y, w = r.w, h = r.h, enabled = not mk,
                }
            end
        end
    end

    -- 入场 tween：每张牌只启动一次（宿醉重绘走 paintHands，不会重复触发）
    for i, card in ipairs(state.dealer.hand) do
        local lx = LEFT_PAD + ((i - 1) % 6) * (TINY_W + TINY_GAP)
        local ly = math.floor((i - 1) / 6) == 0 and DEALER_ROW0_Y or DEALER_ROW1_Y
        if not card._tweened and state.state ~= "bet" then
            UI.tweenCardIn(card, lx, ly, 20, 10, i * 0.08)
            card._tweened = true
        end
    end
    for i, card in ipairs(state.player.hand) do
        local lx = LEFT_PAD + ((i - 1) % 6) * (TINY_W + TINY_GAP)
        local ly = math.floor((i - 1) / 6) == 0 and PLAYER_ROW0_Y or PLAYER_ROW1_Y
        if not card._tweened then
            UI.tweenCardIn(card, lx, ly, 20, 10, i * 0.08)
            card._tweened = true
        end
    end

    -- ===== 绘制；宿醉局（酒吧 + hangoverRound == round）再盖一层 1/8 降采样模糊 =====
    paintHands(false)
    if state.gameMode == "bar" and state.bar and state.bar.hangoverRound == state.bar.round then
        local cw = math.max(1, math.floor(window_width  / 8))
        local ch = math.max(1, math.floor(window_height / 8))
        local created, canvas = pcall(love.graphics.newCanvas, cw, ch)
        if created and canvas then
            local painted = pcall(function()
                love.graphics.setCanvas(canvas)
                love.graphics.clear(0, 0, 0, 0)
                love.graphics.push()
                love.graphics.scale(1 / 8, 1 / 8)
                paintHands(false)
                love.graphics.pop()
                love.graphics.setCanvas()
            end)
            if painted then
                canvas:setFilter("linear", "linear")
                love.graphics.setColor(1, 1, 1)
                love.graphics.draw(canvas, 0, 0, 0, 8, 8)
                canvas:setFilter("nearest", "nearest")
            else
                love.graphics.setCanvas()      -- 还原，避免污染后续绘制
                paintHands(true)               -- 兜底：同底色遮罩抹字
            end
        else
            paintHands(true)                   -- 兜底：canvas 创建失败 / 尺寸异常
        end
        love.graphics.setColor(1, 1, 1, 1)
    end

    local showDealer = state.state == "result" or state.state == "dealer" or state.state == "shop"
    -- Assassin 庄家：玩家看不到任何庄家信息（除了结算时）
    local dealerAssassinHide = state.gameMode == "hard" and state.dealerClass
                               and state.dealerClass.id == "assassin"
                               and state.state ~= "result"
    -- 酒吧模式：庄家点数改由 drawBarDealer 在荷官立绘之后绘制（本行的 x/y 正落在立绘矩形内，会被盖住）
    if state.gameMode ~= "bar" and showDealer and #state.dealer.hand > 0 and not dealerAssassinHide then
        local dt = Blackjack.calculateHand(state.dealer.hand)
        love.graphics.print("庄家点数: " .. dt, SIDE_INFO_X, DEALER_ROW0_Y + 10)
    end

    if #state.player.hand > 0 then
        local pt = Blackjack.calculateHand(state.player.hand)
        local raw = Blackjack.calculateHandRaw(state.player.hand)
        -- 检测软 A：原始值(A全=11)比实际值大，说明有 A 被降级了
        local hasSoftAce = raw > pt
        local playerPtY = PLAYER_PT_Y
        -- 宿醉局（口径与上方手牌模糊滤镜完全一致）：只看显示 —— 玩家那一行点数换成「无法辨认」，
        -- 不改 Blackjack.calculateHand 的返回值，也不碰庄家点数 / BLACKJACK! 标记 / 卡包提示 / 侧栏
        local hangoverBlind = state.gameMode == "bar" and state.bar
                              and state.bar.hangoverRound == state.bar.round
        if hangoverBlind then
            love.graphics.print("点数: 无法辨认", SIDE_INFO_X, playerPtY)
        elseif hasSoftAce then
            love.graphics.print("点数: " .. pt .. " (软 " .. raw .. ")", SIDE_INFO_X, playerPtY)
        else
            love.graphics.print("点数: " .. pt, SIDE_INFO_X, playerPtY)
        end
        if pt == 21 then
            love.graphics.setColor(1, 0.8, 0.2)
            love.graphics.print("BLACKJACK!", SIDE_INFO_X + 110, playerPtY)
        end
    end

    -- ===== 卡包状态显示 =====
    local hasCardPack = false
    for _, r in ipairs(state.relics or {}) do
        if r.id == "card_pack" and not r._expired and r.active ~= false then
            hasCardPack = true; break
        end
    end
    if hasCardPack then
        local packY = PLAYER_PT_Y + 24   -- 玩家点数下方（函数级锚点，手牌为空时也不会 nil 崩溃）
        love.graphics.setFont(UI.cjkFontSmall)
        if state._cardPackStored then
            local sc = state._cardPackStored
            love.graphics.setColor(0.9, 0.85, 0.3)
            love.graphics.print("卡包存牌: " .. tostring(sc.rank) .. sc.suit, SIDE_INFO_X, packY)
        else
            love.graphics.setColor(0.55, 0.55, 0.55)
            love.graphics.print("卡包存牌: 无", SIDE_INFO_X, packY)
        end
        love.graphics.setColor(1, 1, 1)
    end
end

-- ============================================================
-- 牌堆窥视预览 — 已废弃（peek 效果内嵌到 drawHands，手牌[1]._peek → 半透明预览态）
-- 保留空函数占位防止外部引用
-- ============================================================
-- drawPeekPreview 已废弃：peek 效果内嵌到 drawHands（手牌[1]._peek → 半透明）

function UI.drawDealer(state)
    -- 酒吧模式：换用 assets/bar 的荷官四态立绘 + 酒保文本框
    if state and state.gameMode == "bar" then return UI.drawBarDealer(state) end

    local d = UI.dealer
    if not d.currentImage then return end
    love.graphics.push(); love.graphics.translate(d.position.x, d.currY)
    love.graphics.setColor(1, 1, 1)
    love.graphics.draw(d.currentImage, 0, 0, 0, 0.5, 0.5)
    love.graphics.pop()

    -- ===== 困难模式：庄家职阶 icon（移到庄家手牌区右下方 — 彻底避开头像/点数文字） =====
    if state and state.gameMode == "hard" and state.dealerClass then
        local dc = state.dealerClass
        local iw, ih = 36, 36
        -- 独立计算位置（drawDealer 拿不到 drawHands 里的 local）
        local H = window_height
        local sidebar_w = sidebar_width or 120
        local dealerLabelY  = H * 0.15
        local dealerRow0Y   = dealerLabelY + 32
        local tinyH         = 75     -- 和 drawHands 里 TINY_H 一致 (UI.card.height * 0.625)
        local tinyGap       = 12
        local dealerRow1Y   = dealerRow0Y + tinyH + tinyGap
        local dealerCardBottom = dealerRow1Y + tinyH + 4
        local sideInfoX = window_width - sidebar_w - 240
        local ix = sideInfoX + 50   -- 点数文字右边 50px
        local iy = dealerCardBottom + 8

        local col = dc.color or { 0.7, 0.7, 0.7 }
        love.graphics.setColor(col[1]*0.2, col[2]*0.15, col[3]*0.15, 0.95)
        love.graphics.rectangle("fill", ix, iy, iw, ih, 6)
        love.graphics.setColor(1, 0.3, 0.35, 0.8)
        love.graphics.setLineWidth(2); love.graphics.rectangle("line", ix+1, iy+1, iw-2, ih-2, 6); love.graphics.setLineWidth(1)

        love.graphics.setColor(col[1], col[2], col[3], 0.95)
        love.graphics.setFont(UI.cjkFontMid)
        love.graphics.printf(dc.icon or dc.name, ix, iy + 6, iw, "center")

        love.graphics.setColor(1, 0.6, 0.65); love.graphics.setFont(UI.cjkFontSmall)
        love.graphics.printf(dc.name, ix - 20, iy + ih + 2, iw + 40, "center")

        -- 庄家侧专属描述（和玩家职阶 desc 完全不同方向）
        local dealerDescMap = {
            saber =     "结算时斩断你最小的一张牌。\n你的总点数会被悄悄扣掉（最低那张被移除后重算）。",
            lancer =    "庄家发牌时会发三张而不会爆。\n（庄家手牌上限提升到 3，自动停牌）",
            archer =    "下注时你就能看到庄家要发给自己的第一张牌。",
            rider =     "庄家可以在发完牌后直接跳过这一小局（最多发动 3 次），\n跳过的话你的下注会原封退回。",
            caster =    "庄家每连胜三次，可以从三个随机遗物中选一个\n替换自己的一个现有遗物（也可以选择不换）。\n庄家持有遗物越多，你每回合被点数压制越狠。",
            assassin =  "你无法看到庄家的任何一张牌（包括明牌）。\n只能在结算时才翻开对比。",
            berserker = "庄家直到 25 点都不会爆牌，最后只要庄家比你大则判胜。",
        }
        local hoverDesc = "庄家职阶\n" .. (dealerDescMap[dc.id] or dc.desc or "")
        if dc.id == "caster" and state.dealerStreak and state.dealerRelics then
            hoverDesc = hoverDesc .. string.format("\n\n当前连胜: %d\n持有遗物:", state.dealerStreak)
            for _, r in ipairs(state.dealerRelics) do
                hoverDesc = hoverDesc .. "\n  · " .. r.name
            end
            if #state.dealerRelics == 0 then
                hoverDesc = hoverDesc .. "（尚无 · 每3连胜获得）"
            end
        elseif dc.id == "rider" then
            hoverDesc = hoverDesc .. string.format("\n\n剩余跳过次数: %d / 3", state.dealerCharges or 0)
        end

        UI.addHoverTarget(
            { kind = "class", desc = hoverDesc, name = "庄家 · " .. dc.name, color = col },
            ix - 4, iy - 4, iw + 8, ih + 8
        )
    end
end

-- ============================================================
-- 酒吧模式：荷官（酒保）立绘 + 酒保文本框
--   立绘位置与缩放全部按窗口比例；四态映射：
--     state=="dealer" → focus；result: player→win / dealer→lost；其余→normal
--   文本框锚在立绘底边下方，宽约立绘宽度的 1.35 倍、高约 0.105H
-- ============================================================
function UI.drawBarDealer(state)
    local th = UI.barTheme

    local key = "normal"
    if state.state == "dealer" then
        key = "focus"
    elseif state.state == "result" then
        if state.result == "player" then key = "win"
        elseif state.result == "dealer" then key = "lost" end
    end
    local images = (UI.bar and UI.bar.dealer) or {}
    local img = images[key] or images.normal or images.focus
    if not img then return end

    local iw, ih = img:getDimensions()
    -- 立绘矩形：单一数据源。算法只在这里算一次，就地写进复用表（绝不每帧新建表），
    -- 供 (a) 本函数绘制立绘 (b) 悬停统计框的定位与热区 (c) 庄家点数避让 三处共用。
    local rect = UI._barDealerRect
    if not rect then rect = {}; UI._barDealerRect = rect end
    local dh = window_height * 0.40
    local dw = dh * (iw / ih)
    local maxW = (window_width - sidebar_width) * 0.34
    if dw > maxW then dw = maxW; dh = dw * (ih / iw) end
    local dx = window_width - sidebar_width - dw - window_width * 0.02
    if dx < window_width * 0.02 then dx = window_width * 0.02 end
    local dy = window_height * 0.06
    rect.x, rect.y, rect.w, rect.h = dx, dy, dw, dh

    love.graphics.setColor(1, 1, 1)
    love.graphics.draw(img, dx, dy, 0, dw / iw, dh / ih)

    -- 文本框（适当加大：宽 1.35 倍立绘、高 0.105H，最长科普台词也能 3 行放下；
    -- 宽度再设桌面区上限，防止极端窄窗时越出侧栏）
    local tbw = dw * 1.35
    tbw = math.min(tbw, window_width - sidebar_width - 8)
    local tbh = math.max(48, math.floor(window_height * 0.105))
    local tbx = dx + dw / 2 - tbw / 2
    if tbx < 4 then tbx = 4 end
    if tbx + tbw > window_width - sidebar_width - 4 then tbx = window_width - sidebar_width - tbw - 4 end
    local tby = dy + dh + 6
    if tby + tbh > window_height - 8 then tby = window_height - 8 - tbh end
    -- 文本框矩形（夹取后的最终值）：悬停统计框以它为锚点向下排，避免两处各算一遍导致错位
    local brect = UI._barBoilerRect
    if not brect then brect = {}; UI._barBoilerRect = brect end
    brect.x, brect.y, brect.w, brect.h = tbx, tby, tbw, tbh

    love.graphics.setColor(th.panelFill[1], th.panelFill[2], th.panelFill[3], 0.96)
    love.graphics.rectangle("fill", tbx, tby, tbw, tbh, 5)
    love.graphics.setColor(th.panelEdge)
    love.graphics.setLineWidth(2)
    love.graphics.rectangle("line", tbx, tby, tbw, tbh, 5)
    love.graphics.setLineWidth(1)

    local bar = state.bar or {}
    local isGift = bar.giftText ~= nil and love.timer.getTime() < (bar.giftTextUntil or 0)
    local txt = isGift and bar.giftText or (bar.boilerLine or "欢迎光临，慢慢喝。")
    love.graphics.setColor(isGift and th.accent or th.text)
    -- 换行优化：行距随框高自适应（15~18px，替代原 max(tbh/3,14) 的忽大忽小）；
    -- 先按「内宽 × 行数容量」裁到放得下（超出以 ... 收尾，单条文本不过载），
    -- 再整块垂直居中 —— 任何台词长度都不出框，也不与统计框 / 手牌 / 按钮重叠。
    local innerW = tbw - 16
    local lineH = math.max(15, math.min(18, math.floor((tbh - 12) / 3)))
    local shown = UI.fitTextEllipsis(txt, UI.cjkFontSmall, innerW, tbh - 12, lineH)
    local _, count = UI.wrapAndMeasure(shown, UI.cjkFontSmall, innerW)
    local ty = tby + math.max(6, math.floor((tbh - count * lineH) / 2))
    UI.drawWrappedText(shown, UI.cjkFontSmall, tbx + 8, ty, innerW, lineH, nil, "center")
    love.graphics.setColor(1, 1, 1)

    -- ===== 庄家点数（问题 1）=====
    -- 本行必须在立绘与文本框「之后」绘制，且绘制矩形与立绘矩形 (rect) 不相交：
    -- 纵向取「庄家手牌」标签行（0.15H，手牌首行在 0.15H+32，不会压到牌）；
    -- 横向右对齐到立绘左边缘再留 1% 窗口宽，绝不进立绘、绝不进 sidebar。
    if (state.state == "result" or state.state == "dealer" or state.state == "shop")
       and #state.dealer.hand > 0 then
        local dt = Blackjack.calculateHand(state.dealer.hand)
        local padX = window_width * 0.05
        local rightLimit = dx - window_width * 0.01
        love.graphics.setFont(UI.cjkFontSmall)
        love.graphics.setColor(th.text)
        love.graphics.printf("庄家点数: " .. dt, padX, window_height * 0.15,
                             math.max(60, rightLimit - padX), "right")
        love.graphics.setColor(1, 1, 1)
    end
end

-- ============================================================
-- 酒吧模式：悬停荷官立绘 → 立绘旁的统计信息框（问题 7）
--   显示「赠酒概率」与「胜 X 负 Y」；这两项原先常驻在右下角底部区（与立绘重叠、看不清）。
--   显示条件：酒吧模式 + 玩家可操作回合（state == "player"）+ 无任何模态/浮层。
--   位置：叠在立绘下半部（信息面板式），横向以文本框为轴居中、右侧夹取不进 sidebar；
--         立绘高度 0.4H 恒大于框高 0.11H，四个内置分辨率下都不与立绘外的任何
--         文字 / 文本框 / 侧栏 / 手牌区 / 按钮行重叠，窗口过窄时向左夹取，绝不溢出窗口。
--   禁区：不新造 state 字段（概率 / 胜负只看既有 bar.prob / bar.winCount / bar.loseCount）；
--         不每帧新建表（两个矩形表都是复用 + 就地更新）。
-- ============================================================
function UI.drawBarDealerStatBox(state)
    if not (state and state.gameMode == "bar" and state.bar) then return end
    if state.state ~= "player" then return end
    if state._barBriefOpen or state._barGiftOpen or state._barDrinkOpen
       or state._barAlcOpen or state.barEnding then return end

    local rect   = UI._barDealerRect
    local brect  = UI._barBoilerRect
    if not (rect and brect) then return end

    local mx, my = love.mouse.getPosition()
    local hover = mx >= rect.x and mx <= rect.x + rect.w
                  and my >= rect.y and my <= rect.y + rect.h
    if not hover then return end

    local H = window_height
    local bw = rect.w * 1.2
    local bh = math.max(48, math.floor(H * 0.11))
    local bx = brect.x + brect.w / 2 - bw / 2
    if bx + bw > window_width - sidebar_width - 4 then
        bx = window_width - sidebar_width - 4 - bw
    end
    if bx < 4 then bx = 4 end
    -- 悬停框叠在立绘下半部（信息面板式）：原先排在文本框下方，文本框加大后会被
    -- 推到更低处，在 800x600 等小窗盖住「点数 / 卡包存牌」文字。立绘高 0.4H 恒
    -- 大于框高 0.11H 放得下，且立绘下半区没有任何文字 / 按钮，永不重叠。
    local by = rect.y + rect.h - bh - math.max(6, math.floor(H * 0.01))
    if by < 4 then by = 4 end

    local th = UI.barTheme
    local bar = state.bar
    love.graphics.setColor(th.panelFill[1], th.panelFill[2], th.panelFill[3], 0.97)
    love.graphics.rectangle("fill", bx, by, bw, bh, 6)
    love.graphics.setColor(th.panelEdge)
    love.graphics.setLineWidth(2)
    love.graphics.rectangle("line", bx, by, bw, bh, 6)
    love.graphics.setLineWidth(1)

    local prob = bar.prob or 0
    local lineH = math.max(16, math.floor(bh / 3))
    love.graphics.setFont(UI.cjkFontSmall)
    love.graphics.setColor(th.textDim)
    love.graphics.printf("赠酒概率", bx + 8, by + 6, bw - 16, "left")
    love.graphics.setColor(th.accent)
    love.graphics.printf(math.floor(prob * 100 + 0.5) .. "%", bx + 8, by + 6, bw - 16, "right")
    love.graphics.setColor(th.text)
    love.graphics.printf("胜 " .. (bar.winCount or 0) .. "  负 " .. (bar.loseCount or 0),
                         bx + 8, by + 6 + lineH, bw - 16, "left")
    love.graphics.setColor(1, 1, 1)
end

-- ============================================================
-- 下注滑条相关
-- ============================================================
function UI.isInSlider(x, y)
    local s = UI.slider
    return x >= s.x - 10 and x <= s.x + s.w + 10 and y >= s.y - 10 and y <= s.y + s.h + 20
end

function UI.isInSliderConfirm(x, y)
    local s = UI.slider
    local cx = s.x + s.w + 20
    local cy = s.y - 4
    return x >= cx and x <= cx + s.confirmBtn.w and y >= cy and y <= cy + s.confirmBtn.h
end

function UI.updateSliderBet(mouseX, maxChips)
    local s = UI.slider
    local relX = mouseX - s.x
    local pct = math.max(0, math.min(1, relX / s.w))
    local amount = math.floor(pct * (maxChips or 0))
    amount = math.floor(amount)   -- 整数步进（不设最小下注：1 筹码也能下）
    return amount
end

function UI.drawBetSlider(state, betAmount)
    local s = UI.slider
    local chips = state.player.chips

    -- 赊账上限与 placeBet / 滑条拖拽同一口径（Relics.getCreditInfo）
    local hasCredit, creditLimit = Relics.getCreditInfo(state)
    local betCap = chips + creditLimit

    -- 滑条背景
    love.graphics.setColor(0.15, 0.15, 0.15)
    love.graphics.rectangle("fill", s.x, s.y, s.w, s.h, 6)
    love.graphics.setColor(0.4, 0.4, 0.4)
    love.graphics.rectangle("line", s.x, s.y, s.w, s.h, 6)

    -- 填充（注意：betAmount 可能超过 chips！）
    local pct = betCap > 0 and (betAmount or 0) / betCap or 0
    pct = math.max(0, math.min(1, pct))

    -- 颜色: 超过 chips 的部分用红色表示赊账
    local ownPct = chips > 0 and chips / betCap or 1
    if betAmount and betAmount > chips then
        -- 正常部分黄色
        love.graphics.setColor(0.9, 0.7, 0.2)
        love.graphics.rectangle("fill", s.x, s.y, s.w * ownPct, s.h, 6)
        -- 赊账部分红色
        love.graphics.setColor(0.9, 0.2, 0.2)
        love.graphics.rectangle("fill", s.x + s.w * ownPct, s.y, s.w * (pct - ownPct), s.h, 6)
    else
        love.graphics.setColor(0.9, 0.7, 0.2)
        love.graphics.rectangle("fill", s.x, s.y, s.w * pct, s.h, 6)
    end

    -- 滑块
    local mx = s.x + s.w * pct
    love.graphics.setColor(1, 1, 1)
    love.graphics.circle("fill", mx, s.y + s.h / 2, 14)
    love.graphics.setColor(0.6, 0.4, 0.1)
    love.graphics.circle("line", mx, s.y + s.h / 2, 14)

    -- 金额显示（赊账时变色）
    love.graphics.setFont(UI.cjkFont)
    if betAmount and betAmount > chips then
        love.graphics.setColor(1, 0.3, 0.3)  -- 红色警告
        love.graphics.printf("$" .. (betAmount or 0) .. " 赊!", s.x - 100, s.y - 5, 90, "right")
    else
        love.graphics.setColor(1, 1, 0.5)
        love.graphics.printf("$" .. (betAmount or 0), s.x - 80, s.y - 5, 70, "right")
    end

    -- 刻度
    love.graphics.setFont(UI.cjkFontSmall)
    love.graphics.setColor(0.7, 0.7, 0.7)
    love.graphics.printf("$0", s.x - 2, s.y + s.h + 4, 40, "left")
    if hasCredit then
        -- 显示自己的筹码 + 赊账上限
        love.graphics.setColor(0.9, 0.7, 0.2)
        love.graphics.printf("$" .. chips, s.x + s.w * ownPct - 40, s.y + s.h + 4, 80, "center")
        love.graphics.setColor(0.9, 0.2, 0.2)
        love.graphics.printf("$" .. betCap, s.x + s.w - 40, s.y + s.h + 4, 80, "right")
    else
        love.graphics.printf("$" .. chips, s.x + s.w - 40, s.y + s.h + 4, 80, "right")
    end

    -- 快捷金额标记
    local marks = {50, 100, 200, 500, 1000, 2000}
    love.graphics.setColor(0.5, 0.5, 0.5)
    for _, m in ipairs(marks) do
        if betCap >= m then
            local px = s.x + (m / betCap) * s.w
            love.graphics.line(px, s.y + 2, px, s.y + s.h - 2)
        end
    end

    -- 赊账警告文字
    if hasCredit then
        love.graphics.setColor(1, 0.4, 0.4)
        love.graphics.setFont(UI.cjkFontSmall)
        love.graphics.printf("[!] 赊账模式：输了变负 -> 立即游戏结束", s.x, s.y + s.h + 18, s.w, "center")
    end

    -- 确认按钮
    local cx = s.x + s.w + 20; local cy = s.y - 4
    local canBet = (betAmount or 0) >= 1 and betCap >= (betAmount or 0)
    love.graphics.setColor(canBet and {0.3, 0.7, 0.3} or {0.4, 0.4, 0.4})
    love.graphics.rectangle("fill", cx, cy, s.confirmBtn.w, s.confirmBtn.h, 6)
    love.graphics.setColor(1, 1, 1)
    love.graphics.setFont(UI.cjkFont)
    love.graphics.printf("下注", cx, cy + 8, s.confirmBtn.w, "center")
end

-- ============================================================
-- 控制按钮 + 状态 + 下注滑条
-- ============================================================
function UI.drawControls(state)
    love.graphics.setFont(UI.font); love.graphics.setColor(1, 1, 1)
    -- 酒吧模式没有筹码（无下注/经济），顶栏不显示筹码
    local isBar = state.gameMode == "bar"
    if not isBar then
        love.graphics.print("筹码: $" .. state.player.chips, 30, 30)
    end

    -- 右上角设置入口（可点击）—— 移到这里避开所有文字
    local rightW = 80; local rightH = 22
    local rightX = window_width - sidebar_width - rightW - 15
    local rightY = 18
    love.graphics.setColor(0.3, 0.3, 0.35)
    love.graphics.rectangle("fill", rightX, rightY, rightW, rightH, 3)
    love.graphics.setColor(0.85, 0.85, 0.85); love.graphics.setFont(UI.cjkFontSmall)
    love.graphics.printf("[ESC] 设置", rightX, rightY + 3, rightW, "center")
    -- 暴露入口按钮
    UI._settingsEntryBtn = { x = rightX, y = rightY, w = rightW, h = rightH }
    if state.settingsOpen then UI._settingsEntryBtn = nil end

    -- 酒吧模式：右上角「说明」入口（重看开局两页说明）——与 [ESC] 设置同排、紧靠它左边。
    -- 只占桌面有效宽度（x + w <= window_width - sidebar_width），不与设置入口 / 牌堆入口 / 要牌键重叠。
    -- 热区单一数据源：绘制时写这张表，main.lua 点击时读同一张表；仅 state == "player" 可点，其余灰显。
    if isBar then
        local helpW = 80; local helpH = 22
        local helpX = rightX - 8 - helpW
        local helpY = rightY
        local canHelp = (state.state == "player")
        love.graphics.setColor(canHelp and {0.34, 0.29, 0.20} or {0.22, 0.22, 0.24})
        love.graphics.rectangle("fill", helpX, helpY, helpW, helpH, 3)
        love.graphics.setColor(canHelp and {0.95, 0.85, 0.55} or {0.55, 0.55, 0.58})
        love.graphics.setFont(UI.cjkFontSmall)
        love.graphics.printf("说明", helpX, helpY + 3, helpW, "center")
        UI._barHelpBtn = { x = helpX, y = helpY, w = helpW, h = helpH, enabled = canHelp }
    else
        UI._barHelpBtn = nil
    end

    -- 中间上方蓝色牌堆入口（庄家区上方居中，绿背景上，不挡任何文字）
    local W = window_width - sidebar_width  -- 桌面有效宽度
    local dEntryW = 48; local dEntryH = 66
    local dEntryX = math.floor(W / 2) - math.floor(dEntryW / 2)
    local dEntryY = 38
    -- 牌堆形状：两张错开的深蓝卡片（复用旧深蓝牌堆图形，等比）
    love.graphics.setColor(0.22, 0.22, 0.65)
    love.graphics.rectangle("fill", dEntryX + 3, dEntryY + 3, dEntryW, dEntryH, 4)
    love.graphics.setColor(0.3, 0.3, 0.8)
    love.graphics.rectangle("fill", dEntryX, dEntryY, dEntryW, dEntryH, 4)
    love.graphics.setColor(1, 1, 1); love.graphics.setFont(UI.cjkFontSmall)
    love.graphics.printf("牌堆", dEntryX, dEntryY + 24, dEntryW, "center")
    -- 暴露入口（只保留图形，删除所有文字标签）
    UI._deckEntryBtn = { x = dEntryX - 4, y = dEntryY - 4, w = dEntryW + 8, h = dEntryH + 8 }
    if state.deckOverviewOpen then UI._deckEntryBtn = nil end

    -- 牌靴情报入口：紧贴牌堆入口正下方（纵向堆叠，零横向重叠风险）
    -- 热区单一数据源：绘制写 UI._shoeEntryBtn，main.lua 点击读同一张表
    do
        local sW = dEntryW; local sH = 22
        local sX = dEntryX; local sY = dEntryY + dEntryH + 6
        love.graphics.setColor(state._shoeInfoOpen and {0.10, 0.34, 0.32} or {0.14, 0.42, 0.40})
        love.graphics.rectangle("fill", sX, sY, sW, sH, 3)
        love.graphics.setColor(0.75, 0.98, 0.92)
        love.graphics.setFont(UI.cjkFontSmall)
        love.graphics.printf("情报", sX, sY + 3, sW, "center")
        UI._shoeEntryBtn = { x = sX, y = sY, w = sW, h = sH }
        if state._shoeInfoOpen then UI._shoeEntryBtn = nil end
    end

    local statusMap = {
        bet = "下注 — 拖滑条或按 1-5 快捷下注",
        player = "你的回合 — H:要牌  S:停牌",
        dealer = "庄家行动中...",
        shop = "商店",
        relic_select = "选择初始遗物",
        result = "结算中...",
    }
    love.graphics.print(statusMap[state.state] or state.state, 30, 60)

    -- 下注状态 — 画滑条
    if state.state == "bet" then
        -- 用全局的 sliderBetAmount（从 main.lua 传）或者 state.player.bet
        -- 简化：画一个 0~chips 的滑条，按钮支持快捷
        local betAmount = state._sliderBet or 100  -- 默认 100
        love.graphics.setColor(0.6, 0.6, 0.6)
        love.graphics.printf("下注金额 (拖滑条):", 30, UI.slider.y - 22, 200, "left")
        UI.drawBetSlider(state, betAmount)

        -- 快捷下注按钮（可见 + 热区同一份坐标，位置在点数区下方，不与滑条重叠）
        for _, btn in ipairs(UI.buttons.bet or {}) do
            local mx, my = love.mouse.getPosition()
            local hover = mx >= btn.x and mx <= btn.x + btn.w and my >= btn.y and my <= btn.y + btn.h
            love.graphics.setColor(hover and {0.85, 0.7, 0.2} or {0.55, 0.45, 0.15})
            love.graphics.rectangle("fill", btn.x, btn.y, btn.w, btn.h, 5)
            love.graphics.setColor(1, 1, 1)
            love.graphics.setFont(UI.cjkFontSmall)
            love.graphics.printf(btn.label, btn.x, btn.y + btn.h / 2 - 8, btn.w, "center")
        end

        -- 爆注开关（阶段3）：押庄家爆牌 —— 注码取主注一半，赔率发牌时锁定
        -- 坐标锚定快捷按钮行末尾（与 refreshLayout 解耦，任何分辨率不越界）
        do
            local last = (UI.buttons.bet or {})[3]
            if last then
                local bw, bh = last.w, last.h
                local bx = last.x + last.w + math.floor(last.w * 0.14)
                local by = last.y
                local on = state._bustBetOn == true
                love.graphics.setColor(on and {0.72, 0.22, 0.12} or {0.28, 0.18, 0.18})
                love.graphics.rectangle("fill", bx, by, bw, bh, 5)
                love.graphics.setColor(on and {1, 0.9, 0.75} or {0.75, 0.62, 0.62})
                love.graphics.setFont(UI.cjkFontSmall)
                love.graphics.printf(on and "爆注: 开 (B)" or "爆注: 关 (B)", bx, by + bh / 2 - 8, bw, "center")
                UI._bustBetBtn = { x = bx, y = by, w = bw, h = bh }
            end
        end
    end

    -- 玩家/庄家按钮
    if state.state == "player" then
        for _, btn in ipairs(UI.buttons.game) do
            local mx, my = love.mouse.getPosition()
            local hover = mx >= btn.x and mx <= btn.x + btn.w and my >= btn.y and my <= btn.y + btn.h
            -- 加倍只在 canDoubleDown 时可用，否则灰显
            local enabled = true
            if btn.id == "double" then enabled = GameState.canDoubleDown(state) end
            love.graphics.setColor((not enabled) and {0.22, 0.28, 0.22}
                or (hover and {0.4, 0.7, 0.4} or {0.3, 0.6, 0.3}))
            love.graphics.rectangle("fill", btn.x, btn.y, btn.w, btn.h, 5)
            love.graphics.setColor((not enabled) and {0.6, 0.65, 0.6}
                or (hover and {1, 1, 0} or {1, 1, 1}))
            love.graphics.setFont(UI.font)
            love.graphics.printf(btn.label, btn.x, btn.y + btn.h / 2 - 12, btn.w, "center")
        end

        -- 调酒键 + 主动技能展开列表（酒吧模式专属，左侧空间不与其他按钮重叠）
        if isBar then
            UI.drawBarAlcButton(state)
            UI.drawBarAlcMenu(state)
        end

        -- 反出千按钮（红黑色，警告感）— 坐标来自 UI.buttons.accuse（和 main.lua 点击热区同源）
        -- 酒吧模式没有庄家出千与指认，不绘制该按钮
        if not isBar then
        local acc = UI.buttons.accuse or { x = 600, y = 530, w = 120, h = 45 }
        local accuseX, accuseY, accuseW, accuseH = acc.x, acc.y, acc.w, acc.h
        local canAccuse = not (state.cheatState and state.cheatState.wasAccused)
        local mx, my = love.mouse.getPosition()
        local hover = mx >= accuseX and mx <= accuseX + accuseW and my >= accuseY and my <= accuseY + accuseH
        love.graphics.setColor(canAccuse and (hover and {0.7, 0.15, 0.15} or {0.5, 0.1, 0.1}) or {0.3, 0.3, 0.3})
        love.graphics.rectangle("fill", accuseX, accuseY, accuseW, accuseH, 5)
        love.graphics.setColor(canAccuse and {1, 0.8, 0.8} or {0.6, 0.6, 0.6})
        love.graphics.setFont(UI.cjkFont)
        love.graphics.printf("指认出千[C]", accuseX, accuseY + accuseH / 2 - 8, accuseW, "center")

        -- 提示：按钮高亮/闪烁与「是否真作弊」彻底解耦 —— 只按时间做呼吸，
        -- 不作弊的局面同样闪烁、同样可点；玩家无法靠按钮外观反推答案
        do
            local t = love.timer.getTime()
            local a = 0.18 + 0.18 * math.sin(t * 2)
            love.graphics.setColor(1, 0.5, 0.5, a)
            love.graphics.rectangle("line", accuseX, accuseY, accuseW, accuseH, 5)
        end
        end

        -- 投降按钮（遗物"后期投降"激活 + 点数小于 18 时才出现）
        -- 坐标同源：UI.buttons.surrender（main.lua 点击热区读同一份）
        local sur = UI.buttons.surrender
        if sur and GameState.canSurrender(state) then
            local smx, smy = love.mouse.getPosition()
            local shover = smx >= sur.x and smx <= sur.x + sur.w and smy >= sur.y and smy <= sur.y + sur.h
            love.graphics.setColor(shover and {0.6, 0.45, 0.15} or {0.45, 0.32, 0.1})
            love.graphics.rectangle("fill", sur.x, sur.y, sur.w, sur.h, 5)
            love.graphics.setColor(1, 0.95, 0.8)
            love.graphics.setFont(UI.cjkFontSmall)
            love.graphics.printf("投降(U)", sur.x, sur.y + sur.h / 2 - 8, sur.w, "center")
        end
    end
    -- 右下角小提示已删除（牌堆只保留中间的蓝色图形入口）
end

-- ============================================================
-- 开局遗物选择界面
-- ============================================================
function UI.drawStarterSelect(state)
    local w, h = love.graphics.getWidth(), love.graphics.getHeight()

    love.graphics.setColor(0.05, 0.2, 0.1, 1)
    love.graphics.rectangle("fill", 0, 0, w, h)

    love.graphics.setFont(UI.splash.titleFont); love.graphics.setColor(1, 0.8, 0.2)
    love.graphics.printf("选择你的初始遗物", 0, 40, w, "center")

    love.graphics.setFont(UI.cjkFont); love.graphics.setColor(0.85, 0.85, 0.85)
    love.graphics.printf("点击一张选中，或按 1/2/3 键", 0, 85, w, "center")

    local card_w, card_h, spacing = 160, 200, 50
    local total_w = card_w * 3 + spacing * 2
    local start_x = (w - total_w) / 2
    local card_y = h / 2 - card_h / 2 + 30

    for i, relic in ipairs(state.pendingRelics or {}) do
        local rx = start_x + (i - 1) * (card_w + spacing)
        local r, g, b = unpack(Relics.getRarityColor(relic.rarity))
        love.graphics.setColor(r * 0.2, g * 0.2, b * 0.2, 0.95)
        love.graphics.rectangle("fill", rx, card_y, card_w, card_h, 8)
        love.graphics.setColor(r, g, b)
        love.graphics.rectangle("line", rx, card_y, card_w, card_h, 8)

        UI.drawRelicIcon(relic, rx + (card_w - 90) / 2, card_y + 10, 90, 95)

        love.graphics.setColor(1, 1, 1); love.graphics.setFont(UI.cjkFont)
        love.graphics.printf(relic.name, rx + 6, card_y + 105, card_w - 12, "center")

        love.graphics.setColor(r, g, b); love.graphics.setFont(UI.cjkFontSmall)
        love.graphics.printf("[" .. relic.rarity .. "]", rx + 6, card_y + 130, card_w - 12, "center")

        -- 描述：可用高度只到「按 N」提示的上沿（硬边界），放不下就截断并以 ASCII "..." 结尾
        love.graphics.setColor(0.85, 0.85, 0.85)
        local descY = card_y + card_h - 55
        local descShown = UI.fitTextEllipsis(relic.desc, UI.cjkFontSmall, card_w - 20,
                                            (card_y + card_h - 22) - descY)
        love.graphics.printf(descShown, rx + 10, descY, card_w - 20, "center")

        love.graphics.setColor(1, 1, 0.5); love.graphics.setFont(UI.font)
        love.graphics.printf("按 " .. i, rx + 6, card_y + card_h - 22, card_w - 12, "center")

        UI.addHoverTarget(relic, rx, card_y, card_w, card_h)
    end
end

-- ============================================================
-- 统一文本工具（解决 printf 自动换行后高度算不对导致的重叠 + 长名字溢出）
-- ============================================================

-- 按 font + maxWidth 把一段文本（可含 \n）拆成实际渲染行
-- 返回: { lines, totalLineCount }  — totalLineCount 是 Love2D printf 真正会画的行数
function UI.wrapAndMeasure(text, font, maxWidth)
    if not text then return {}, 0 end
    font = font or love.graphics.getFont()
    local rawLines = {}
    for line in tostring(text):gmatch("[^\n]+") do
        table.insert(rawLines, line)
    end
    if #rawLines == 0 then rawLines = { "" } end
    local allLines = {}
    for _, raw in ipairs(rawLines) do
        -- getWrap 可能返回 (lines, maxLineWidth) 或 (maxLineWidth, lines)
        local v1, v2 = font:getWrap(raw, maxWidth)
        local wrapped = (type(v1) == "table") and v1 or v2
        if wrapped then
            for _, wl in ipairs(wrapped) do
                table.insert(allLines, wl)
            end
        end
    end
    return allLines, #allLines
end

-- 渲染一段文本（可含 \n + 自动换行），按给定 font/maxWidth/lineH 排
-- 返回实际渲染行数
function UI.drawWrappedText(text, font, x, y, maxWidth, lineH, color, align)
    if not text then return 0 end
    font = font or love.graphics.getFont()
    align = align or "left"
    love.graphics.setFont(font)
    if color then love.graphics.setColor(unpack(color)) end
    local wrapped, count = UI.wrapAndMeasure(text, font, maxWidth)
    for i, wl in ipairs(wrapped) do
        love.graphics.printf(wl, x, y + (i - 1) * lineH, maxWidth, align)
    end
    return count
end

-- 按「可用宽 × 可用高」裁一段文本：放得下就原样返回，放不下就保留前几行、并在
-- 最后保留的那一行行尾补 ASCII 三个点 "..."（多行 clamp 语义）。
-- lineStep: 该界面绘制多行时用的实际行距（缺省 font:getHeight()）；宽/高一律由字体度量与既有布局变量推导
-- 返回: 裁好的文本（含 \n，可直接交给 printf）、保留行数与保留行数组（供按行距逐行绘制的界面复用）
-- 依赖 UI.wrapAndMeasure（与 printf 同语义），不自己另写一套换行逻辑
function UI.fitTextEllipsis(text, font, maxWidth, maxHeight, lineStep)
    if text == nil then return "", 0, {} end
    text = tostring(text)
    font = font or love.graphics.getFont()
    local step = lineStep or font:getHeight()
    if not step or step <= 0 then step = 1 end
    local maxLines = math.max(1, math.floor((maxHeight or step) / step))
    local lines, count = UI.wrapAndMeasure(text, font, maxWidth)
    if count <= maxLines then
        return text, count, lines   -- 不溢出：原样返回，绝不追加 "..."（tooltip 仍是全文）
    end
    local kept = {}
    for i = 1, maxLines do kept[i] = lines[i] or "" end
    -- 最后一行要给 "..." 自身留出宽度，并按 UTF-8 字符边界退让（不切断多字节字符）
    local ell = "..."
    local limit = maxWidth - font:getWidth(ell)
    local last = kept[maxLines]
    local trimmed = ""
    local i, n = 1, #last
    while i <= n do
        local b = last:byte(i)
        local len = 1
        if b >= 0xF0 then len = 4
        elseif b >= 0xE0 then len = 3
        elseif b >= 0xC0 then len = 2 end
        local ch = last:sub(i, i + len - 1)
        if font:getWidth(trimmed .. ch) > limit then break end
        trimmed = trimmed .. ch
        i = i + len
    end
    kept[maxLines] = trimmed .. ell
    return table.concat(kept, "\n"), maxLines, kept
end

-- ============================================================
-- 商店（阶段动态价格）
-- ============================================================
function UI.drawShop(state)
    local w, h = love.graphics.getWidth(), love.graphics.getHeight()

    love.graphics.setColor(0, 0, 0, 0.88)
    love.graphics.rectangle("fill", 0, 0, w, h)

    if state._pureDeckShop then
        love.graphics.setFont(UI.splash.titleFont); love.graphics.setColor(0.5, 0.9, 1)
        love.graphics.printf("纯牌组商店 · 稀有事件 (阶段 " .. state.stage .. ")", 0, 30, w, "center")
    else
        love.graphics.setFont(UI.splash.titleFont); love.graphics.setColor(1, 0.8, 0.2)
        love.graphics.printf("商店  (阶段 " .. state.stage .. " x" .. (1 + (state.stage - 1) * 0.5) .. "价格)", 0, 30, w, "center")
    end

    love.graphics.setFont(UI.cjkFontMid); love.graphics.setColor(1, 1, 1)
    love.graphics.printf("当前筹码: $" .. state.player.chips, 0, 72, w, "center")

    local topY = 110

    -- ========== 混排：遗物 5 张 + 牌组 offer 2 张 ==========
    -- 尺寸缩小适配最小窗口（1280 宽 + sidebar 约 154px → 剩 1126，7×100+6×12=772 放得下）
    local card_w, card_h = 100, 135
    local spacing = 12

    local combined = {}   -- { kind="relic", relic=... } or { kind="deck", offer=... }
    for _, r in ipairs(state.shopOfferings or {}) do table.insert(combined, { kind = "relic", relic = r }) end
    for _, o in ipairs(state.shopDeckOfferings or {}) do table.insert(combined, { kind = "deck",  offer = o }) end

    local count = #combined
    local total_w = card_w * count + spacing * math.max(0, count - 1)
    local start_x = math.max(20, (w - total_w) / 2)
    local card_y = topY

    UI._shopCards = {}   -- 存储卡片 hit target {kind, index, x, y, w, h}

    for i, entry in ipairs(combined) do
        local cx = start_x + (i - 1) * (card_w + spacing)
        if entry.kind == "relic" then
            local relic = entry.relic
            local basePrice = Relics.getStagePrice(relic, state.stage)
            local stagePrice = GameState.shopItemPrice(state, basePrice, i)   -- 打折位：混排货架位置 i
            relic._shopPrice = stagePrice
            local discounted = stagePrice < basePrice
            local canBuy = not relic.sold and state.player.chips >= stagePrice and #state.relics < 5

            local r, g, b = unpack(Relics.getRarityColor(relic.rarity))
            if relic.sold then love.graphics.setColor(0.3, 0.3, 0.3, 0.8)
            elseif not canBuy then love.graphics.setColor(r * 0.25, g * 0.25, b * 0.25, 0.7)
            else love.graphics.setColor(r * 0.2, g * 0.2, b * 0.2, 0.95) end
            love.graphics.rectangle("fill", cx, card_y, card_w, card_h, 6)
            love.graphics.setColor(relic.sold and {0.5, 0.5, 0.5} or {r, g, b})
            love.graphics.setLineWidth(2); love.graphics.rectangle("line", cx, card_y, card_w, card_h, 6); love.graphics.setLineWidth(1)

            local icon_size = 58
            UI.drawRelicIcon(relic, cx + (card_w - icon_size) / 2, card_y + 4, icon_size, 78)

            -- 名称（自动换行，最多 2 行；放不下则截断并以 "..." 结尾）
            love.graphics.setColor(1, 1, 1); love.graphics.setFont(UI.cjkFontSmall)
            local relicNameY = card_y + 84
            local relicNameStep = 13                       -- 与下方逐行绘制用的行距一致
            local _, relicNameCount, relicNameLines = UI.fitTextEllipsis(relic.name, UI.cjkFontSmall,
                card_w - 8, 2 * relicNameStep, relicNameStep)
            for ni = 1, relicNameCount do
                love.graphics.printf(relicNameLines[ni], cx + 4, relicNameY + (ni - 1) * relicNameStep, card_w - 8, "center")
            end

            -- 价格（固定卡片底部）
            local priceY = card_y + card_h - 18
            if relic.sold then
                love.graphics.setColor(0.5, 0.5, 0.5)
                love.graphics.printf("已售出", cx + 4, priceY, card_w - 8, "center")
            else
                love.graphics.setColor(discounted and {0.35, 1, 0.45} or (canBuy and {1, 1, 0} or {0.8, 0.3, 0.3}))
                love.graphics.printf("$" .. stagePrice, cx + 4, priceY, card_w - 8, "center")
            end
            -- 打折角标（每店一个货架位置固定 2-9 折）
            if discounted and not relic.sold then
                love.graphics.setColor(0.05, 0.55, 0.2, 0.96)
                love.graphics.rectangle("fill", cx + card_w - 32, card_y + 4, 28, 16, 4)
                love.graphics.setColor(1, 1, 1)
                love.graphics.setFont(UI.cjkFontSmall)
                love.graphics.printf(math.floor(state._shopDiscount.rate * 10 + 0.5) .. "折",
                                     cx + card_w - 32, card_y + 6, 28, "center")
            end

            UI.addHoverTarget(relic, cx, card_y, card_w, card_h)
            table.insert(UI._shopCards, { kind = "relic", index = i, relic = relic, x = cx, y = card_y, w = card_w, h = card_h })

        else  -- deck
            local offer = entry.offer
            local deckBase = offer.price
            local deckPrice = GameState.shopItemPrice(state, deckBase, i)   -- 打折位：纯牌组店 i / 普通店 5
            offer._shopPrice = deckPrice
            local discounted = deckPrice < deckBase
            local canBuy = not offer.sold and state.player.chips >= deckPrice
            local color = offer.color or {1, 0.85, 0.2}

            -- 背景
            if offer.sold then love.graphics.setColor(0.25, 0.2, 0.1, 0.9)
            elseif not canBuy then love.graphics.setColor(0.35, 0.25, 0.08, 0.9)
            else love.graphics.setColor(0.18, 0.13, 0.05, 0.95) end
            love.graphics.rectangle("fill", cx, card_y, card_w, card_h, 6)

            -- 黄色边框（区别于遗物）
            local borderCol = offer.sold and {0.5, 0.5, 0.4} or {1, 0.85, 0.2}
            love.graphics.setColor(unpack(borderCol))
            love.graphics.setLineWidth(2.5); love.graphics.rectangle("line", cx + 0.5, card_y + 0.5, card_w - 1, card_h - 1, 6); love.graphics.setLineWidth(1)

            -- 色条（顶部）
            love.graphics.setColor(unpack(color))
            love.graphics.rectangle("fill", cx + 3, card_y + 3, card_w - 6, 4, 2)

            -- 中间：小图标（牌背方块）
            local ico = 54
            love.graphics.setColor(0.95, 0.95, 0.95)
            love.graphics.rectangle("fill", cx + (card_w - ico)/2, card_y + 14, ico, 72, 5)
            love.graphics.setColor(unpack(color))
            love.graphics.setFont(UI.cjkFontMid)
            local icoText
            if offer.typeKey == "decimal" then icoText = "小数"
            elseif offer.typeKey == "negative" then icoText = "负数"
            elseif offer.typeKey == "multiplier" then icoText = "倍率"
            elseif offer.typeKey == "s67" then icoText = "67"
            elseif offer.typeKey == "rps" then icoText = "RPS"
            elseif offer.typeKey == "remove" then icoText = "删"
            elseif offer.typeKey == "blackhole" then icoText = "黑洞"
            elseif offer.typeKey == "cage" then icoText = "牢笼"
            elseif offer.typeKey == "champion" then icoText = "冠军"
            else icoText = "?" end
            love.graphics.printf(icoText,
                                  cx + (card_w - ico)/2, card_y + 40, ico, "center")

            -- 名称（自动换行，最多 2 行；放不下则截断并以 "..." 结尾）
            -- 名字区上收 + 行距 12：给底部价格留出净空，杜绝文字压边框
            love.graphics.setColor(1, 1, 1); love.graphics.setFont(UI.cjkFontSmall)
            local deckNameY = card_y + 88
            local deckNameStep = 12                         -- 与下方逐行绘制用的行距一致
            local _, deckNameCount, deckNameLines = UI.fitTextEllipsis(offer.name, UI.cjkFontSmall,
                card_w - 8, 2 * deckNameStep, deckNameStep)
            for ni = 1, deckNameCount do
                love.graphics.printf(deckNameLines[ni], cx + 4, deckNameY + (ni - 1) * deckNameStep, card_w - 8, "center")
            end

            -- 价格（固定卡片底部，与名字区之间保有间隔）
            local priceY = card_y + card_h - 16
            if offer.sold then
                love.graphics.setColor(0.6, 0.6, 0.6)
                love.graphics.printf("已售出", cx + 4, priceY, card_w - 8, "center")
            else
                love.graphics.setColor(discounted and {0.35, 1, 0.45} or (canBuy and {1, 1, 0} or {0.8, 0.3, 0.3}))
                love.graphics.printf("$" .. deckPrice, cx + 4, priceY, card_w - 8, "center")
            end
            -- 打折角标（每店一个货架位置固定 2-9 折）
            if discounted and not offer.sold then
                love.graphics.setColor(0.05, 0.55, 0.2, 0.96)
                love.graphics.rectangle("fill", cx + card_w - 32, card_y + 4, 28, 16, 4)
                love.graphics.setColor(1, 1, 1)
                love.graphics.setFont(UI.cjkFontSmall)
                love.graphics.printf(math.floor(state._shopDiscount.rate * 10 + 0.5) .. "折",
                                     cx + card_w - 32, card_y + 6, 28, "center")
            end

            UI.addHoverTarget(offer, cx, card_y, card_w, card_h)
            table.insert(UI._shopCards, { kind = "deck", index = i, offer = offer, x = cx, y = card_y, w = card_w, h = card_h })
        end
    end

    -- ========== 按钮（坐标存入 UI._shopButtons，handleShopClick 直接读）==========
    UI._shopButtons = {}
    local btnY = card_y + card_h + 25; local btnW = 140; local btnH = 36
    local rerollPrice = state.shopRerollCost

    love.graphics.setColor(state.player.chips >= rerollPrice and {0.3, 0.5, 0.8} or {0.4, 0.4, 0.4})
    love.graphics.rectangle("fill", start_x, btnY, btnW, btnH, 4)
    love.graphics.setColor(1, 1, 1); love.graphics.setFont(UI.cjkFont)
    love.graphics.printf("重刷 $" .. rerollPrice .. " [R]", start_x, btnY + 8, btnW, "center")
    table.insert(UI._shopButtons, { action = "reroll", x = start_x, y = btnY, w = btnW, h = btnH })

    -- ===== 铸造（二阶段以后 20% 出现，每店限一次）：把一件有次数限制的遗物改为永久 =====
    -- 位置紧随重刷键之后；真实货架恒为 5 张卡（4 遗物 + 1 牌组 / 纯牌组 5），
    -- 重刷 140 + 12 + 铸造 140 = 292 < 货架宽 548，不会与「离开」重叠
    if state._forgeOffered and not state._forgeUsed then
        local forgeX = start_x + btnW + 12
        local canForge = state.player.chips >= GameState.FORGE_PRICE
        love.graphics.setColor(canForge and {0.55, 0.35, 0.85} or {0.36, 0.30, 0.44})
        love.graphics.rectangle("fill", forgeX, btnY, btnW, btnH, 4)
        love.graphics.setColor(1, 1, 1); love.graphics.setFont(UI.cjkFont)
        love.graphics.printf("铸造 $" .. GameState.FORGE_PRICE, forgeX, btnY + 8, btnW, "center")
        table.insert(UI._shopButtons, { action = "forge", x = forgeX, y = btnY, w = btnW, h = btnH })

        love.graphics.setFont(UI.cjkFontSmall); love.graphics.setColor(0.62, 0.55, 0.78)
        love.graphics.printf("铸造：把一件有次数限制的遗物改为永久生效（每店限一次）", 0, btnY + btnH + 8, w, "center")
    end

    local leaveX = start_x + total_w - btnW
    love.graphics.setColor({0.5, 0.5, 0.5})
    love.graphics.rectangle("fill", leaveX, btnY, btnW, btnH, 4)
    love.graphics.setColor(1, 1, 1)
    love.graphics.printf("离开 [ESC]", leaveX, btnY + 8, btnW, "center")
    table.insert(UI._shopButtons, { action = "leave", x = leaveX, y = btnY, w = btnW, h = btnH })

    -- 铸造选择面板（模态：盖在商店上，打开时屏蔽商店点击）
    UI.drawForgeSelect(state)
end

-- ============================================================
-- 铸造选择面板（商店模态）：列出可铸造目标，点选确认后才扣款
-- 热区写入 UI._forgeBtns（单一数据源，handleShopClick 直接读）
-- ============================================================
function UI.drawForgeSelect(state)
    if not state.forgeSelectOpen or state.state ~= "shop" then return end
    local w, h = love.graphics.getWidth(), love.graphics.getHeight()

    love.graphics.setColor(0, 0, 0, 0.85)
    love.graphics.rectangle("fill", 0, 0, w, h)

    local targets = GameState.forgeTargets(state)
    local panelW = math.min(560, w - 60)
    local px = (w - panelW) / 2
    local rowH = 58
    local panelH = 96 + #targets * rowH + 56
    local py = math.max(30, (h - panelH) / 2)

    love.graphics.setColor(0.09, 0.07, 0.15, 0.98)
    love.graphics.rectangle("fill", px, py, panelW, panelH, 8)
    love.graphics.setColor(0.55, 0.35, 0.85)
    love.graphics.setLineWidth(2); love.graphics.rectangle("line", px, py, panelW, panelH, 8); love.graphics.setLineWidth(1)

    love.graphics.setFont(UI.cjkFont); love.graphics.setColor(0.85, 0.7, 1)
    love.graphics.printf("铸造 —— 选择一件有次数限制的遗物", px, py + 14, panelW, "center")
    love.graphics.setFont(UI.cjkFontSmall); love.graphics.setColor(0.7, 0.65, 0.8)
    love.graphics.printf("花费 $" .. GameState.FORGE_PRICE .. " 使其永久生效（每店限一次）", px, py + 40, panelW, "center")

    UI._forgeBtns = {}
    local rowsY = py + 72
    for i, t in ipairs(targets) do
        local lib = (t.type == "relic") and t.relic or Relics.getById(t.mark.id)
        if lib then
            local ry = rowsY + (i - 1) * rowH
            love.graphics.setColor(0.16, 0.13, 0.25)
            love.graphics.rectangle("fill", px + 10, ry, panelW - 20, rowH - 6, 5)

            if t.type == "relic" then
                UI.drawRelicIcon(lib, px + 18, ry + 7, 34, 38)
            else
                UI.drawRelicIcon({ markDot = lib.markDot }, px + 18, ry + 7, 34, 38)
            end

            local usesTag
            if t.type == "relic" then
                usesTag = "（剩余 " .. (lib._usesLeft or 0) .. " 次）"
            else
                usesTag = t.mark.forged and "（∞）" or ("（剩余 " .. (t.mark.uses or 0) .. " 次）")
            end
            love.graphics.setFont(UI.cjkFont); love.graphics.setColor(1, 1, 0.9)
            love.graphics.print(lib.name .. usesTag, px + 62, ry + 7)
            love.graphics.setFont(UI.cjkFontSmall); love.graphics.setColor(0.8, 0.8, 0.85)
            local oneLine = (lib.desc or ""):gsub("[\r\n]+", " ")
            love.graphics.print(UI.fitTextEllipsis(oneLine, UI.cjkFontSmall, panelW - 100, 16), px + 62, ry + 30)

            table.insert(UI._forgeBtns, { target = t, x = px + 10, y = ry, w = panelW - 20, h = rowH - 6 })
        end
    end

    -- 取消按钮（不扣款）
    local cy = rowsY + #targets * rowH + 6
    love.graphics.setColor(0.45, 0.45, 0.5)
    love.graphics.rectangle("fill", px + panelW / 2 - 70, cy, 140, 34, 5)
    love.graphics.setColor(1, 1, 1); love.graphics.setFont(UI.cjkFont)
    love.graphics.printf("取消 [ESC]", px + panelW / 2 - 70, cy + 8, 140, "center")
    table.insert(UI._forgeBtns, { cancel = true, x = px + panelW / 2 - 70, y = cy, w = 140, h = 34 })
end

-- ============================================================
-- Caster 遗物替换面板（模态）
-- 两步选择：先点自己的遗物（被替换）→ 再点 3 个候选里的 1 个 → 立即替换并关闭
-- 所有坐标按窗口比例计算；热区写入 UI._classOfferRelics / _classOfferCards / _classOfferButtons
-- ============================================================
function UI.drawClassOffer(state)
    local offer = state.classOffer
    if state.state ~= "classOffer" or not offer then return end

    local w, h = love.graphics.getWidth(), love.graphics.getHeight()

    love.graphics.setColor(0, 0, 0, 0.9)
    love.graphics.rectangle("fill", 0, 0, w, h)

    -- 顺序排版：每一块的 y 由上一块的实际高度推出，任何分辨率都不重叠
    local gGap   = math.max(8, math.floor(h * 0.02))
    local lineH  = 13                                  -- cjkFontSmall 行高（与商店一致）
    local y = math.floor(h * 0.045)

    -- 标题
    love.graphics.setFont(UI.splash.titleFont or UI.cjkFontMid)
    love.graphics.setColor(0.75, 0.55, 1)
    love.graphics.printf("Caster —— 遗物替换", 0, y, w, "center")
    y = y + (UI.splash.titleFont and UI.splash.titleFont:getHeight() or 40) + gGap

    -- 副标题（术之残卷的 replaceSelf 面板与 Caster 职阶面板共用布局，文案区分）
    love.graphics.setFont(UI.cjkFontMid)
    love.graphics.setColor(1, 1, 1)
    if offer.replaceSelf then
        love.graphics.printf("残卷觉醒（连胜 3 局）：挑 1 个候选替换【术之残卷】自身，也可拒绝", 0, y, w, "center")
    else
        love.graphics.printf("3 连胜奖励：从 3 个候选遗物里挑 1 个，替换掉自己已有的 1 个", 0, y, w, "center")
    end
    y = y + UI.cjkFontMid:getHeight() + gGap

    -- ========== 第一行：自己的遗物 ==========
    love.graphics.setFont(UI.cjkFont)
    love.graphics.setColor(1, 0.85, 0.4)
    if offer.replaceSelf then
        love.graphics.printf("你的遗物（将替换高亮的残卷自身）", 0, y, w, "center")
    else
        love.graphics.printf("你的遗物（先点一个作为「被替换」）", 0, y, w, "center")
    end
    y = y + UI.cjkFont:getHeight() + math.floor(gGap * 0.5)

    local relicW   = math.min(110, math.floor(w * 0.075))
    local relicH   = math.floor(relicW * 1.35)
    local relicGap = math.max(8, math.floor(w * 0.012))
    local relics   = state.relics or {}
    local relicRowW = #relics * relicW + math.max(0, #relics - 1) * relicGap
    local relicX0  = math.max(10, math.floor((w - relicRowW) / 2))

    UI._classOfferRelics = {}
    for i, relic in ipairs(relics) do
        local cx = relicX0 + (i - 1) * (relicW + relicGap)
        -- 未激活的遗物画灰度（与左侧遗物栏语义一致）
        local greyTint = (not Relics.isPreGame(relic)) and relic.active ~= true
        UI.drawRelicIcon(relic, cx, y, relicW, relicH, greyTint)

        -- 选中态：黄色呼吸边框
        if state.classOfferTarget == i then
            local a = 0.6 + 0.4 * math.sin(love.timer.getTime() * 4)
            love.graphics.setColor(1, 0.9, 0.2, a)
            love.graphics.setLineWidth(4)
            love.graphics.rectangle("line", cx - 2, y - 2, relicW + 4, relicH + 4, 6)
            love.graphics.setLineWidth(1)
        end

        -- 名称（最多 2 行；放不下则截断并以 "..." 结尾）
        love.graphics.setFont(UI.cjkFontSmall)
        love.graphics.setColor(1, 1, 1)
        local _, cnt, lines = UI.fitTextEllipsis(relic.name, UI.cjkFontSmall, relicW, 2 * lineH, lineH)
        for ni = 1, cnt do
            love.graphics.printf(lines[ni], cx, y + relicH + 2 + (ni - 1) * lineH, relicW, "center")
        end

        UI.addHoverTarget(relic, cx, y, relicW, relicH)
        table.insert(UI._classOfferRelics, { index = i, x = cx, y = y, w = relicW, h = relicH })
    end
    y = y + relicH + 2 + 2 * lineH + gGap

    -- ========== 第二行：候选遗物（3 选 1）==========
    love.graphics.setFont(UI.cjkFont)
    love.graphics.setColor(0.6, 0.9, 1)
    if state.classOfferTarget then
        love.graphics.printf("候选遗物（点一个完成替换）", 0, y, w, "center")
    else
        love.graphics.printf("候选遗物（3 选 1）— 请先在上面选一个要替换掉的遗物", 0, y, w, "center")
    end
    y = y + UI.cjkFont:getHeight() + math.floor(gGap * 0.5)

    local offerW    = math.min(120, math.floor(w * 0.085))
    local offerH    = math.floor(offerW * 1.35)
    local offerGap  = math.max(10, math.floor(w * 0.015))
    local opts      = offer.options or {}
    local offerRowW = #opts * offerW + math.max(0, #opts - 1) * offerGap
    local offerX0   = math.max(10, math.floor((w - offerRowW) / 2))
    local picked    = state.classOfferTarget ~= nil or offer.replaceSelf == true

    UI._classOfferCards = {}
    for i, relic in ipairs(opts) do
        local cx = offerX0 + (i - 1) * (offerW + offerGap)

        love.graphics.setColor(0.1, 0.1, 0.14, 0.95)
        love.graphics.rectangle("fill", cx, y, offerW, offerH, 6)
        UI.drawRelicIcon(relic, cx, y, offerW, offerH)

        -- 还没选目标时整体压暗，提示"先选被替换的遗物"
        if not picked then
            love.graphics.setColor(0, 0, 0, 0.45)
            love.graphics.rectangle("fill", cx, y, offerW, offerH, 6)
        end

        love.graphics.setFont(UI.cjkFontSmall)
        love.graphics.setColor(picked and {1, 1, 1} or {0.55, 0.55, 0.55})
        local _, cnt, lines = UI.fitTextEllipsis(relic.name, UI.cjkFontSmall, offerW, 2 * lineH, lineH)
        for ni = 1, cnt do
            love.graphics.printf(lines[ni], cx, y + offerH + 2 + (ni - 1) * lineH, offerW, "center")
        end

        UI.addHoverTarget(relic, cx, y, offerW, offerH)
        table.insert(UI._classOfferCards, { index = i, x = cx, y = y, w = offerW, h = offerH })
    end

    -- ========== 底部按钮：不换 ==========
    UI._classOfferButtons = {}
    local btnW = math.min(220, math.floor(w * 0.18))
    local btnH = math.max(36, math.floor(h * 0.062))
    local btnX = math.floor((w - btnW) / 2)
    local btnY = math.floor(h * 0.9)
    local mx, my = love.mouse.getPosition()
    local hover = mx >= btnX and mx <= btnX + btnW and my >= btnY and my <= btnY + btnH

    love.graphics.setColor(hover and {0.45, 0.45, 0.5} or {0.32, 0.32, 0.36})
    love.graphics.rectangle("fill", btnX, btnY, btnW, btnH, 5)
    love.graphics.setColor(1, 1, 1)
    love.graphics.setFont(UI.cjkFont)
    love.graphics.printf("不换 (ESC)", btnX, btnY + btnH / 2 - 12, btnW, "center")
    table.insert(UI._classOfferButtons, { action = "keep", x = btnX, y = btnY, w = btnW, h = btnH })
end

-- ============================================================
-- Saber 斩击动画（对角线光刃 + 牌裂成两半飞开）
-- ============================================================
function UI.drawSaberSlash(state)
    local sa = state._saberAnim
    if not sa then return end
    local card = sa.card
    local t = (sa.t or 0) / sa.duration   -- 0.0 → 1.0
    if t > 1 then t = 1 end

    -- 找到这张牌当前的屏幕坐标（drawCard 存的 visual 位置）
    local cx, cy = 0, 0
    local HAND_SCALE = 0.625
    local cw = UI.card.width * HAND_SCALE
    local ch = UI.card.height * HAND_SCALE
    if card.visual then
        cx = card.visual.x or 0
        cy = card.visual.y or 0
        cw = UI.card.width * HAND_SCALE * (card.visual.scaleX or 1)
        ch = UI.card.height * HAND_SCALE * (card.visual.scaleY or 1)
    end

    -- ===== Phase 1 (0-0.15): 屏幕红闪 + 微震 =====
    if t < 0.18 then
        local p = t / 0.18
        local w, h = love.graphics.getWidth(), love.graphics.getHeight()
        love.graphics.setColor(0.8, 0.1, 0.1, 0.25 * (1 - p))
        love.graphics.rectangle("fill", 0, 0, w, h)
    end

    -- ===== Phase 2 (0.15-0.40): 光刃扫过 =====
    -- 光刃从右上角 → 左下角（对角线），在牌中央穿过
    local ww, wh = love.graphics.getWidth(), love.graphics.getHeight()
    if t >= 0.15 and t < 0.45 then
        local p = (t - 0.15) / 0.30   -- 0→1
        local progress = p * p        -- ease-in

        -- 光刃中心沿对角线移动（从右上到左下）
        local edgeX = ww + 50
        local edgeY = -50
        local bladeX = edgeX - (edgeX + 50) * progress   -- 移到左下方向
        local bladeY = edgeY + (wh + 100) * progress

        -- 先画白色亮线（核心）
        love.graphics.setColor(1, 1, 1, 0.95 * (1 - math.abs(p - 0.5) * 1.2))
        love.graphics.setLineWidth(6)
        -- 光刃方向：和移动方向垂直（更像挥剑）
        local dx, dy = -1, 1   -- 对角线方向向量
        local len = math.sqrt(ww * ww + wh * wh)
        local nx, ny = -dy, dx  -- 法线方向
        love.graphics.line(
            bladeX - nx * len * 0.6, bladeY - ny * len * 0.6,
            bladeX + nx * len * 0.6, bladeY + ny * len * 0.6
        )

        -- 外层红色光焰
        love.graphics.setColor(1, 0.3, 0.3, 0.6 * (1 - math.abs(p - 0.5) * 1.2))
        love.graphics.setLineWidth(16)
        love.graphics.line(
            bladeX - nx * len * 0.6, bladeY - ny * len * 0.6,
            bladeX + nx * len * 0.6, bladeY + ny * len * 0.6
        )

        -- 更深的红光外晕
        love.graphics.setColor(0.7, 0, 0, 0.25 * (1 - math.abs(p - 0.5) * 1.2))
        love.graphics.setLineWidth(32)
        love.graphics.line(
            bladeX - nx * len * 0.6, bladeY - ny * len * 0.6,
            bladeX + nx * len * 0.6, bladeY + ny * len * 0.6
        )
        love.graphics.setLineWidth(1); love.graphics.setColor(1, 1, 1, 1)

        -- 剑鸣/斩击声（用 Sfx.play21 复用，或直接 short beep）
        if sa._slashSfxPlayed ~= true then
            sa._slashSfxPlayed = true
            if Sfx and Sfx.play21 then Sfx.play21() end
        end
    end

    -- ===== Phase 3 (0.30-1.0): 牌裂成两半飞开 + 淡出 =====
    if t >= 0.30 then
        local p = (t - 0.30) / 0.70   -- 0→1
        if p > 1 then p = 1 end
        -- ease-out
        local e = 1 - (1 - p) * (1 - p)

        -- 先用黑色盖掉原来那张完整牌（否则会重叠显示）
        love.graphics.setScissor(cx - 6, cy - 6, cw + 12, ch + 12)
        love.graphics.setColor(0, 0, 0, 0.99)
        love.graphics.rectangle("fill", cx - 6, cy - 6, cw + 12, ch + 12)
        love.graphics.setScissor()

        -- 目标位移：左半（上三角）往左上飞，右半（下三角）往右下飞
        local halfW = cw / 2
        local halfH = ch / 2
        local flyDist = 120 + 80 * e

        local alpha = 1 - p * 0.95
        local rotAngle = 0.6 * p   -- 牌片旋转

        -- === 画左上角（用 scissor 把完整牌裁成两半）===
        love.graphics.setScissor(cx - 4, cy - 4, halfW + 4, ch + 8)

        -- 左半位移（左上）
        local ox1 = -flyDist * 0.6
        local oy1 = -flyDist * 0.55 - 40 * p   -- 同时上飘
        love.graphics.push()
        love.graphics.translate(cx + halfW + ox1, cy + halfH + oy1)
        love.graphics.rotate(-rotAngle)
        love.graphics.setColor(1, 1, 1, alpha)
        UI.drawCard(card, -halfW, -halfH, true, HAND_SCALE)
        love.graphics.pop()

        -- === 画右下角 ===
        love.graphics.setScissor(cx + halfW - 2, cy - 4, halfW + 6, ch + 8)

        local ox2 = flyDist * 0.6
        local oy2 = flyDist * 0.55 - 20 * p
        love.graphics.push()
        love.graphics.translate(cx + halfW + ox2, cy + halfH + oy2)
        love.graphics.rotate(rotAngle)
        love.graphics.setColor(1, 1, 1, alpha)
        UI.drawCard(card, -halfW, -halfH, true, HAND_SCALE)
        love.graphics.pop()

        love.graphics.setScissor()
        love.graphics.setColor(1, 1, 1, 1)
    end
end

-- ============================================================
-- 结算详情
--   酒吧模式（gameMode == "bar"）：只展示「醉酒倒计时」，绝不出现 WIN!/PUSH/LOSE
--   与下注 / 筹码 / 倍率 / 净增减等条目（酒吧模式下这些恒为 0 或无意义）。
--   非酒吧模式（基础 / 困难）走原逻辑，一字不改。
-- ============================================================
function UI.drawResults(state)
    if state.state ~= "result" or not state.lastScoreDetails then return end

    -- 面板锚点：宽固定 500（内容定宽），水平居中；纵向取屏高 1/4（800×600 时 = 150）
    local w, h = love.graphics.getWidth(), love.graphics.getHeight()
    local px, py = (w - 500) / 2, h * 0.25

    -- ===== 酒吧模式分支：醉酒倒计时面板 =====
    if state.gameMode == "bar" then
        local th = UI.barTheme
        local bar = state.bar or {}

        love.graphics.setColor(0, 0, 0, 0.85)
        love.graphics.rectangle("fill", px, py, 500, 350, 10)
        love.graphics.setColor(th.panelEdge)
        love.graphics.setLineWidth(2)
        love.graphics.rectangle("line", px + 1, py + 1, 498, 348, 10)
        love.graphics.setLineWidth(1)

        love.graphics.setFont(UI.splash.titleFont); love.graphics.setColor(th.accent)
        love.graphics.printf("醉酒倒计时", px, py + 15, 500, "center")

        local active = Cocktails.activeList(state)   -- 顺序已按 LIBRARY 固定，不再自行排序
        local listTop, listBottom = py + 70, py + 290
        local n = #active
        -- 容量预算：面板列表区 220px、行距下限 14 → 最多 15 行。生效酒更多时
        -- 不再静默冲出面板，改留出最后一行显式提示（「另有 N 款生效中」）。
        local maxRows = math.floor((listBottom - listTop) / 14)
        local shownRows, hiddenRows = n, 0
        if n > maxRows then
            hiddenRows = n - maxRows + 1             -- 最后一行让给溢出提示
            shownRows = maxRows - 1
            if shownRows < 0 then shownRows = 0 end
        end
        local step = math.floor((listBottom - listTop) / math.max(1, shownRows))
        if step > 28 then step = 28 end
        if step < 14 then step = 14 end
        local iconH = math.max(10, step - 4)
        local iconW = iconH * (40 / 58)   -- 与 barDrinkIconSize 同比例（cocktails/<id>.png 立绘 40:58）
        local textX = px + 30 + iconW + 6
        -- 行距被压到 20 以下时换小字号，避免相邻行文字互相叠压
        local listFont = (step >= 20) and UI.cjkFont or UI.cjkFontSmall

        if n == 0 then
            love.graphics.setFont(UI.cjkFont); love.graphics.setColor(th.textDim)
            love.graphics.printf("当前无醉酒", px, listTop + 20, 500, "center")
        else
            local ry = listTop
            for i, item in ipairs(active) do
                if i > shownRows then break end
                UI.barDrawDrink(item.def.id, px + 30, ry, iconW, iconH)
                love.graphics.setFont(listFont); love.graphics.setColor(th.text)
                local label = item.def.name .. "  剩余 " .. item.turns .. " 回合"
                love.graphics.printf(UI.fitTextEllipsis(label, listFont, px + 480 - textX, step),
                                     textX, ry, px + 480 - textX, "left")
                ry = ry + step
            end
            if hiddenRows > 0 then
                love.graphics.setFont(UI.cjkFontSmall); love.graphics.setColor(th.textDim)
                love.graphics.printf("另有 " .. hiddenRows .. " 款生效中", px, ry, 500, "center")
            end
        end

        -- 本局刚有酒到期 → 预告下一局宿醉（与侧栏倒计时区分：这是「下一局」的事）
        if bar.hangoverRound and bar.hangoverRound == (bar.round or 0) + 1 then
            love.graphics.setFont(UI.cjkFontSmall); love.graphics.setColor(th.accent)
            love.graphics.printf("宿醉：下一局眼花，看不清手牌", px, py + 298, 500, "center")
        end

        local t = love.timer.getTime()
        local alpha = 0.5 + 0.5 * math.sin(t * 4)
        love.graphics.setColor(1, 1, 0.5, alpha); love.graphics.setFont(UI.cjkFont)
        love.graphics.printf("点击屏幕或按任意键继续...", px, py + 324, 500, "center")
        love.graphics.setColor(1, 1, 1)
        return
    end

    local d = state.lastScoreDetails

    love.graphics.setColor(0, 0, 0, 0.85)
    -- 面板高度 380（问题 2）：新增两行点数后最多 9 行，行距 28 不变，
    -- 末行后的「点击屏幕或按任意键继续...」必须留在面板内（底边 py+380）。
    love.graphics.rectangle("fill", px, py, 500, 380, 10)

    local resultText, resultColor
    if d.result == "player" then resultText = "WIN!"; resultColor = {0.3, 1, 0.3}
    elseif d.result == "push" then resultText = "PUSH"; resultColor = {1, 1, 0.3}
    else resultText = "LOSE"; resultColor = {1, 0.3, 0.3} end

    love.graphics.setFont(UI.splash.titleFont); love.graphics.setColor(unpack(resultColor))
    love.graphics.printf(resultText, px, py + 15, 500, "center")

    love.graphics.setFont(UI.font); love.graphics.setColor(1, 1, 1)
    local ly = py + 70
    local lines = {
        string.format("下注:          $%d", d.bet),
        string.format("基础筹码:      $%d", d.baseChips),
        string.format("遗物加成:      +$%d", d.relicChips),
    }
    if d.multAdd and d.multAdd > 0 then table.insert(lines, string.format("倍率 +%d", d.multAdd)) end
    if d.xMultProd and d.xMultProd > 1 then table.insert(lines, string.format("最终 ×%.2f", d.xMultProd)) end
    table.insert(lines, string.format("净增减:        $%+d", d.netChange))
    table.insert(lines, string.format("最终筹码:      $%d", state.player.chips))
    -- 新增两行（问题 2）：点数一律 Blackjack.calculateHand 现算，不碰 state.lastScoreDetails
    -- （它只含下注 / 筹码 / 倍率 / 净增减）；既有行的内容、顺序一字不动。
    table.insert(lines, string.format("玩家点数:      %d", Blackjack.calculateHand(state.player.hand)))
    table.insert(lines, string.format("庄家点数:      %d", Blackjack.calculateHand(state.dealer.hand)))

    for _, line in ipairs(lines) do
        love.graphics.print(line, px + 50, ly); ly = ly + 28
    end

    local t = love.timer.getTime()
    local alpha = 0.5 + 0.5 * math.sin(t * 4)
    love.graphics.setColor(1, 1, 0.5, alpha); love.graphics.setFont(UI.cjkFont)
    love.graphics.printf("点击屏幕或按任意键继续...", px, ly + 15, 500, "center")
end

-- ============================================================
-- 宿醉全屏滤镜
--   只在「酒吧模式 且 hangoverRound == bar.round」的宿醉局绘制，纯视觉、不碰任何数值。
--   全屏半透明矩形，alpha 0.12（淡淡的，不遮挡可读性），颜色取到期酒颜色的算术平均。
--   调用位置在 drawAll 的 drawControls 与 drawResults 之间 —— 牌桌/手牌/按钮/侧栏都在
--   滤镜之下（名副其实的全屏），结算面板与各类模态弹窗都在其上，不会被染色。
--   禁区：不改任何点数计算、胜负判定、可点击区域或抽牌逻辑。
-- ============================================================
function UI.drawHangoverFilter(state)
    if not state or state.gameMode ~= "bar" then return end
    local bar = state.bar
    if not bar or not bar.hangoverRound or bar.hangoverRound ~= bar.round then return end

    local col = bar.hangoverColor
    if col then love.graphics.setColor(col[1] or 0, col[2] or 0, col[3] or 0, 0.12)
    else       love.graphics.setColor(0.5, 0.5, 0.5, 0.12) end
    love.graphics.rectangle("fill", 0, 0, love.graphics.getWidth(), love.graphics.getHeight())
    love.graphics.setColor(1, 1, 1)
end

-- ============================================================
-- 阶段完成界面（含庄家机制变化提示）
-- ============================================================
function UI.drawStageClear(state)
    if state.state ~= "stageClear" then return end
    local w, h = love.graphics.getWidth(), love.graphics.getHeight()

    love.graphics.setColor(0, 0, 0, 0.88)
    love.graphics.rectangle("fill", 100, 100, w - 200, h - 200, 15)

    love.graphics.setFont(UI.splash.titleFont); love.graphics.setColor(1, 0.8, 0.2)
    love.graphics.printf("★ 阶段 " .. (state.stage - 1) .. " 完成！★", 100, h * 7 / 30, w - 200, "center")

    local stageColors = { [1] = {0.3, 0.8, 0.3}, [2] = {0.9, 0.5, 0.2}, [3] = {0.9, 0.2, 0.2} }
    local sc = stageColors[state.stage] or {1, 1, 1}
    love.graphics.setColor(sc[1], sc[2], sc[3])
    love.graphics.setFont(UI.cjkFont)

    -- 难度文字
    local diffDesc = {
        [1] = "经典策略（硬17停/软17继续）",
        [2] = "激进策略（18以下必要/软18继续）",
        [3] = "作弊AI（看你手牌决定是否要牌！）",
    }
    local difficultyText = (state.stage == 1 and "经典")
                        or (state.stage == 2 and "激进")
                        or "作弊（看牌！）"
    local oldDiff = (state.stage == 2 and "经典") or (state.stage == 3 and "激进") or "经典"

    local minChips = state.stageMinChips and state.stageMinChips[state.stage] or 0

    -- 说明块：下界 = 下一段内容的上沿（阶段 3 是红色警告，否则是「当前筹码」），放不下则截断并以 "..." 结尾
    local infoY = h * 0.35                                   -- 800×600 时 = 210
    local infoBottom = (state.stage == 3) and h * 37 / 60 or (h / 2 + 40)  -- 阶段 3 时 = 370
    local infoShown = UI.fitTextEllipsis(
        "下一阶段: " .. (state.stageName and state.stageName[state.stage] or "") ..
        "\n庄家难度: " .. difficultyText ..
        "\n庄家策略变化: " .. oldDiff .. " → " .. difficultyText ..
        "\n阶段最低金: $" .. minChips,
        UI.cjkFont, w - 200, infoBottom - infoY)
    love.graphics.printf(infoShown, 100, infoY, w - 200, "center")

    -- 阶段 3 红色警告（正文/规则行相对 infoBottom 步进：+30/+75）
    if state.stage == 3 then
        love.graphics.setColor(1, 0.2, 0.2)
        love.graphics.setFont(UI.cjkFont)
        love.graphics.printf("[!] 警告：庄家会看你的明牌！", 100, infoBottom, w - 200, "center")
        love.graphics.setFont(UI.cjkFontSmall)
        love.graphics.setColor(1, 0.5, 0.5)
        -- 警告正文：下界 = 下面「阶段 3 规则变化」那一行的 y（warnY=infoBottom+30 → ruleY=infoBottom+75）
        local warnShown = UI.fitTextEllipsis(
            "它会根据你的点数决定要不要牌。玩家点数高时会保守停牌\n点数低时会跟到你以上。注意调整策略！",
            UI.cjkFontSmall, w - 200, 45)
        love.graphics.printf(warnShown, 100, infoBottom + 30, w - 200, "center")
        love.graphics.setColor(1, 0.35, 0.35)
        -- 规则变化只占这一行（下注硬规则，必须完整显示；宽度足够时不会截断）
        local ruleShown = UI.fitTextEllipsis("阶段 3 规则变化：每次下注必须至少下注现有筹码的一半",
            UI.cjkFontSmall, w - 200, UI.cjkFontSmall:getHeight())
        love.graphics.printf(ruleShown, 100, infoBottom + 75, w - 200, "center")
    end

    love.graphics.setFont(UI.font); love.graphics.setColor(1, 1, 0.5)
    love.graphics.printf("当前筹码: $" .. state.player.chips, 100, h / 2 + 40, w - 200, "center")

    local t = love.timer.getTime()
    local alpha = 0.5 + 0.5 * math.sin(t * 4)
    love.graphics.setColor(1, 1, 0.5, alpha); love.graphics.setFont(UI.cjkFont)
    love.graphics.printf("点击或按任意键进入阶段 " .. state.stage, 100, h - 160, w - 200, "center")
end

-- ============================================================
-- 通关界面
-- ============================================================
function UI.drawVictory(state)
    if state.state ~= "victory" then return end
    local w, h = love.graphics.getWidth(), love.graphics.getHeight()

    love.graphics.setColor(0, 0, 0, 0.92)
    love.graphics.rectangle("fill", 80, 80, w - 160, h - 160, 15)

    love.graphics.setFont(UI.splash.titleFont); love.graphics.setColor(1, 0.9, 0.3)
    love.graphics.printf("通 关 胜 利", 80, h * 13 / 60, w - 160, "center")

    love.graphics.setFont(UI.cjkFont); love.graphics.setColor(1, 1, 1)
    -- 刷榜：本局用时小局数 + 历史最快纪录（recordVictory 写入 _victoryInfo）
    local vic = state._victoryInfo
    local recordLine = ""
    if vic then
        local modeText = (vic.mode == "hard") and "困难" or "基础"
        if vic.isNewRecord then
            recordLine = "\n本局用时 " .. vic.rounds .. " 小局（" .. modeText .. "）  ★ 新纪录！"
        else
            recordLine = "\n本局用时 " .. vic.rounds .. " 小局（" .. modeText .. "）  ·  最快纪录 " .. vic.best .. " 小局"
        end
    end
    love.graphics.printf("你击败了所有 3 个赌场！\n" ..
        "最终筹码: $" .. state.player.chips .. "\n" ..
        "持有遗物: " .. #state.relics .. " 个" .. recordLine,
        80, h * 23 / 60, w - 160, "center")

    local t = love.timer.getTime()
    local alpha = 0.5 + 0.5 * math.sin(t * 3)
    love.graphics.setColor(1, 1, 0.5, alpha)
    love.graphics.printf("点击或按任意键返回主界面", 80, h - 150, w - 160, "center")
end

-- ============================================================
-- Tooltip
-- ============================================================
UI._hoverTargets = nil
function UI.beginHoverTargets() UI._hoverTargets = {} end
function UI.addHoverTarget(relic, x, y, w, h) table.insert(UI._hoverTargets, { relic = relic, x = x, y = y, w = w, h = h }) end

function UI.getHoverTargetAt(mx, my)
    if not UI._hoverTargets then return nil end
    for _, t in ipairs(UI._hoverTargets) do
        if mx >= t.x and mx <= t.x + t.w and my >= t.y and my <= t.y + t.h then
            return t.relic
        end
    end
    return nil
end

-- ============================================================
-- 模式选择（开始游戏前）
-- ============================================================
function UI.drawModeSelect(state)
    if state.state ~= "modeSelect" then return end
    local w, h = love.graphics.getWidth(), love.graphics.getHeight()

    love.graphics.setColor(0, 0, 0, 0.92)
    love.graphics.rectangle("fill", 0, 0, w, h)

    love.graphics.setColor(1, 0.85, 0.2); love.graphics.setFont(UI.cjkFontXL)
    love.graphics.printf("选择游戏模式", 0, 80, w, "center")

    love.graphics.setColor(0.85, 0.85, 0.85); love.graphics.setFont(UI.cjkFontMid)
    love.graphics.printf("模式一经选定不可更改。你确定要挑战哪种？", 0, 130, w, "center")

    -- 三张卡横排（基础 / 困难 / 酒吧）：两张旧卡的文案与热区语义保持不变
    local cardW = math.min(280, w * 0.28)
    local cardH = 320
    local gap = math.max(20, math.floor(w * 0.03))
    local totalW = cardW * 3 + gap * 2
    local startX = (w - totalW) / 2
    local cardY = h / 2 - cardH / 2

    UI._modeSelectBtns = {}

    -- ===== 基础模式 =====
    local bx = startX
    love.graphics.setColor(0.2, 0.5, 0.2, 0.18)
    love.graphics.rectangle("fill", bx, cardY, cardW, cardH, 10)
    love.graphics.setColor(0.35, 0.75, 0.35, 0.95)
    love.graphics.setLineWidth(3); love.graphics.rectangle("line", bx+1, cardY+1, cardW-2, cardH-2, 10); love.graphics.setLineWidth(1)

    love.graphics.setColor(0.35, 0.75, 0.35, 0.95); love.graphics.setFont(UI.cjkFontXL)
    love.graphics.printf("基础模式", bx, cardY + 40, cardW, "center")
    love.graphics.setColor(1, 1, 1); love.graphics.setFont(UI.cjkFontMid)
    love.graphics.printf("NORMAL", bx, cardY + 88, cardW, "center")

    love.graphics.setColor(0.85, 0.85, 0.85); love.graphics.setFont(UI.cjkFontSmall)
    local basicLines = {
        "庄家按传统 21 点规则行动",
        "只有你在阶段 2→3 时选一个职阶",
        "适合熟悉玩法的新玩家",
        "",
        "目标：3 阶段累计筹码 $2,000,000",
    }
    -- 每行只占布局给它的那一行（步距 20），放不下则截断并以 "..." 结尾
    for i, line in ipairs(basicLines) do
        local shown = UI.fitTextEllipsis(line, UI.cjkFontSmall, cardW - 40, 20)
        love.graphics.printf(shown, bx + 20, cardY + 150 + (i-1) * 20, cardW - 40, "center")
    end

    table.insert(UI._modeSelectBtns, {
        x = bx, y = cardY, w = cardW, h = cardH,
        _mode = "basic",
    })

    -- ===== 困难模式 =====
    local hx = startX + cardW + gap
    love.graphics.setColor(0.5, 0.15, 0.15, 0.18)
    love.graphics.rectangle("fill", hx, cardY, cardW, cardH, 10)
    love.graphics.setColor(0.9, 0.25, 0.25, 0.95)
    love.graphics.setLineWidth(3); love.graphics.rectangle("line", hx+1, cardY+1, cardW-2, cardH-2, 10); love.graphics.setLineWidth(1)

    love.graphics.setColor(0.9, 0.25, 0.25, 0.95); love.graphics.setFont(UI.cjkFontXL)
    love.graphics.printf("困难模式", hx, cardY + 40, cardW, "center")
    love.graphics.setColor(1, 1, 1); love.graphics.setFont(UI.cjkFontMid)
    love.graphics.printf("HARD", hx, cardY + 88, cardW, "center")

    love.graphics.setColor(0.85, 0.85, 0.85); love.graphics.setFont(UI.cjkFontSmall)
    local hardLines = {
        "庄家从阶段 1 起就持有一个职阶",
        "每阶段切换时还会转职换另一个",
        "你在阶段 2→3 仍可选自己的职阶",
        "",
        "目标：同样 $2,000,000，难度翻倍",
    }
    -- 每行只占布局给它的那一行（步距 20），放不下则截断并以 "..." 结尾
    for i, line in ipairs(hardLines) do
        local shown = UI.fitTextEllipsis(line, UI.cjkFontSmall, cardW - 40, 20)
        love.graphics.printf(shown, hx + 20, cardY + 150 + (i-1) * 20, cardW - 40, "center")
    end

    table.insert(UI._modeSelectBtns, {
        x = hx, y = cardY, w = cardW, h = cardH,
        _mode = "hard",
    })

    -- ===== 酒吧模式（第三张卡）=====
    local brx = startX + (cardW + gap) * 2
    local th = UI.barTheme
    love.graphics.setColor(0.20, 0.15, 0.08, 0.35)
    love.graphics.rectangle("fill", brx, cardY, cardW, cardH, 10)
    love.graphics.setColor(0.92, 0.74, 0.32, 0.95)
    love.graphics.setLineWidth(3); love.graphics.rectangle("line", brx+1, cardY+1, cardW-2, cardH-2, 10); love.graphics.setLineWidth(1)

    love.graphics.setColor(0.92, 0.74, 0.32, 0.95); love.graphics.setFont(UI.cjkFontXL)
    love.graphics.printf("酒吧模式", brx, cardY + 40, cardW, "center")
    love.graphics.setColor(1, 1, 1); love.graphics.setFont(UI.cjkFontMid)
    love.graphics.printf("BAR", brx, cardY + 88, cardW, "center")

    love.graphics.setFont(UI.cjkFontSmall)
    local barLines = {
        "没有筹码、下注、破产与遗物",
        "调酒栏最多 6 杯，喝空即被请出去",
        "每输一局必须喝 1/5 杯",
        "喝一口获得该酒 5 小局的被动",
        "目标：撑满 100 小局，喝出结局",
    }
    -- 每行只占布局给它的那一行（步距 20），放不下则截断并以 "..." 结尾
    for i, line in ipairs(barLines) do
        love.graphics.setColor(0.90, 0.84, 0.68)
        local shown = UI.fitTextEllipsis(line, UI.cjkFontSmall, cardW - 40, 20)
        love.graphics.printf(shown, brx + 20, cardY + 142 + (i-1) * 20, cardW - 40, "center")
    end

    table.insert(UI._modeSelectBtns, {
        x = brx, y = cardY, w = cardW, h = cardH,
        _mode = "bar",
    })

    -- ESC 取消回标题
    love.graphics.setColor(0.6, 0.6, 0.6); love.graphics.setFont(UI.cjkFontSmall)
    love.graphics.printf("按 [ESC] 返回主菜单", 0, cardY + cardH + 30, w, "center")
end

-- ============================================================
-- 职阶选择面板（阶段 3 专属）
-- ============================================================
function UI.drawClassSelect(state)
    if state.state ~= "classSelect" then return end
    local w, h = love.graphics.getWidth(), love.graphics.getHeight()

    love.graphics.setColor(0, 0, 0, 0.92)
    love.graphics.rectangle("fill", 0, 0, w, h)

    love.graphics.setColor(1, 0.85, 0.2); love.graphics.setFont(UI.cjkFontXL)
    love.graphics.printf("选择你的职阶", 0, 60, w, "center")

    love.graphics.setColor(0.85, 0.85, 0.85); love.graphics.setFont(UI.cjkFontSmall)
    love.graphics.printf("进入黑暗赌场前，选一个职业。它将成为你接下来 30 回合的核心被动。\n（鼠标移上去看详细效果）", 0, 110, w, "center")

    local Classes = require("src.classes")
    local all = Classes.allIds()

    -- 两行布局：上 4 下 3，卡片自适应宽度
    local gap = 14
    local rows = { {1,2,3,4}, {5,6,7} }
    local cardW, cardH = 0, 0
    local topY = h / 2 - 140

    UI._classSelectCards = {}

    for ri, row in ipairs(rows) do
        local rowCount = #row
        cardW = math.min(150, (w - 80 - gap * (rowCount - 1)) / rowCount)
        cardH = math.min(200, cardW * 1.35)
        local totalW = cardW * rowCount + gap * (rowCount - 1)
        local startX = (w - totalW) / 2
        local cardY = topY + (ri - 1) * (cardH + 18)

        for ci, idx in ipairs(row) do
            local c = Classes.get(all[idx])
            local cx = startX + (ci - 1) * (cardW + gap)
            local col = c.color or { 0.7, 0.7, 0.7 }

            love.graphics.setColor(col[1]*0.18, col[2]*0.18, col[3]*0.18, 0.95)
            love.graphics.rectangle("fill", cx, cardY, cardW, cardH, 8)
            love.graphics.setColor(col[1], col[2], col[3], 0.95)
            love.graphics.setLineWidth(3); love.graphics.rectangle("line", cx+1, cardY+1, cardW-2, cardH-2, 8); love.graphics.setLineWidth(1)

            -- 中间大 icon
            love.graphics.setColor(col[1], col[2], col[3], 0.9)
            love.graphics.setFont(UI.cjkFontMid)
            love.graphics.printf(c.icon or c.name, cx, cardY + cardH * 0.15, cardW, "center")

            -- 名字（下界 = 同卡片下一次要画的内容的上沿；放不下则截断并以 "..." 结尾）
            love.graphics.setColor(1, 1, 1); love.graphics.setFont(UI.cjkFontSmall)
            local cnameY = cardY + cardH * 0.55
            local cnameBottom = c.charges and (cardY + cardH * 0.78) or (cardY + cardH)
            local _, cnameCnt, cnameLines = UI.fitTextEllipsis(c.name, UI.cjkFontSmall, cardW - 8,
                                                               cnameBottom - cnameY)
            for ni = 1, cnameCnt do
                love.graphics.printf(cnameLines[ni], cx + 4, cnameY + (ni - 1) * UI.cjkFontSmall:getHeight(), cardW - 8, "center")
            end

            -- Rider 显示可用次数
            if c.charges then
                love.graphics.setColor(1, 1, 0); love.graphics.setFont(UI.cjkFontSmall)
                love.graphics.printf("×" .. c.charges .. " 次", cx + 4, cardY + cardH * 0.78, cardW - 8, "center")
            end

            UI.addHoverTarget(c, cx, cardY, cardW, cardH)
            table.insert(UI._classSelectCards, { id = all[idx], x = cx, y = cardY, w = cardW, h = cardH })
        end
    end
end

-- ============================================================
-- 右上角职阶 icon（只有选了职阶才显示）
-- ============================================================
function UI.drawClassIcon(state)
    if not state.class then return end
    if state.state == "classSelect" then return end

    local Classes = pcall(require, "src.classes") and require("src.classes") or nil
    if not Classes then return end
    local cdef = Classes.get(state.class.id) or Classes.get(state.class)
    if not cdef then return end

    -- 放在桌面左上角筹码显示下方（避开侧栏遗物 + 设置按钮）
    local iw, ih = 42, 42
    local ix = 30       -- 筹码显示同 x（筹码在 (30, 30)）
    local iy = 70       -- 筹码显示下方 40px

    -- 背景
    local col = cdef.color or { 0.7, 0.7, 0.7 }
    love.graphics.setColor(col[1]*0.2, col[2]*0.2, col[3]*0.2, 0.95)
    love.graphics.rectangle("fill", ix, iy, iw, ih, 6)
    love.graphics.setColor(col[1], col[2], col[3], 0.95)
    love.graphics.setLineWidth(2); love.graphics.rectangle("line", ix+1, iy+1, iw-2, ih-2, 6); love.graphics.setLineWidth(1)

    -- 大 icon 字母
    love.graphics.setColor(col[1], col[2], col[3], 0.95)
    love.graphics.setFont(UI.cjkFontMid)
    love.graphics.printf(cdef.icon or cdef.name, ix, iy + 8, iw, "center")

    -- Rider 剩余次数小标
    if cdef.charges and (state.classCharges or 0) > 0 then
        love.graphics.setColor(1, 1, 0); love.graphics.setFont(UI.cjkFontSmall)
        love.graphics.printf("×" .. state.classCharges, ix, iy + 26, iw, "center")
    end

    -- 名字 label（icon 右边）
    love.graphics.setColor(col[1], col[2], col[3]); love.graphics.setFont(UI.cjkFontSmall)
    love.graphics.printf(cdef.name, ix + iw + 6, iy + 10, 80, "left")

    -- 注册 hover 目标（显示完整详情）
    UI.addHoverTarget({ kind = "class", desc = cdef.desc, name = cdef.name, color = col }, ix, iy, iw, ih)
end

-- 在 player 状态下点击遗物栏: 返回 {index=, relic=} 或 nil
-- 独立于 draw(), 用于 mousepressed 事件
-- 坐标公式必须和 drawRelics 完全一致（单一数据源）
function UI.hitTestRelicBar(mx, my, state)
    if not state or not state.relics or #state.relics == 0 then return nil end
    local sx = sidebar_x + 4

    -- 和 drawRelics 完全一致（含特种标记区 marksH 的预留）
    local topPadding = 10
    local bottomReserved = 96
    local infoH = 34
    local MAX_SLOTS = 5
    local gap = 4
    local nameH = 14
    local marksH = 58
    local availH = window_height - topPadding - bottomReserved - infoH - marksH - gap * 3
    local perSlotH = math.floor((availH - gap * (MAX_SLOTS - 1)) / MAX_SLOTS)
    local icon_h = math.max(30, perSlotH - nameH - 2)
    local iconStartY = topPadding

    if my < iconStartY or my > window_height - bottomReserved then return nil end

    for i, relic in ipairs(state.relics) do
        local iy = iconStartY + (i - 1) * (icon_h + gap)
        local top = iy - 8
        local h = icon_h + 18
        if mx >= sx + 2 and mx <= sx + sidebar_width - 10 and my >= top and my <= top + h then
            return { index = i, relic = relic }
        end
    end
    return nil
end

-- ============================================================
-- 特殊标记效果动画（数据由 GameState.markFx 写入，updateVisuals 到期清除）
--   vanish 灰白牌影上升消散 / void 紫色漩涡收缩 / bomb 红色冲击环
--   flame 金色火苗跳动（注意：绘制内禁用 love.math.random —— 会污染随机序列）
-- ============================================================
function UI.drawMarkFx(state)
    local fx = state._markFx
    if not fx then return end
    local t = love.timer.getTime() - fx.startAt
    local life = fx.life or 0.9
    if t >= life then return end
    local p = t / life          -- 0 → 1
    local w, h = love.graphics.getWidth(), love.graphics.getHeight()
    -- 锚点（比例布局：与牌桌牌堆 / 玩家手牌 / 庄家手牌的大致位置对齐）
    local ax, ay
    if fx.anchor == "hand" then ax, ay = w * 0.30, h * 0.60
    elseif fx.anchor == "dealer" then ax, ay = w * 0.30, h * 0.24
    else ax, ay = w * 0.27, h * 0.09 end

    if fx.kind == "vanish" then
        -- 灰白牌影上升淡出
        local a = (1 - p)
        love.graphics.setColor(0.92, 0.92, 0.88, a * 0.55)
        love.graphics.rectangle("fill", ax - 24, ay - 34 - p * 42, 48, 68, 5)
        love.graphics.setColor(0.55, 0.55, 0.55, a * 0.8)
        love.graphics.rectangle("line", ax - 24, ay - 34 - p * 42, 48, 68, 5)
        love.graphics.setFont(UI.cjkFontSmall)
        love.graphics.setColor(0.85, 0.85, 0.82, a)
        love.graphics.printf("消失", ax - 40, ay - 6 - p * 42, 80, "center")
    elseif fx.kind == "void" then
        -- 紫色漩涡：双环向内收缩 + 旋转粒子
        local r1 = 10 + (1 - p) * 44
        love.graphics.setColor(0.62, 0.32, 0.95, 0.85)
        love.graphics.setLineWidth(3)
        love.graphics.circle("line", ax, ay, r1)
        love.graphics.setColor(0.8, 0.55, 1, 0.7)
        love.graphics.setLineWidth(2)
        love.graphics.circle("line", ax, ay, r1 * 0.55)
        for i = 0, 5 do
            local ang = t * 7 + i * math.pi / 3
            local rr = r1 * (1 - 0.35 * p)
            love.graphics.circle("fill", ax + rr * math.cos(ang), ay + rr * math.sin(ang) * 0.6, 2.5)
        end
        love.graphics.setLineWidth(1)
    elseif fx.kind == "bomb" then
        -- 红色冲击环扩散 + 内圈闪光
        love.graphics.setColor(0.95, 0.18, 0.14, (1 - p) * 0.9)
        love.graphics.setLineWidth(4)
        love.graphics.circle("line", ax, ay, 12 + p * 58)
        love.graphics.setColor(1, 0.55, 0.3, (1 - p) * 0.5)
        love.graphics.circle("fill", ax, ay, 26 * (1 - p) + 6)
        love.graphics.setLineWidth(1)
    elseif fx.kind == "flame" then
        -- 金色火苗：三簇三角用时间函数抖动（不消耗随机源）
        for i = 0, 2 do
            local fx0 = ax + (i - 1) * 16
            local wob = math.sin(t * 18 + i * 2.1) * 4
            local fh = 26 + math.sin(t * 13 + i) * 6
            love.graphics.setColor(1, 0.78 + 0.1 * i, 0.15, (1 - p) * 0.85)
            love.graphics.polygon("fill",
                fx0 - 7, ay + 14,
                fx0 + 7, ay + 14,
                fx0 + wob, ay + 14 - fh)
        end
    end
    love.graphics.setColor(1, 1, 1)
end

-- ============================================================
-- 临时提示（"手牌已满"等）— 居中淡色条，2 秒自动消失
-- ============================================================
function UI.drawFlashMessage(state)
    local msg = state._flashMsg
    if not msg then return end
    local now = love.timer.getTime()
    if now > (msg.expires or 0) then
        state._flashMsg = nil
        return
    end
    -- Modal 打开时不显示（被 overlay 盖住）
    if state.settingsOpen or state.deckOverviewOpen then return end

    local w, h = love.graphics.getWidth(), love.graphics.getHeight()
    local barW = 360; local barH = 38
    local bx = (w - barW) / 2; local by = h * 0.45

    love.graphics.setColor(0.15, 0.05, 0.05, 0.92)
    love.graphics.rectangle("fill", bx, by, barW, barH, 6)
    love.graphics.setColor(0.85, 0.2, 0.2, 0.9)
    love.graphics.setLineWidth(2); love.graphics.rectangle("line", bx, by, barW, barH, 6)

    love.graphics.setFont(UI.cjkFont); love.graphics.setColor(1, 0.7, 0.7)
    love.graphics.printf(msg.text, bx, by + 8, barW, "center")
end

function UI.drawTooltip(state)
    if not UI._hoverTargets then return end

    local mx, my = love.mouse.getPosition()
    local hovered = UI.getHoverTargetAt(mx, my)
    UI._hoverTargets = nil

    if not hovered then return end

    local pad = 10; local lineH = 20
    local tw, th, lines, borderR, borderG, borderB, titleColor

    if hovered.kind == "class" then
        -- ===== 职阶 =====
        lines = { hovered.name or "", hovered.desc or "" }
        borderR, borderG, borderB = unpack(hovered.color or {0.8, 0.8, 0.8})
        titleColor = { borderR, borderG, borderB }
    elseif hovered.kind == "barCup" then
        -- ===== 酒吧模式 · 一款酒（调酒栏 / 醉酒倒计时区共用）=====
        local def = Cocktails.getById(hovered.barId)
        if not def then return end
        local turns = Cocktails.turnsLeft(state, def.id)
        lines = { def.name, def.desc }
        if hovered.cup then
            table.insert(lines, "剩余 " .. Cocktails.poursLeft(hovered.cup)
                                .. " / " .. Cocktails.POURS_PER_CUP .. " 口")
        end
        if turns > 0 then table.insert(lines, "被动剩余 " .. turns .. " 回合") end
        borderR, borderG, borderB = unpack(def.color)
        titleColor = { borderR, borderG, borderB }
    elseif hovered.typeKey then
        -- ===== 牌组 offer =====
        local DeckTypes = require("src.deck_types")
        local tpl = DeckTypes.TYPES[hovered.typeKey]
        local size = DeckTypes.SIZES[hovered.sizeKey]
        local color = hovered.color or {1, 0.85, 0.2}

        local shownDeckPrice = hovered._shopPrice or hovered.price
        local deckPriceTag = (hovered._shopPrice and hovered.price and hovered._shopPrice < hovered.price)
                             and (" (" .. math.floor(state._shopDiscount.rate * 10 + 0.5) .. "折)") or ""
        lines = { hovered.name,
                 "牌组 | $" .. shownDeckPrice .. deckPriceTag .. " | " .. size.count .. " 张",
                 tpl.desc }
        borderR, borderG, borderB = 1, 0.85, 0.2   -- 牌组统一黄色
        titleColor = {1, 0.85, 0.2}

        -- 如果牌组有特殊牌细节，展开每行描述
        local sampleCards = DeckTypes.generate(hovered.typeKey, hovered.sizeKey)
        local detail = ""
        local kinds = {}
        for _, c in ipairs(sampleCards) do
            if not kinds[c.kind] then kinds[c.kind] = true end
        end
        if hovered.typeKey == "decimal"    then detail = "所有牌点数为小数 (如 2.5, 7.5)"
        elseif hovered.typeKey == "negative" then detail = "所有牌点数为负数 (如 -3, -8)"
        elseif hovered.typeKey == "multiplier" then detail = "所有牌附带 +0.5x 倍率加成 (赢牌时生效)"
        elseif hovered.typeKey == "s67" then detail = "一半是 6，一半是 7。\n同时持 67 卡组的 6 和 7 → 填满到 12 张且不会爆，直接判赢 ×67 倍率"
        elseif hovered.typeKey == "rps" then detail = "三等分石头/剪刀/布，默认点数 0。\n玩家和庄家各有且仅有一张 RPS → 按石头剪刀布判定输赢（平局算玩家赢）"
        elseif hovered.typeKey == "remove" then detail = "从固有牌堆删除 " .. (hovered.removeDecks or 1) .. " 套标准扑克。\n固有牌堆原本 6 套，不能删到 0。"
        end
        if detail ~= "" then table.insert(lines, detail) end
        if hovered.typeKey == "remove" then
            table.insert(lines, "立即生效，减少固有牌堆套数")
        else
            table.insert(lines, "永久注入牌堆，不可移除")
        end

    elseif hovered._markTip then
        -- ===== 特种标记（遗物栏标记区）：显示具体功能与使用情况 =====
        local lib = Relics.getById(hovered.markId)
        if not lib then return end
        local usesLine
        if hovered.forged then
            usesLine = "永久生效（∞ 次）· 每回合限 1 次"
        else
            usesLine = "剩余 " .. (hovered.uses or 0) .. " 次 · 每回合限 1 次"
            if state._specialMarkUsedRound then usesLine = usesLine .. "（本回合已用）" end
        end
        lines = { lib.name, usesLine, lib.desc }
        borderR, borderG, borderB = unpack(lib.markDot or {0.7, 0.4, 1})
        titleColor = { borderR, borderG, borderB }

    else
        -- ===== 遗物 =====
        local displayPrice = hovered.price
        if state.state == "shop" and hovered.price then
            displayPrice = Relics.getStagePrice(hovered, state.stage)
        end
        if state.state == "shop" and hovered._shopPrice then
            displayPrice = hovered._shopPrice   -- 打折位：显示折后价（buyRelic 扣的就是这个数）
        end
        local rarityTag = hovered.rarity and ("[" .. hovered.rarity .. "]") or ""
        local priceTag = displayPrice and (" $" .. displayPrice) or ""

        lines = { hovered.name,
                  rarityTag .. priceTag,
                  hovered.desc }
        borderR, borderG, borderB = unpack(Relics.getRarityColor(hovered.rarity or "common"))
        titleColor = {borderR, borderG, borderB}
    end

    -- 计算 tooltip 尺寸（正确处理自动换行 + \n）
    love.graphics.setFont(UI.cjkFontSmall)
    local tw = 280   -- 固定面板宽度，够大部分描述
    local th = pad * 2 + 8

    -- 第一行：标题（用大字体测）
    local titleLines, titleCount = UI.wrapAndMeasure(lines[1] or "", UI.cjkFont, tw - pad * 2)
    th = th + titleCount * (lineH + 4)

    -- 第二行：类型/价格
    local l2Lines, l2Count = UI.wrapAndMeasure(lines[2] or "", UI.cjkFontSmall, tw - pad * 2)
    th = th + l2Count * lineH

    -- 后续：描述（逐行 \n 展开 + 自动换行）
    local descTotalLines = 0
    for li = 3, #lines do
        local _, wc = UI.wrapAndMeasure(lines[li], UI.cjkFontSmall, tw - pad * 2)
        descTotalLines = descTotalLines + wc
    end
    th = th + descTotalLines * lineH

    -- 位置（避开右边/下边越界）
    local tx = mx + 15; local ty = my + 15
    if tx + tw > love.graphics.getWidth() then tx = mx - tw - 15 end
    if ty + th > love.graphics.getHeight() then ty = love.graphics.getHeight() - th - 5 end

    -- 背景框
    love.graphics.setColor(0, 0, 0, 0.94)
    love.graphics.rectangle("fill", tx, ty, tw, th, 4)
    love.graphics.setColor(borderR, borderG, borderB, 0.95)
    love.graphics.setLineWidth(2)
    love.graphics.rectangle("line", tx, ty, tw, th, 4)
    love.graphics.setLineWidth(1)

    -- 第一行：标题（可多行）
    love.graphics.setColor(unpack(titleColor))
    UI.drawWrappedText(lines[1] or "", UI.cjkFont, tx + pad, ty + pad, tw - pad * 2, lineH + 4, nil, "center")

    -- 第二行：类型/价格
    UI.drawWrappedText(lines[2] or "", UI.cjkFontSmall, tx + pad, ty + pad + (lineH + 4) * titleCount, tw - pad * 2, lineH, {0.85, 0.85, 0.85}, "center")

    -- 后续：描述
    local curY = ty + pad + (lineH + 4) * titleCount + lineH * l2Count
    love.graphics.setColor(0.92, 0.92, 0.92)
    for li = 3, #lines do
        local _, wc = UI.wrapAndMeasure(lines[li], UI.cjkFontSmall, tw - pad * 2)
        love.graphics.printf(lines[li], tx + pad, curY, tw - pad * 2, "left")
        curY = curY + wc * lineH
    end
end

-- ============================================================
-- 设置页（ESC 打开）
-- ============================================================
function UI.drawSettingsOverlay(state)
    if not state.settingsOpen then return end

    local w, h = love.graphics.getWidth(), love.graphics.getHeight()
    local s = state.settings or {}
    UI._settingsBtns = {}

    -- 遮罩
    love.graphics.setColor(0, 0, 0, 0.7)
    love.graphics.rectangle("fill", 0, 0, w, h)

    -- ========== 第一遍：计算内容高度 ==========
    -- 先用临时 ly 算出 totalHeight，然后再画一遍（弹窗尺寸完全自适应内容）
    local function calcHeight()
        local ly = 0
        ly = ly + 44 + 20   -- header + gap
        ly = ly + 50        -- 音量 section
        -- 分辨率 2×2 grid
        local gridRows = 2
        local resH = 30; local gridRowH = resH + 10
        ly = ly + gridRows * gridRowH + 20   -- 2 行按钮 + gap
        ly = ly + 40        -- 全屏 section
        ly = ly + 70        -- 货币耗尽 section (toggle + hint 两行)
        ly = ly + 62        -- 存档 section (label + 重置按钮 + hint 两行)
        ly = ly + 50        -- 底部按钮行
        ly = ly + 30        -- 底部 padding
        return ly
    end

    local pw = 560
    local contentH = calcHeight()
    local ph = math.min(contentH + 30, h - 40)   -- 弹窗高度自适应，上限窗口-40
    ph = math.max(ph, 380)                       -- 最小 380
    local px = (w - pw) / 2; local py = math.max(20, (h - ph) / 2)

    -- 弹窗
    love.graphics.setColor(0.1, 0.1, 0.15, 0.98)
    love.graphics.rectangle("fill", px, py, pw, ph, 10)
    love.graphics.setColor(1, 0.85, 0.2)
    love.graphics.setLineWidth(2); love.graphics.rectangle("line", px, py, pw, ph, 10); love.graphics.setLineWidth(1)

    -- 标题
    local headerH = 44
    love.graphics.setColor(0.18, 0.13, 0.05, 1)
    love.graphics.rectangle("fill", px, py, pw, headerH, 10, 10, 0, 0)
    love.graphics.setColor(1, 0.85, 0.2); love.graphics.setFont(UI.cjkFontMid)
    love.graphics.printf("设置  [ESC 关闭]", px, py + 12, pw, "center")

    local ly = py + headerH + 20

    -- ========== 通用：单行 label + control helper ==========
    -- 左侧 label 在 (px+30, ly) ，control 在右侧，底部 = ly + controlH
    local LABEL_X = px + 30
    local LABEL_W = 150   -- label 区域宽度
    local LABEL_H = 26    -- label 行高
    local function drawLabel(text, curLy)
        love.graphics.setFont(UI.cjkFont); love.graphics.setColor(1, 1, 1)
        love.graphics.print(text, LABEL_X, curLy)
    end

    -- ========== 音量 ==========
    drawLabel("音量", ly)
    local volW = 260; local volH = 18
    local volX = px + LABEL_W + 10; local volY = ly + 4
    love.graphics.setColor(0.25, 0.25, 0.3)
    love.graphics.rectangle("fill", volX, volY, volW, volH, 4)
    love.graphics.setColor(1, 0.85, 0.2)
    local volFill = volW * s.volume
    love.graphics.rectangle("fill", volX, volY, volFill, volH, 4)
    love.graphics.setColor(1, 1, 1)
    love.graphics.rectangle("fill", volX + volFill - 4, volY - 3, 8, volH + 6, 2)
    love.graphics.setFont(UI.cjkFontSmall); love.graphics.setColor(0.85, 0.85, 0.85)
    love.graphics.printf(math.floor(s.volume * 100) .. "%", volX + volW + 12, volY, 50, "left")

    table.insert(UI._settingsBtns, {
        x = volX, y = volY - 4, w = volW, h = volH + 8,
        onClick = function()
            local mx = love.mouse.getX()
            local ratio = math.max(0, math.min(1, (mx - volX) / volW))
            state.settings.volume = ratio
            if love.audio and love.audio.setVolume then love.audio.setVolume(ratio) end
            if BGM and BGM.setVolume then BGM.setVolume(ratio) end
            Persist.saveProgress(state)   -- 设置项属于游玩记录，改动即写盘（事件驱动）
        end,
    })
    ly = ly + LABEL_H + 20   -- ← 动态前进（label 行 + section 间 gap）

    -- ========== 分辨率 2×2 grid ==========
    drawLabel("分辨率", ly)
    local resW = 220; local resH = 30; local resGap = 16
    local gridCols = 2
    local gridRows = math.ceil(#UI.RESOLUTIONS / gridCols)
    local gridTotalW = resW * gridCols + resGap * (gridCols - 1)
    local gridStartX = px + (pw - gridTotalW) / 2
    local gridRowH = resH + 10

    for i, res in ipairs(UI.RESOLUTIONS) do
        local col = (i - 1) % gridCols
        local row = math.floor((i - 1) / gridCols)
        local rx = gridStartX + col * (resW + resGap)
        local ry = ly + 4 + row * gridRowH   -- label 下方开始

        local selected = (state.settings.resolutionIndex or 1) == i
        love.graphics.setColor(selected and {1, 0.85, 0.2} or {0.35, 0.35, 0.4})
        love.graphics.rectangle("fill", rx, ry, resW, resH, 4)
        love.graphics.setColor(selected and {0, 0, 0} or {0.85, 0.85, 0.85})
        love.graphics.setFont(UI.cjkFontSmall)
        love.graphics.printf(res.label, rx, ry + 7, resW, "center")

        table.insert(UI._settingsBtns, {
            x = rx, y = ry, w = resW, h = resH,
            onClick = function()
                state.settings.resolutionIndex = i
                local fullscreen = state.settings.fullscreen
                if love.window and love.window.setMode then
                    love.window.setMode(res.w, res.h, { fullscreen = fullscreen, resizable = true })
                    UI.refreshLayout()
                end
                Persist.saveProgress(state)   -- 分辨率属于游玩记录，改动即写盘
            end,
        })
    end
    ly = ly + LABEL_H + gridRows * gridRowH + 10   -- ← 精确：label + grid 总高 + 间隙

    -- ========== 全屏 toggle ==========
    drawLabel("全屏", ly)
    local fsW = 60; local fsH = 26; local fsX = px + LABEL_W + 10; local fsY = ly + 4
    local fsOn = state.settings.fullscreen == true
    love.graphics.setColor(fsOn and {0.2, 0.75, 0.2} or {0.35, 0.35, 0.4})
    love.graphics.rectangle("fill", fsX, fsY, fsW, fsH, 4)
    love.graphics.setColor(0, 0, 0); love.graphics.setFont(UI.cjkFontSmall)
    love.graphics.printf(fsOn and "ON" or "OFF", fsX, fsY + 5, fsW, "center")

    table.insert(UI._settingsBtns, {
        x = fsX, y = fsY, w = fsW, h = fsH,
        onClick = function()
            state.settings.fullscreen = not state.settings.fullscreen
            local res = UI.RESOLUTIONS[state.settings.resolutionIndex or 1]
            if love.window and love.window.setMode then
                love.window.setMode(res.w, res.h, { fullscreen = state.settings.fullscreen, resizable = true })
                UI.refreshLayout()
            end
            Persist.saveProgress(state)   -- 全屏属于游玩记录，改动即写盘
        end,
    })
    ly = ly + LABEL_H + 20

    -- ========== 失败是否踢出游戏（原"货币耗尽自动退出"：功能已扩为失败判负统一开关）==========
    drawLabel("失败是否踢出游戏", ly)
    local aeW = 60; local aeH = 26; local aeX = px + LABEL_W + 10; local aeY = ly + 4
    local aeOn = state.settings.autoEndOnBroke ~= false
    love.graphics.setColor(aeOn and {0.2, 0.75, 0.2} or {0.35, 0.35, 0.4})
    love.graphics.rectangle("fill", aeX, aeY, aeW, aeH, 4)
    love.graphics.setColor(0, 0, 0); love.graphics.setFont(UI.cjkFontSmall)
    love.graphics.printf(aeOn and "ON" or "OFF", aeX, aeY + 5, aeW, "center")

    love.graphics.setFont(UI.cjkFontSmall); love.graphics.setColor(0.6, 0.6, 0.6)
    love.graphics.printf("关闭后失败（含筹码耗尽、标记致贫）不踢出，可赊账继续游玩", px + 30, ly + LABEL_H + 2, pw - 60, "left")

    table.insert(UI._settingsBtns, {
        x = aeX, y = aeY, w = aeW, h = aeH,
        onClick = function()
            state.settings.autoEndOnBroke = not aeOn
            Persist.saveProgress(state)   -- 设置项改动即写盘
        end,
    })
    ly = ly + LABEL_H + 32   -- toggle + hint 两行

    -- ========== 存档：重置（删除 saves21 目录） ==========
    -- 破坏性操作：两步确认（第一次点击只进入确认态，第二次才真正删除）
    drawLabel("存档", ly)
    local rsW = 190; local rsH = 32; local rsX = px + LABEL_W + 10; local rsY = ly + 2
    local resetConfirm = type(state._resetSaveConfirm) == "number"
                         and love.timer.getTime() < state._resetSaveConfirm
    love.graphics.setColor(resetConfirm and {0.85, 0.2, 0.2} or {0.5, 0.16, 0.16})
    love.graphics.rectangle("fill", rsX, rsY, rsW, rsH, 5)
    love.graphics.setColor(1, 0.9, 0.9); love.graphics.setFont(UI.cjkFontSmall)
    love.graphics.printf(resetConfirm and "再次点击确认重置" or "重置存档",
                         rsX, rsY + 8, rsW, "center")

    love.graphics.setFont(UI.cjkFontSmall)
    love.graphics.setColor(resetConfirm and {1, 0.6, 0.6} or {0.6, 0.6, 0.6})
    love.graphics.printf(resetConfirm and "确认状态：再次点击将立即清空全部存档（不可恢复）"
                                      or "删除 saves21 目录：通关记录 / 最高记录 / 冠军牌组 全部清空",
                         px + 30, ly + LABEL_H + 2, pw - 60, "left")

    table.insert(UI._settingsBtns, {
        x = rsX, y = rsY, w = rsW, h = rsH,
        onClick = function()
            if state._resetSaveConfirm then
                state._resetSaveConfirm = nil
                Persist.reset(state)
                state.settingsOpen = false
                state.state = "title"
                state._flashMsg = {
                    text = "存档已重置：游玩记录与冠军牌组已清空",
                    expires = love.timer.getTime() + 2.5,
                }
            else
                -- 5 秒内再次点击才生效（避免误触直接清空存档）
                state._resetSaveConfirm = love.timer.getTime() + 5
            end
        end,
    })
    ly = ly + LABEL_H + 32

    -- ========== 返回主界面 + 关闭 ==========
    local backW = 160; local backH = 40; local backX = px + 30; local backY = ly
    love.graphics.setColor(0.5, 0.35, 0.15)
    love.graphics.rectangle("fill", backX, backY, backW, backH, 5)
    love.graphics.setColor(1, 0.85, 0.2); love.graphics.setFont(UI.cjkFont)
    love.graphics.printf("返回主界面", backX, backY + 10, backW, "center")

    table.insert(UI._settingsBtns, {
        x = backX, y = backY, w = backW, h = backH,
        onClick = function()
            state.settingsOpen = false
            state.state = "title"
        end,
    })

    local closeW = 120; local closeH = 40; local closeX = px + pw - closeW - 30; local closeY = ly
    love.graphics.setColor(0.4, 0.4, 0.4)
    love.graphics.rectangle("fill", closeX, closeY, closeW, closeH, 5)
    love.graphics.setColor(1, 1, 1); love.graphics.setFont(UI.cjkFont)
    love.graphics.printf("关闭 [ESC]", closeX, closeY + 10, closeW, "center")

    table.insert(UI._settingsBtns, {
        x = closeX, y = closeY, w = closeW, h = closeH,
        onClick = function() state.settingsOpen = false end,
    })

    UI._settingsArea = { x = px, y = py, w = pw, h = ph }
end

-- ============================================================
-- 牌堆总览弹窗（按 D 键随时打开，枚举当前牌堆里每一种具体牌）
-- ============================================================
function UI.drawDeckOverviewOverlay(state)
    if not state.deckOverviewOpen then return end

    local w, h = love.graphics.getWidth(), love.graphics.getHeight()
    local deck = state.deck
    if not deck or not deck.cards then return end

    -- 1. 统计：每种 (kind + is_blackhole + suit + rank) 出现多少次
    local counts = {}   -- key = "kind|bh|suit|rank"
    for _, c in ipairs(deck.cards) do
        local bh = c.is_blackhole and "bh" or "ok"
        local key = (c.kind or "normal") .. "|" .. bh .. "|" .. (c.suit or "?") .. "|" .. tostring(c.rank)
        if not counts[key] then
            counts[key] = { suit = c.suit, rank = c.rank, kind = c.kind or "normal",
                            is_blackhole = c.is_blackhole == true,
                            is_cage = c.is_cage == true,
                            is_chip = c.is_chip == true, count = 0 }
        end
        counts[key].count = counts[key].count + 1
    end

    -- 2. 排序：先按 kind (normal 排最前)，再按 suit (♠♥♦♣)，再按 rank
    local rankOrder = { A = 1, ['2'] = 2, ['3'] = 3, ['4'] = 4, ['5'] = 5, ['6'] = 6, ['7'] = 7,
                        ['8'] = 8, ['9'] = 9, ['10'] = 10, J = 11, Q = 12, K = 13 }
    local suitOrder = { ['\u{2660}'] = 1, ['\u{2665}'] = 2, ['\u{2666}'] = 3, ['\u{2663}'] = 4 }
    local kindOrder = { normal = 1, decimal = 2, negative = 3, multiplier = 4, s67 = 5, blackhole = 6, rps = 7, cage = 8, chip = 9 }
    -- 黑洞牌要单独计（is_blackhole=true 标识，不是 kind）
    for _, c in ipairs(deck.cards) do
        if c.is_blackhole then kindOrder["_bh_" .. (c.kind or "normal")] = 10 end
    end

    local sorted = {}
    for _, entry in pairs(counts) do table.insert(sorted, entry) end
    table.sort(sorted, function(a, b)
        local ka = kindOrder[a.kind] or 10; local kb = kindOrder[b.kind] or 10
        if ka ~= kb then return ka < kb end
        local sa = suitOrder[a.suit] or 9; local sb = suitOrder[b.suit] or 9
        if sa ~= sb then return sa < sb end
        -- rank 可能是数字字符串或字母
        local ra = rankOrder[tostring(a.rank)] or tonumber(a.rank) or 99
        local rb = rankOrder[tostring(b.rank)] or tonumber(b.rank) or 99
        return ra < rb
    end)

    local totalCards = #deck.cards

    -- 3. 弹窗（高度不超过窗口 - 20，否则 800x600 下底栏会被裁掉）
    local pw = 700; local ph = math.min(600, h - 20)
    local px = (w - pw) / 2; local py = math.max(10, (h - ph) / 2 - 40)

    -- 遮罩
    love.graphics.setColor(0, 0, 0, 0.6)
    love.graphics.rectangle("fill", 0, 0, w, h)

    -- 弹窗框
    love.graphics.setColor(0.08, 0.08, 0.14, 0.97)
    love.graphics.rectangle("fill", px, py, pw, ph, 10)
    love.graphics.setColor(1, 0.85, 0.2, 0.9)
    love.graphics.setLineWidth(2); love.graphics.rectangle("line", px, py, pw, ph, 10); love.graphics.setLineWidth(1)

    -- 标题栏
    local headerH = 44
    love.graphics.setColor(0.18, 0.13, 0.05, 1)
    love.graphics.rectangle("fill", px, py, pw, headerH, 10, 10, 0, 0)
    love.graphics.setColor(1, 0.85, 0.2); love.graphics.setFont(UI.cjkFontMid)
    love.graphics.printf("牌堆总览  " .. #sorted .. " 种 · 抽 " .. totalCards .. " · 弃 " .. #(deck.discardPile or {}) .. "  [D/ESC 关闭]",
                         px, py + 12, pw, "center")

    -- 4. 列表区 —— 三列多行布局（底部留 64px：提示行 + 关闭钮各占一行互不压叠）
    local listTopY = py + headerH + 8
    local listBotY = py + ph - 64
    local listH = listBotY - listTopY

    local COLS = 3
    local colGap = 10; local listPadX = 12
    local colW = (pw - listPadX * 2 - colGap * (COLS - 1)) / COLS

    -- 卡牌缩略图：保持 UI.card.width:UI.card.height 比例（2:3），缩小到 40x60
    local CARD_TINY_W = 40
    local CARD_TINY_H = 60
    local cardRowH = 78  -- 每行高度 = 缩略图 + 文字间距

    local totalRows = math.ceil(#sorted / COLS)
    local scrollAmt = state.deckOverviewScroll or 0
    local rowsInView = math.max(1, math.floor(listH / cardRowH))
    local maxScroll = math.max(0, totalRows - rowsInView)
    scrollAmt = math.min(scrollAmt, maxScroll)
    scrollAmt = math.max(0, scrollAmt)
    state.deckOverviewScroll = scrollAmt

    -- Scissor clip：滚动时卡面不会顶破 header / 溢出底部
    love.graphics.setScissor(px, listTopY, pw, listH)

    -- 绘制每个"行"（每行 = 3 种牌横向排列）
    for row = 0, totalRows - 1 do
        local rowY = listTopY + (row - scrollAmt) * cardRowH
        if rowY + cardRowH >= listTopY - 2 and rowY <= listBotY then

            -- 背景（隔行交替，整行横跨 3 列）
            if row % 2 == 0 then
                love.graphics.setColor(0.11, 0.11, 0.17, 0.85)
                love.graphics.rectangle("fill", px + listPadX, rowY, pw - listPadX * 2, cardRowH - 4, 3)
            end

            -- 这一行里的 3 种
            for col = 0, COLS - 1 do
                local idx = row * COLS + col + 1
                if idx > #sorted then break end  -- 最后一行可能不足 3 种

                local entry = sorted[idx]
                local cx = px + listPadX + col * (colW + colGap)
                local cy = rowY + 8

                -- 花色颜色
                local suitIsRed = (entry.suit == '\u{2665}' or entry.suit == '\u{2666}')
                local bgColor, fgColor
                if entry.is_blackhole then       -- 黑洞牌（优先）
                    bgColor, fgColor = {0.03, 0.03, 0.06}, {0.9, 0.9, 0.9}
                elseif entry.kind == "decimal"      then bgColor, fgColor = {0.12, 0.28, 0.12}, {0.3, 0.85, 0.3}
                elseif entry.kind == "negative" then bgColor, fgColor = {0.3, 0.1, 0.1}, {0.9, 0.3, 0.3}
                elseif entry.kind == "multiplier" then bgColor, fgColor = {0.3, 0.22, 0.05}, {0.95, 0.75, 0.2}
                elseif entry.kind == "s67" then bgColor, fgColor = {0.22, 0.1, 0.3}, {0.6, 0.3, 0.9}
                elseif entry.kind == "blackhole" then bgColor, fgColor = {0.03, 0.03, 0.06}, {0.9, 0.9, 0.9}
                elseif entry.kind == "cage" then bgColor, fgColor = {0.20, 0.19, 0.18}, {0.78, 0.75, 0.70}
                elseif entry.kind == "chip" then bgColor, fgColor = {0.28, 0.10, 0.10}, {0.90, 0.35, 0.35}
                elseif entry.kind == "dice6" then bgColor, fgColor = {0.26, 0.26, 0.24}, {0.95, 0.95, 0.92}
                elseif entry.kind == "dice20" then bgColor, fgColor = {0.09, 0.26, 0.24}, {0.30, 0.88, 0.80}
                else
                    bgColor = {0.18, 0.18, 0.24}
                    fgColor = suitIsRed and {0.9, 0.2, 0.2} or {0.92, 0.92, 0.92}
                end

                -- 等比缩略图 (CARD_TINY_W × CARD_TINY_H，2:3)
                local tx = cx + 6; local ty = cy + 4
                love.graphics.setColor(unpack(bgColor))
                love.graphics.rectangle("fill", tx, ty, CARD_TINY_W, CARD_TINY_H, 4)
                -- 黑洞牌加黑色边框
                if entry.is_blackhole or entry.kind == "blackhole" then
                    love.graphics.setColor(0, 0, 0)
                    love.graphics.setLineWidth(2)
                    love.graphics.rectangle("line", tx - 1, ty - 1, CARD_TINY_W + 2, CARD_TINY_H + 2, 4)
                    love.graphics.setLineWidth(1)
                end
                -- 牢笼牌加铁色边框 + 竖杠
                if entry.is_cage or entry.kind == "cage" then
                    love.graphics.setColor(0.45, 0.42, 0.40)
                    love.graphics.setLineWidth(2)
                    love.graphics.rectangle("line", tx - 1, ty - 1, CARD_TINY_W + 2, CARD_TINY_H + 2, 4)
                    for i = 1, 3 do
                        local bx = tx + CARD_TINY_W * i / 4
                        love.graphics.line(bx, ty + 1, bx, ty + CARD_TINY_H - 1)
                    end
                    love.graphics.setLineWidth(1)
                end
                -- 筹码牌加红黑相间边框（首参是左上角，不能传缩略图中心，否则偏半张卡身）
                if entry.is_chip or entry.kind == "chip" then
                    UI.drawChipMarks(tx, ty, CARD_TINY_W, CARD_TINY_H, 1)
                end
                love.graphics.setColor(unpack(fgColor))
                love.graphics.setLineWidth(1)
                love.graphics.rectangle("line", tx + 0.5, ty + 0.5, CARD_TINY_W - 1, CARD_TINY_H - 1, 4)
                love.graphics.setFont(UI.font)
                love.graphics.printf(tostring(entry.rank), tx, ty + 8, CARD_TINY_W, "center")
                love.graphics.printf(entry.suit, tx, ty + 30, CARD_TINY_W, "center")

                -- 名称 + 数量（在卡右侧或下方）
                love.graphics.setFont(UI.cjkFontSmall); love.graphics.setColor(1, 1, 1)
                local nameLabel = UI.fitTextEllipsis(entry.suit .. " " .. tostring(entry.rank),
                    UI.cjkFontSmall, colW - CARD_TINY_W - 10, UI.cjkFontSmall:getHeight())
                love.graphics.printf(nameLabel, tx + CARD_TINY_W + 4, cy + 4, colW - CARD_TINY_W - 10, "left")

                -- 数量
                love.graphics.setFont(UI.cjkFontMid); love.graphics.setColor(unpack(fgColor))
                local countLabel = UI.fitTextEllipsis("x " .. entry.count,
                    UI.cjkFontMid, colW - CARD_TINY_W - 10, UI.cjkFontMid:getHeight())
                love.graphics.printf(countLabel, tx + CARD_TINY_W + 4, cy + 20, colW - CARD_TINY_W - 10, "left")

                -- Kind tag（右下）
                local kindLabel
                if entry.is_blackhole then
                    kindLabel = "黑洞"
                else
                    kindLabel = entry.kind == "decimal" and "小数" or
                                entry.kind == "negative" and "负数" or
                                entry.kind == "multiplier" and "倍率" or
                                entry.kind == "s67" and "67" or
                                entry.kind == "blackhole" and "黑洞牌" or
                                entry.kind == "cage" and "牢笼" or
                                entry.kind == "chip" and "筹码" or
                                entry.kind == "dice6" and "六面骰" or
                                entry.kind == "dice20" and "二十面骰" or
                                entry.kind == "rps" and "RPS" or "标准"
                end
                local tagColor = entry.kind == "normal" and {0.55, 0.55, 0.55} or fgColor
                love.graphics.setFont(UI.cjkFontSmall)
                love.graphics.setColor(unpack(tagColor))
                local tagShown = UI.fitTextEllipsis("[" .. kindLabel .. "]",
                    UI.cjkFontSmall, colW - CARD_TINY_W - 10, UI.cjkFontSmall:getHeight())
                love.graphics.printf(tagShown, tx + CARD_TINY_W + 4, cy + 40, colW - CARD_TINY_W - 10, "left")
            end
        end
    end

    -- 恢复全局 scissor
    love.graphics.setScissor()

    -- 5. 滚动条（位置不变，但高度计算基于 rowsInView）
    if totalRows > rowsInView then
        local sbH = math.max(18, (rowsInView / totalRows) * rowsInView * cardRowH)
        local sbY = listTopY + (scrollAmt / math.max(1, totalRows - rowsInView)) * (rowsInView * cardRowH - sbH)
        love.graphics.setColor(0.25, 0.25, 0.25)
        love.graphics.rectangle("fill", px + pw - 14, listTopY, 6, rowsInView * cardRowH, 3)
        love.graphics.setColor(0.75, 0.75, 0.75)
        love.graphics.rectangle("fill", px + pw - 14, sbY, 6, sbH, 3)
    end

    -- 底部统计行（左对齐，独占一行；与关闭钮分行，杜绝压叠）
    love.graphics.setFont(UI.cjkFontSmall); love.graphics.setColor(0.6, 0.6, 0.6)
    local hintShown = UI.fitTextEllipsis("滚轮 / 上下键 / PageUp PageDown 滚动   |   当前抽牌堆剩余 " .. totalCards .. " 张 · 弃牌堆 " .. #(deck.discardPile or {}) .. " 张",
        UI.cjkFontSmall, pw - 24, UI.cjkFontSmall:getHeight())
    love.graphics.printf(hintShown, px + 12, py + ph - 52, pw - 24, "left")

    -- 关闭按钮（最底行居中）
    local btnY = py + ph - 28; local btnW = 110; local btnH = 24
    love.graphics.setColor(0.45, 0.45, 0.45)
    love.graphics.rectangle("fill", px + pw / 2 - btnW / 2, btnY, btnW, btnH, 4)
    love.graphics.setColor(1, 1, 1); love.graphics.setFont(UI.cjkFontSmall)
    love.graphics.printf("关闭 [D]", px + pw / 2 - btnW / 2, btnY + 4, btnW, "center")

    -- 暴露按钮和弹窗区域给 main.lua
    UI._deckOverviewCloseBtn = { x = px + pw / 2 - btnW / 2, y = btnY, w = btnW, h = btnH }
    UI._deckOverviewArea = { x = px, y = py, w = pw, h = ph }
end

-- 玩家标记的桌面记号：右下角纯色小点（真实出千记号的还原——只有玩家知道含义）
-- 不同标记类型用不同颜色：墨水=橙 / 消失=灰白 / 爆炸=红 / 火焰=金 / 虚空=紫 / 赏金=绿
local MARK_COLORS = {
    ink    = { 1, 0.62, 0.10 },
    vanish = { 0.75, 0.75, 0.80 },
    bomb   = { 0.95, 0.15, 0.15 },
    flame  = { 1, 0.85, 0 },
    void   = { 0.6, 0.3, 0.95 },
    bounty = { 0.2, 0.9, 0.3 },
}
UI.MARK_COLORS = MARK_COLORS

function UI.drawCardMark(card, r, mark)
    if not card or not r then return end
    local col = MARK_COLORS[(mark and mark.kind) or "ink"] or MARK_COLORS.ink
    love.graphics.setColor(col[1], col[2], col[3], 0.95)
    love.graphics.circle("fill", r.x + r.w - 7, r.y + r.h - 7, 4)
    love.graphics.setColor(0.15, 0.10, 0.02, 0.9)
    love.graphics.circle("line", r.x + r.w - 7, r.y + r.h - 7, 4)
    love.graphics.setColor(1, 1, 1)
end

-- ============================================================
-- 牌靴情报面板（模态，I 键 / 桌面「情报」按钮打开）
--   长矩形牌框：上半 = 顺序带（接下来 K 张：窥视明牌 / 牌背"?"），
--              下半 = 构成栏（13 点数 + 不定值"?"列）+ 爆率行 + 弃牌堆行
--   未知 = 问号（用户规范）；写不下进子页（阶段2 标签台账），本面板永不滚动
--   热区: UI._shoeInfoCloseBtn / UI._shoeInfoArea（main.lua 同源读取）
-- ============================================================
function UI.drawShoeInfoOverlay(state)
    if not state._shoeInfoOpen then return end
    local w, h = love.graphics.getWidth(), love.graphics.getHeight()
    local deck = state.deck
    if not deck or not deck.cards then return end

    local pw = math.min(840, w - 40)
    local ph = math.min(376, h - 50)   -- 内容实际高度：不留大段空白
    local px = math.floor((w - pw) / 2)
    local py = math.floor((h - ph) / 2)

    -- 遮罩 + 面板框（青色系，与深蓝牌堆/金框总览区分）
    love.graphics.setColor(0, 0, 0, 0.6)
    love.graphics.rectangle("fill", 0, 0, w, h)
    love.graphics.setColor(0.06, 0.10, 0.12, 0.97)
    love.graphics.rectangle("fill", px, py, pw, ph, 10)
    love.graphics.setColor(0.35, 0.85, 0.78, 0.9)
    love.graphics.setLineWidth(2); love.graphics.rectangle("line", px, py, pw, ph, 10); love.graphics.setLineWidth(1)

    -- 标题栏
    love.graphics.setColor(0.05, 0.16, 0.15, 1)
    love.graphics.rectangle("fill", px, py, pw, 40, 10, 10, 0, 0)
    love.graphics.setColor(0.6, 0.95, 0.88); love.graphics.setFont(UI.cjkFontMid)
    love.graphics.printf("牌靴情报  [I / ESC 关闭]", px, py + 10, pw, "center")

    -- ===== 页签：顺序带 / 标签台账 / 弃牌堆 + 标记费余额（同行右对齐，互不重叠）=====
    local tab = state._shoeInfoTab or "strip"
    local mprice = GameState.markPrice(state)   -- 酒吧模式为 nil（无标记玩法）
    UI._shoeInfoTabBtns = {}
    local function tabBtn(id, label, tx)
        love.graphics.setColor(tab == id and {0.10, 0.34, 0.32} or {0.12, 0.18, 0.20})
        love.graphics.rectangle("fill", tx, py + 46, 96, 22, 3)
        love.graphics.setColor(tab == id and {0.75, 0.98, 0.92} or {0.55, 0.65, 0.64})
        love.graphics.setFont(UI.cjkFontSmall)
        love.graphics.printf(label, tx, py + 49, 96, "center")
        UI._shoeInfoTabBtns[id] = { x = tx, y = py + 46, w = 96, h = 22 }
    end
    tabBtn("strip", "顺序带", px + 12)
    tabBtn("ledger", "标签台账", px + 116)
    tabBtn("discard", "弃牌堆", px + 220)
    tabBtn("dealer", "庄家", px + 324)
    love.graphics.setFont(UI.cjkFontSmall); love.graphics.setColor(0.95, 0.80, 0.50)
    local costText = mprice
        and ("标记 " .. #(state.shoeMarks or {}) .. "/" .. GameState.marksCap(state) .. " · $" .. mprice .. "/次")
        or "酒吧模式无标记"
    love.graphics.printf(costText, px + pw - 208, py + 49, 196, "right")

    local markMap = GameState.markUidMap(state)

    if tab == "strip" then
    -- ===== 顺序带（左 = 下一张；滚轮/方向键向后拉）=====
    local stripTop = py + 84
    local SLOT_W, SLOT_H, GAP = 52, 76, 8
    local maxSlots = math.floor((pw - 24 + GAP) / (SLOT_W + GAP))
    local peekN = math.min(state._shoePeek or 0, 12)
    local stripScroll = state._shoeInfoStripScroll or 0
    stripScroll = math.max(0, math.min(stripScroll, math.max(0, #deck.cards - 1)))
    state._shoeInfoStripScroll = stripScroll
    local slots = ShoeInfo.visibleSlots(deck, maxSlots, peekN, stripScroll, state._revealedPos)
    love.graphics.setFont(UI.cjkFontSmall); love.graphics.setColor(0.55, 0.75, 0.72)
    local stripHint
    if state._rodArmed then
        stripHint = (state._rodArmed.kind == "swap" and #(state._rodArmed.picked or {}) == 1)
            and "换位钓具：已选第 1 张，再点一张已标记的牌完成互换:"
            or "钓具武装中：点击已标记的牌作为目标:"
    elseif mprice then
        stripHint = "第 " .. (stripScroll + 1) .. " 张起 · 点击牌背花 $" .. mprice
            .. " 做记号 · 再点已标记的牌取消 · 滚轮/方向键后拉:"
    else
        stripHint = "第 " .. (stripScroll + 1) .. " 张起 · 滚轮/方向键后拉:"
    end
    love.graphics.print(stripHint, px + 12, stripTop - 16)
    UI._shoeSlotBtns = {}
    local mx, my = love.mouse.getPosition()
    for i, s in ipairs(slots) do
        local sx = px + 12 + (i - 1) * (SLOT_W + GAP)
        local sy = stripTop
        local mk = markMap[s.card.uid]
        if s.revealed then
            local c = s.card
            local isRed = (c.suit == "♥" or c.suit == "♦")
            love.graphics.setColor(0.94, 0.94, 0.90)
            love.graphics.rectangle("fill", sx, sy, SLOT_W, SLOT_H, 4)
            love.graphics.setColor(isRed and {0.85, 0.15, 0.15} or {0.12, 0.12, 0.16})
            love.graphics.rectangle("line", sx + 0.5, sy + 0.5, SLOT_W - 1, SLOT_H - 1, 4)
            love.graphics.setFont(UI.font)
            love.graphics.printf(tostring(c.rank), sx, sy + 12, SLOT_W, "center")
            love.graphics.printf(c.suit or "", sx, sy + 38, SLOT_W, "center")
        else
            -- 牌背 + "?"（未知即问号）
            love.graphics.setColor(0.20, 0.26, 0.46)
            love.graphics.rectangle("fill", sx, sy, SLOT_W, SLOT_H, 4)
            love.graphics.setColor(0.34, 0.42, 0.68)
            love.graphics.rectangle("line", sx + 0.5, sy + 0.5, SLOT_W - 1, SLOT_H - 1, 4)
            love.graphics.setColor(0.55, 0.62, 0.85); love.graphics.setFont(UI.font)
            love.graphics.printf("?", sx, sy + 24, SLOT_W, "center")
        end
        -- 玩家标记：橙点记号（真实出千记号的还原——只有玩家知道含义）
        if mk then
            UI.drawCardMark(s.card, { x = sx, y = sy, w = SLOT_W, h = SLOT_H }, mk)
            if mk.seen and not s.revealed then
                love.graphics.setColor(1, 0.72, 0.25); love.graphics.setFont(UI.cjkFontSmall)
                love.graphics.printf(tostring(mk.rank) .. (mk.suit or ""), sx, sy + SLOT_H - 18, SLOT_W, "center")
            end
        end
        -- 可标记 / 可取消 / 钓具目标 热区；悬停高亮（钓具目标 = 青色，其余 = 琥珀色）
        local canMark = (not s.revealed) and (not mk) and mprice ~= nil
            and (state.player.chips or 0) >= mprice
            and #(state.shoeMarks or {}) < GameState.marksCap(state)
        local canCancel = (mk ~= nil) and mprice ~= nil
        local rodTargetOk = (state._rodArmed ~= nil) and (mk ~= nil)
        local interactive = canMark or canCancel or rodTargetOk
        local hover = interactive and mx >= sx and mx <= sx + SLOT_W and my >= sy and my <= sy + SLOT_H
        if hover then
            if rodTargetOk then
                love.graphics.setColor(0.3, 0.95, 0.9, 0.95)
            else
                love.graphics.setColor(1, 0.72, 0.25, 0.9)
            end
            love.graphics.setLineWidth(2)
            love.graphics.rectangle("line", sx - 1, sy - 1, SLOT_W + 2, SLOT_H + 2, 4)
            love.graphics.setLineWidth(1)
        end
        UI._shoeSlotBtns[#UI._shoeSlotBtns + 1] = {
            slotIndex = s.index, x = sx, y = sy, w = SLOT_W, h = SLOT_H,
            enabled = interactive,
            marked = (mk ~= nil),
        }
        -- 槽位序号（绝对位置：牌库第 N 张；牌框下方小字，独立一行不与牌面叠压）
        love.graphics.setFont(UI.cjkFontSmall); love.graphics.setColor(0.45, 0.60, 0.58)
        love.graphics.print(tostring(s.index), sx + 2, sy + SLOT_H + 2)
    end
    -- 尾部"还有 N 张"
    local remain = #deck.cards - (stripScroll + #slots)
    local tailW = pw - 24 - (#slots * (SLOT_W + GAP) - GAP)
    if remain > 0 and tailW >= 44 then
        local tx = px + 12 + #slots * (SLOT_W + GAP)
        love.graphics.setColor(0.13, 0.18, 0.22)
        love.graphics.rectangle("fill", tx, stripTop, tailW, SLOT_H, 4)
        love.graphics.setColor(0.5, 0.68, 0.66); love.graphics.setFont(UI.cjkFontSmall)
        love.graphics.printf("… 还有 " .. remain .. " 张", tx + 6, stripTop + SLOT_H / 2 - 8, tailW - 12, "left")
    end

    -- ===== 鱼钩动画（钓具钓获演出：动画结束后 updateVisuals 才真正改牌库）=====
    if state._rodAnim then
        local ra = state._rodAnim
        local t = love.timer.getTime() - ra.startAt
        local dur = ra.duration or 0.8
        local p = math.min(1, t / dur)
        -- 锚点：点击槽位中心；即发型 / 缺省 → 顺序带首个槽位
        local hx = ra.x or (px + 12 + SLOT_W / 2)
        local hy = ra.y or (stripTop + SLOT_H / 2)
        if ra.x then hx, hy = ra.x, ra.y end
        -- 鱼线：从面板标题垂下，随进度下探到目标
        local hookY = py + 20 + (hy - py - 20) * math.min(1, p * 1.4)
        love.graphics.setColor(0.95, 0.95, 0.9, 0.85)
        love.graphics.setLineWidth(2)
        love.graphics.line(hx, py + 8, hx, hookY - 10)
        -- J 形鱼钩
        love.graphics.arc("line", hx, hookY - 10, 9, math.pi * 0.15, math.pi * 1.05)
        love.graphics.setColor(1, 0.85, 0.3, 0.9)
        love.graphics.circle("fill", hx + 9 * math.cos(math.pi * 0.15), hookY - 10 + 9 * math.sin(math.pi * 0.15), 2.5)
        -- 落点涟漪（接近结束时扩散）
        if p > 0.55 then
            local rp = (p - 0.55) / 0.45
            love.graphics.setColor(0.4, 0.95, 0.9, (1 - rp) * 0.9)
            love.graphics.setLineWidth(2)
            love.graphics.circle("line", hx, hy, 6 + rp * 26)
            love.graphics.circle("line", hx, hy, 2 + rp * 14)
        end
        love.graphics.setLineWidth(1)
        love.graphics.setFont(UI.cjkFontSmall)
        love.graphics.setColor(0.85, 0.98, 0.95, 0.9)
        love.graphics.printf("钓获中…", px, py + ph - 26, pw, "center")
    end

    -- ===== 构成栏（13 点数 + 不定值"?"列）=====
    -- +40 间隔：槽位序号小字（槽下 2px 起，高约 12px）与本节标签错行，绝不压叠
    local compTop = stripTop + SLOT_H + 40
    local comp = ShoeInfo.rankComposition(deck)
    local COLS = #ShoeInfo.RANK_ORDER + 1
    local colW = (pw - 24) / COLS
    love.graphics.setFont(UI.cjkFontSmall); love.graphics.setColor(0.55, 0.75, 0.72)
    love.graphics.print("抽牌堆构成（张数）:", px + 12, compTop - 16)
    for ci, rk in ipairs(ShoeInfo.RANK_ORDER) do
        local cx = px + 12 + (ci - 1) * colW
        love.graphics.setColor(0.10, 0.15, 0.18)
        love.graphics.rectangle("fill", cx, compTop, colW - 3, 44, 3)
        love.graphics.setColor(0.85, 0.88, 0.86); love.graphics.setFont(UI.font)
        love.graphics.printf(rk, cx, compTop + 4, colW - 3, "center")
        love.graphics.setColor(0.65, 0.90, 0.85); love.graphics.setFont(UI.cjkFontSmall)
        love.graphics.printf(tostring(comp.byRank[rk] or 0), cx, compTop + 24, colW - 3, "center")
    end
    -- 特殊/不定值列
    do
        local ci = COLS
        local cx = px + 12 + (ci - 1) * colW
        love.graphics.setColor(0.14, 0.12, 0.10)
        love.graphics.rectangle("fill", cx, compTop, colW - 3, 44, 3)
        love.graphics.setColor(0.95, 0.80, 0.50); love.graphics.setFont(UI.font)
        love.graphics.printf("?", cx, compTop + 4, colW - 3, "center")
        love.graphics.setFont(UI.cjkFontSmall)
        love.graphics.printf(tostring(comp.unknown), cx, compTop + 24, colW - 3, "center")
    end

    -- ===== 爆率行 + 弃牌堆行 =====
    local oddsY = compTop + 58
    local difficulty = (state.stageDifficulty and state.stageDifficulty[state.stage]) or 1
    -- 缓存：枚举不能每帧跑；戳 = 洗牌计数|抽牌堆张数|双手张数|玩家点数|难度
    local stamp = table.concat({
        tostring(deck.shuffleCount or 0), tostring(#deck.cards),
        tostring(#state.player.hand or 0),
        tostring(Blackjack.calculateHand(state.player.hand or {})),
        tostring(#state.dealer.hand or 0), tostring(difficulty),
    }, "|")
    if not UI._shoeOdds or UI._shoeOdds.stamp ~= stamp then
        UI._shoeOdds = {
            stamp = stamp,
            bust = ShoeInfo.bustOdds(state.player.hand or {}, deck),
            dealerBust = ShoeInfo.dealerBustOdds(state.dealer.hand or {}, deck, difficulty),
        }
    end
    local function pct(v)
        if v == nil then return "--" end
        return string.format("%.1f%%", v * 100)
    end
    love.graphics.setFont(UI.cjkFontSmall); love.graphics.setColor(0.80, 0.90, 0.88)
    local line = "下一张爆率: " .. pct(UI._shoeOdds.bust) .. "      庄家最终爆率: " .. pct(UI._shoeOdds.dealerBust)
    local nonStd = (comp.total or 0) - (comp.standard or 0)
    if nonStd > 0 then
        line = line .. "（" .. nonStd .. " 张特殊/不定值牌未计入庄家爆率）"
    end
    love.graphics.print(line, px + 12, oddsY)
    love.graphics.setColor(0.55, 0.68, 0.66)
    love.graphics.print("弃牌堆 " .. #(deck.discardPile or {}) .. " 张 · 按 D 翻看抽牌堆总览", px + 12, oddsY + 18)
    end  -- 顺序带页签结束

    -- ===== 标签台账页签 =====
    if tab == "ledger" then
        local ly0 = py + 92
        love.graphics.setFont(UI.cjkFontSmall)
        love.graphics.setColor(0.55, 0.75, 0.72)
        love.graphics.print("实体标记（洗牌后仍追踪同一张牌；位置实时刷新）:", px + 12, ly0)
        local marks = state.shoeMarks or {}
        if #marks == 0 then
            love.graphics.setColor(0.5, 0.6, 0.58)
            love.graphics.print("暂无标记 — 切到「顺序带」点击牌背槽位，消耗 1 墨水做记号。", px + 12, ly0 + 26)
        end
        for mi, m in ipairs(marks) do
            local ry = ly0 + 30 + (mi - 1) * 30
            local where, idx = GameState.markWhere(state, m)
            local whereText =
                where == "draw" and ("抽牌堆第 " .. idx .. " 张") or
                where == "discard" and ("弃牌堆第 " .. idx .. " 张") or
                where == "player" and "玩家手牌中" or
                where == "dealer" and "庄家手牌中" or
                where == "stored" and "卡包寄存中" or
                "行踪不明"
            local valText = m.seen and (tostring(m.rank) .. (m.suit or "")) or "点数未知"
            local kindName = ({ ink = "墨水", vanish = "消失", bomb = "爆炸", flame = "火焰", void = "虚空", bounty = "赏金" })[m.kind or "ink"] or "墨水"
            love.graphics.setColor(0.9, 0.94, 0.92)
            love.graphics.printf("#" .. mi .. " [" .. kindName .. "]  " .. whereText .. "  ·  " .. valText,
                px + 12, ry, pw - 24, "left")
            love.graphics.setColor(0.15, 0.20, 0.22)
            love.graphics.rectangle("fill", px + 12, ry + 23, pw - 24, 1)
        end
    end

    -- ===== 庄家页签（只用明牌推断，绝不泄露暗牌）=====
    if tab == "dealer" then
        local dyy = py + 92
        love.graphics.setFont(UI.cjkFontSmall)
        love.graphics.setColor(0.55, 0.75, 0.72)
        love.graphics.print("庄家分析（只用明牌推断，不泄露暗牌）:", px + 12, dyy - 16)
        local visibleCards = {}
        for _, c in ipairs(state.dealer.hand or {}) do
            if c.faceUp then table.insert(visibleCards, c) end
        end
        local visTotal = Blackjack.calculateHand(visibleCards)
        local difficulty = (state.stageDifficulty and state.stageDifficulty[state.stage]) or 1
        local stopAt = (difficulty >= 2) and 18 or 15
        local ruleText = (difficulty >= 2) and "不足 18 点必须要牌（软 18 继续要）" or "不足 15 点必须要牌（停牌线 15）"
        local lines = {
            "明牌合计: " .. visTotal,
            "庄规: " .. ruleText,
        }
        if visTotal >= stopAt then
            table.insert(lines, "倾向: 明牌已达停牌线 → 庄家几乎必然停牌")
        else
            local needHole = stopAt - visTotal
            table.insert(lines, "倾向: 暗牌 ≥ " .. needHole .. " 点即停牌，否则继续要牌")
        end
        local cc = (state.cheatChance and state.cheatChance[state.stage]) or 0
        table.insert(lines, string.format("本阶段作弊风险: %d%%（指认成功 = 3 倍下注奖金）", math.floor(cc * 100 + 0.5)))
        if state.gameMode == "hard" and state.dealerClass then
            table.insert(lines, "庄家职阶: " .. tostring(state.dealerClass.name or state.dealerClass.id))
        end
        love.graphics.setColor(0.9, 0.94, 0.92)
        for i, ln in ipairs(lines) do
            love.graphics.print(ln, px + 12, dyy + (i - 1) * 28)
        end
    end

    -- ===== 弃牌堆页签（公开信息可整堆翻查；点击消耗标记费；滚轮/方向键翻页）=====
    if tab == "discard" then
        local dzTop = py + 84
        local CW, CH, CGAP = 40, 60, 8
        local cols = math.floor((pw - 24 + CGAP) / (CW + CGAP))
        local pile = state.deck.discardPile or {}
        love.graphics.setFont(UI.cjkFontSmall); love.graphics.setColor(0.55, 0.75, 0.72)
        local dzHint
        if state._salvagerArmed then
            dzHint = "打捞武装中：点击一张弃牌，下次要牌将其打出（每回合不限，共 3 次）:"
        else
            dzHint = "弃牌堆（公开信息）· 点击一张做记号 · 再点已标记的牌取消 · 滚轮/方向键翻页:"
        end
        love.graphics.print(dzHint, px + 12, dzTop - 16)
        local viewH = (py + ph - 48) - dzTop
        local rows = math.max(1, math.floor((viewH + CGAP) / (CH + CGAP)))
        local totalRows = math.ceil(#pile / cols)
        local scroll = state._shoeInfoDiscardScroll or 0
        scroll = math.max(0, math.min(scroll, math.max(0, totalRows - rows)))
        state._shoeInfoDiscardScroll = scroll
        UI._shoeDiscardBtns = {}
        local dmx, dmy = love.mouse.getPosition()
        for ri = 0, rows - 1 do
            local rowIdx = scroll + ri
            if rowIdx >= totalRows then break end
            local dy = dzTop + ri * (CH + CGAP)
            for ci = 0, cols - 1 do
                local idx = rowIdx * cols + ci + 1
                local card = pile[idx]
                if not card then break end
                local cx = px + 12 + ci * (CW + CGAP)
                local isRed = (card.suit == "♥" or card.suit == "♦")
                love.graphics.setColor(0.90, 0.90, 0.86)
                love.graphics.rectangle("fill", cx, dy, CW, CH, 3)
                love.graphics.setColor(isRed and {0.85, 0.15, 0.15} or {0.12, 0.12, 0.16})
                love.graphics.rectangle("line", cx + 0.5, dy + 0.5, CW - 1, CH - 1, 3)
                love.graphics.setFont(UI.font)
                love.graphics.printf(tostring(card.rank), cx, dy + 8, CW, "center")
                love.graphics.printf(card.suit or "", cx, dy + 30, CW, "center")
                local mk2 = markMap[card.uid]
                if mk2 then UI.drawCardMark(card, { x = cx, y = dy, w = CW, h = CH }, mk2) end
                local canMark2 = (not mk2) and mprice ~= nil
                    and (state.player.chips or 0) >= mprice
                    and #(state.shoeMarks or {}) < GameState.marksCap(state)
                -- 打捞武装中：任何弃牌都可选中；已标记的牌可取消
                local canSalvage = (state._salvagerArmed ~= nil)
                local canCancel2 = (mk2 ~= nil) and mprice ~= nil
                local hover2 = (canMark2 or canCancel2 or canSalvage)
                    and dmx >= cx and dmx <= cx + CW and dmy >= dy and dmy <= dy + CH
                if hover2 then
                    if canSalvage then
                        love.graphics.setColor(0.3, 0.95, 0.9, 0.9)
                    else
                        love.graphics.setColor(1, 0.72, 0.25, 0.9)
                    end
                    love.graphics.setLineWidth(2)
                    love.graphics.rectangle("line", cx - 1, dy - 1, CW + 2, CH + 2, 3)
                    love.graphics.setLineWidth(1)
                end
                UI._shoeDiscardBtns[#UI._shoeDiscardBtns + 1] = {
                    index = idx, x = cx, y = dy, w = CW, h = CH,
                    enabled = canMark2 or canCancel2 or canSalvage,
                    marked = (mk2 ~= nil),
                }
            end
        end
        if #pile == 0 then
            love.graphics.setColor(0.5, 0.6, 0.58)
            love.graphics.print("弃牌堆还是空的 — 打完一手牌后这里会有牌。", px + 12, dzTop + 8)
        end
    end

    -- 关闭按钮
    local cbW, cbH = 110, 24
    local cbX = px + pw / 2 - cbW / 2
    local cbY = py + ph - 32
    love.graphics.setColor(0.35, 0.45, 0.44)
    love.graphics.rectangle("fill", cbX, cbY, cbW, cbH, 4)
    love.graphics.setColor(1, 1, 1); love.graphics.setFont(UI.cjkFontSmall)
    love.graphics.printf("关闭 [I]", cbX, cbY + 4, cbW, "center")

    UI._shoeInfoCloseBtn = { x = cbX, y = cbY, w = cbW, h = cbH }
    UI._shoeInfoArea = { x = px, y = py, w = pw, h = ph }
end

-- ============================================================
-- 阶段 2 说明弹窗（模态，纯阅读 + 点确认；ESC 不跳过）
--   _stage2BriefOpen 由 game_state 在「每次新游戏内首次进入阶段 2」时置真
--   热区写入 UI._stage2BriefBtn，由 main.lua 读取（绘制与点击同一份坐标）
-- ============================================================
function UI.drawStage2Brief(state)
    if not state._stage2BriefOpen then return end

    local w, h = love.graphics.getWidth(), love.graphics.getHeight()
    love.graphics.setColor(0, 0, 0, 0.78)
    love.graphics.rectangle("fill", 0, 0, w, h)

    local pw = math.min(600, w - 60)
    local ph = math.min(400, h - 60)
    local px = (w - pw) / 2
    local py = (h - ph) / 2

    love.graphics.setColor(0.1, 0.1, 0.15, 0.98)
    love.graphics.rectangle("fill", px, py, pw, ph, 10)
    love.graphics.setColor(1, 0.6, 0.3)
    love.graphics.setLineWidth(2)
    love.graphics.rectangle("line", px, py, pw, ph, 10)
    love.graphics.setLineWidth(1)

    local headerH = 42
    love.graphics.setColor(0.2, 0.12, 0.05, 1)
    love.graphics.rectangle("fill", px, py, pw, headerH, 10, 10, 0, 0)
    love.graphics.setColor(1, 0.7, 0.35); love.graphics.setFont(UI.cjkFontMid)
    love.graphics.printf("庄家开始出千了", px, py + 11, pw, "center")

    local lx = px + 26
    local lw = pw - 52
    local ly = py + headerH + 20

    love.graphics.setFont(UI.cjkFont); love.graphics.setColor(0.92, 0.92, 0.92)
    love.graphics.printf("从这一阶段起，庄家有概率在牌上动手脚。", lx, ly, lw, "left")
    ly = ly + 26
    love.graphics.printf("三招的痕迹各不相同，都画在被动过的那张牌上：", lx, ly, lw, "left")

    ly = ly + 26
    love.graphics.setFont(UI.cjkFontSmall); love.graphics.setColor(0.85, 0.85, 0.85)
    love.graphics.printf("  A 暗牌换牌：暗牌位白描边 + 持续抖动", lx, ly, lw, "left")
    ly = ly + 20
    love.graphics.printf("  B 抽牌必 10：新抽到的牌金色描边脉冲", lx, ly, lw, "left")
    ly = ly + 20
    love.graphics.printf("  C 低牌换掉：被换的牌青绿淡出，新牌淡入", lx, ly, lw, "left")

    ly = ly + 24
    love.graphics.setColor(1, 0.75, 0.4)
    love.graphics.printf("看到的痕迹不一定为真，也可能只是「像」而已。", lx, ly, lw, "left")

    ly = ly + 24
    love.graphics.setColor(0.85, 0.85, 0.85)
    love.graphics.printf("确信是出千就按 C 指认（每小局仅一次）：", lx, ly, lw, "left")
    ly = ly + 20
    love.graphics.printf("  指认成功 -> 赢 3 倍下注，本局结束", lx, ly, lw, "left")
    ly = ly + 20
    love.graphics.printf("  指认错误 -> 本笔下注输掉，另罚 $50", lx, ly, lw, "left")

    -- 确认按钮：唯一出口（ESC 不跳过；热区与绘制同源）
    local btnW, btnH = 160, 30
    local btnX = px + pw / 2 - btnW / 2
    local btnY = py + ph - btnH - 18
    love.graphics.setColor(0.85, 0.45, 0.2)
    love.graphics.rectangle("fill", btnX, btnY, btnW, btnH, 5)
    love.graphics.setColor(0.35, 0.2, 0.05); love.graphics.setLineWidth(1)
    love.graphics.rectangle("line", btnX, btnY, btnW, btnH, 5)
    love.graphics.setColor(1, 1, 1); love.graphics.setFont(UI.cjkFontSmall)
    love.graphics.printf("我知道了", btnX, btnY + 7, btnW, "center")

    UI._stage2BriefBtn = { x = btnX, y = btnY, w = btnW, h = btnH }
end

-- ============================================================
-- 冠军牌组编辑器（全屏模态）
--   左侧：36 格牌组栏（点击已放进去的牌 = 移除 / 点击牌池里的牌 = 加入）
--   右侧：牌池，先用下拉菜单选「牌组种类」，再把该种类的全部牌展示出来
--   顶部：保存 / 清空 / 返回
-- 布局一律按窗口比例推算（800x600 ~ 1920x1080 都不重叠）；
-- 热区写入 UI._deckEditor*，由 main.lua 的 handleDeckEditorClick 读取（绘制与点击同一份坐标）
-- ============================================================

-- 迷你卡面（编辑器专用）：不写 card.visual，绝不污染牌池 / 冠军牌组模板
local function drawMiniCard(card, x, y, w, h, hovered)
    love.graphics.setColor(hovered and {1, 1, 0.8} or {0.92, 0.92, 0.92})
    love.graphics.rectangle("fill", x, y, w, h, 4)

    -- 词条色条（顶部）
    local accent
    if card.is_blackhole then            accent = {0.04, 0.04, 0.04}
    elseif card.is_cage then             accent = {0.45, 0.42, 0.40}
    elseif card.is_chip then             accent = {0.85, 0.15, 0.15}
    elseif card.kind == "negative" then  accent = {0.85, 0.15, 0.15}
    elseif card.kind == "decimal" then   accent = {0.15, 0.70, 0.20}
    elseif card.kind == "multiplier" then accent = {0.90, 0.65, 0.10}
    elseif card.kind == "s67" then       accent = {0.60, 0.30, 0.90}
    elseif card.kind == "dice6" then     accent = {0.78, 0.78, 0.74}
    elseif card.kind == "dice20" then    accent = {0.20, 0.75, 0.70}
    elseif card.kind == "rps" then       accent = {0.30, 0.60, 0.90}
    else                                 accent = {0.55, 0.55, 0.60} end
    love.graphics.setColor(accent)
    local barH = math.max(3, math.floor(h * 0.10))
    love.graphics.rectangle("fill", x + 2, y + 2, w - 4, barH, 2)

    -- 牌面（点数）
    local col
    if card.kind == "negative" then      col = {0.85, 0.15, 0.15}
    elseif card.kind == "decimal" then   col = {0.10, 0.50, 0.15}
    elseif card.kind == "multiplier" then col = {0.72, 0.48, 0.05}
    elseif card.is_blackhole then        col = {0.08, 0.08, 0.08}
    elseif card.is_chip then             col = {0.80, 0.05, 0.05}
    elseif card.suit == "\u{2665}" or card.suit == "\u{2666}" then col = {0.80, 0.05, 0.05}
    else                                 col = {0.05, 0.05, 0.05} end
    love.graphics.setColor(col)
    love.graphics.setFont(UI.cjkFontSmall)
    love.graphics.printf(tostring(card.rank or "?"), x, y + barH + 3, w, "center")

    -- 底注：倍率附注优先，其次是花色
    if card.mult_bonus and card.mult_bonus > 0 then
        love.graphics.setColor(0.72, 0.48, 0.05)
        love.graphics.printf("+" .. card.mult_bonus, x, y + h - 17, w, "center")
    elseif card.suit and not card.is_blackhole then
        love.graphics.setColor(col)
        love.graphics.printf(card.suit, x, y + h - 17, w, "center")
    end

    -- 词条边框（黑洞：黑色粗边框；牢笼：铁色边框 + 3 条竖杠）
    if card.is_blackhole then
        love.graphics.setColor(0.02, 0.02, 0.02)
        love.graphics.setLineWidth(3)
        love.graphics.rectangle("line", x - 1, y - 1, w + 2, h + 2, 4)
        love.graphics.setLineWidth(1)
    elseif card.is_cage then
        love.graphics.setColor(0.45, 0.42, 0.40)
        love.graphics.setLineWidth(3)
        love.graphics.rectangle("line", x - 1, y - 1, w + 2, h + 2, 4)
        love.graphics.setColor(0.36, 0.34, 0.32)
        love.graphics.setLineWidth(2)
        for i = 1, 3 do
            local bx = x + w * i / 4
            love.graphics.line(bx, y + 2, bx, y + h - 2)
        end
        love.graphics.setLineWidth(1)
    elseif card.is_chip then
        -- 首参是卡身左上角，不能传中心（传中心会偏半张卡身）
        UI.drawChipMarks(x, y, w, h, 1)
    end

    love.graphics.setColor(1, 1, 1)
end

-- 编辑器布局（纯计算，无副作用；绘制 / 滚动 / 热区共用这一份推算结果）
function UI.deckEditorLayout(state)
    local W, H = window_width, window_height
    local pad     = math.floor(W * 0.02)
    local headerH = math.floor(H * 0.13)

    -- 右侧牌池面板（先定它，左侧牌组栏吃掉剩下的宽度）
    local poolW = math.floor((W - pad * 3) * 0.56)
    local poolX = W - pad - poolW
    local deckX = pad
    local deckW = poolX - pad - deckX

    local bodyTop    = headerH
    local bodyBottom = H - math.max(6, math.floor(H * 0.02))
    local bodyH      = bodyBottom - bodyTop

    -- ===== 左侧：6 x 6 = 36 格牌组栏 =====
    local dGap    = math.max(3, math.floor(W * 0.004))
    local dLabelH = math.max(18, math.floor(H * 0.045))
    local dGridH  = bodyH - dLabelH
    local dcw = math.floor((deckW - dGap * 5) / 6)
    local dch = math.floor((dGridH - dGap * 5) / 6)
    local dsize = math.max(16, math.min(dcw, math.floor(dch / 1.5)))
    local dCardW = dsize
    local dCardH = math.floor(dsize * 1.5)
    local dGridW = dCardW * 6 + dGap * 5
    local dGridX = deckX + math.max(0, math.floor((deckW - dGridW) / 2))
    local dGridY = bodyTop + dLabelH

    -- ===== 右侧：下拉菜单 + 牌池网格（8 列，纵向滚动）=====
    local pCols  = 8
    local pGap   = dGap
    local pDropX = poolX
    local pDropY = bodyTop
    local pDropW = poolW
    local pDropH = math.max(26, math.floor(H * 0.055))
    local pHintH = math.max(16, math.floor(H * 0.04))
    local pGridX = poolX
    local pGridY = pDropY + pDropH + pHintH
    local pGridH = bodyBottom - pGridY
    local pCardW = math.max(20, math.floor((poolW - pGap * (pCols - 1)) / pCols))
    local pCardH = math.floor(pCardW * 1.5)
    local rowsVisible = math.max(1, math.floor((pGridH + pGap) / (pCardH + pGap)))

    -- 当前种类的牌数 → 总行数 → 最大滚动行数
    local total = 0
    for _, g in ipairs(state._deckEditorPool or {}) do
        if g.key == state.deckEditorType then total = #g.cards break end
    end
    local totalRows = math.ceil(total / pCols)
    local maxScroll = math.max(0, totalRows - rowsVisible)

    return {
        pad = pad, headerH = headerH, bodyTop = bodyTop, bodyBottom = bodyBottom,
        deckX = deckX, deckW = deckW, dLabelH = dLabelH, dGap = dGap,
        dGridX = dGridX, dGridY = dGridY, dCardW = dCardW, dCardH = dCardH,
        poolX = poolX, poolW = poolW,
        pDropX = pDropX, pDropY = pDropY, pDropW = pDropW, pDropH = pDropH,
        pHintH = pHintH, pGridX = pGridX, pGridY = pGridY, pGridH = pGridH,
        pCardW = pCardW, pCardH = pCardH, pGap = pGap, pCols = pCols,
        rowsVisible = rowsVisible, maxScroll = maxScroll,
    }
end

-- 滚轮滚动上限（main.lua 的 wheelmoved 读它做夹紧）
function UI.getDeckEditorMaxScroll(state)
    return UI.deckEditorLayout(state).maxScroll
end

function UI.drawDeckEditor(state)
    if state.state ~= "deckEditor" then return end
    local W, H = window_width, window_height
    local pool  = state._deckEditorPool or {}
    local cards = state._deckEditorCards or {}
    local L = UI.deckEditorLayout(state)

    -- 背景
    love.graphics.setColor(0.05, 0.05, 0.08)
    love.graphics.rectangle("fill", 0, 0, W, H)
    love.graphics.setColor(0.25, 0.2, 0.35)
    love.graphics.setLineWidth(2)
    love.graphics.rectangle("line", L.pad, math.floor(H * 0.01), W - L.pad * 2, H - math.floor(H * 0.02), 8)
    love.graphics.setLineWidth(1)

    local mx, my = love.mouse.getPosition()

    -- ===== 顶部：标题 + 已选张数 =====
    love.graphics.setFont(UI.cjkFontMid)
    love.graphics.setColor(1, 0.85, 0.2)
    love.graphics.printf("冠军牌组编辑", L.pad, math.floor(H * 0.022), W - L.pad * 2, "left")

    local cnt = Champion.count(cards)
    love.graphics.setFont(UI.cjkFont)
    love.graphics.setColor(cnt == Champion.SIZE and {0.4, 0.9, 0.4} or {0.9, 0.75, 0.3})
    love.graphics.printf("已选 " .. cnt .. " / " .. Champion.SIZE .. " 张",
        L.pad, math.floor(H * 0.082), W - L.pad * 2, "left")

    -- ===== 顶部按钮（从右往左画；热区与点击同源）=====
    UI._deckEditorButtons = {}
    local btnH   = math.max(26, math.floor(H * 0.05))
    local btnW   = math.max(80, math.floor(W * 0.09))
    local btnGap = math.max(6, math.floor(W * 0.008))
    local bx = W - L.pad - btnW
    local by = math.floor(H * 0.022)
    local function drawTopBtn(label, color, hoverColor, action)
        local hov = mx >= bx and mx <= bx + btnW and my >= by and my <= by + btnH
        love.graphics.setColor(hov and hoverColor or color)
        love.graphics.rectangle("fill", bx, by, btnW, btnH, 5)
        love.graphics.setColor(1, 1, 1, 0.75)
        love.graphics.rectangle("line", bx, by, btnW, btnH, 5)
        love.graphics.setColor(1, 1, 1)
        love.graphics.setFont(UI.cjkFont)
        love.graphics.printf(label, bx, by + math.max(2, math.floor(btnH * 0.18)), btnW, "center")
        table.insert(UI._deckEditorButtons, { action = action, x = bx, y = by, w = btnW, h = btnH })
        bx = bx - btnW - btnGap
    end
    drawTopBtn("保存",     {0.2, 0.5, 0.25},  {0.3, 0.7, 0.35}, "save")
    drawTopBtn("返回",     {0.35, 0.2, 0.2},  {0.55, 0.3, 0.3},  "close")

    -- ===== 左侧：36 格牌组栏 =====
    love.graphics.setFont(UI.cjkFont)
    love.graphics.setColor(0.85, 0.85, 0.9)
    love.graphics.printf("我的冠军牌组（点已选的牌移除）", L.deckX, L.bodyTop, L.deckW, "left")

    UI._deckEditorSlots = {}
    local slotN = Champion.SIZE
    for i = 1, slotN do
        local c  = (i - 1) % 6
        local r  = math.floor((i - 1) / 6)
        local x  = L.dGridX + c * (L.dCardW + L.dGap)
        local y  = L.dGridY + r * (L.dCardH + L.dGap)
        local card = cards[i]
        if card then
            local hov = mx >= x and mx <= x + L.dCardW and my >= y and my <= y + L.dCardH
            drawMiniCard(card, x, y, L.dCardW, L.dCardH, hov)
            table.insert(UI._deckEditorSlots, { index = i, x = x, y = y, w = L.dCardW, h = L.dCardH })
        else
            -- 空槽：虚线感的暗框 + 序号
            love.graphics.setColor(0.14, 0.14, 0.18)
            love.graphics.rectangle("fill", x, y, L.dCardW, L.dCardH, 4)
            love.graphics.setColor(0.3, 0.3, 0.36)
            love.graphics.rectangle("line", x + 0.5, y + 0.5, L.dCardW - 1, L.dCardH - 1, 4)
            love.graphics.setColor(0.35, 0.35, 0.42)
            love.graphics.printf(tostring(i), x, y + math.floor(L.dCardH / 2) - 8, L.dCardW, "center")
        end
    end

    -- ===== 右侧：当前牌组 =====
    local curGroup = nil
    for _, g in ipairs(pool) do if g.key == state.deckEditorType then curGroup = g break end end
    if not curGroup and pool[1] then
        curGroup = pool[1]
        state.deckEditorType = curGroup.key
    end

    -- 下拉菜单表头
    local dropHov = mx >= L.pDropX and mx <= L.pDropX + L.pDropW
                and my >= L.pDropY and my <= L.pDropY + L.pDropH
    love.graphics.setColor(dropHov and {0.28, 0.24, 0.4} or {0.18, 0.16, 0.26})
    love.graphics.rectangle("fill", L.pDropX, L.pDropY, L.pDropW, L.pDropH, 5)
    love.graphics.setColor(0.6, 0.5, 0.9)
    love.graphics.rectangle("line", L.pDropX, L.pDropY, L.pDropW, L.pDropH, 5)
    love.graphics.setColor(1, 1, 1)
    love.graphics.setFont(UI.cjkFont)
    local gName = curGroup and curGroup.name or "（无）"
    love.graphics.printf(gName .. (state.deckEditorDropOpen and "  ^ 收起" or "  v 展开"),
        L.pDropX + 10, L.pDropY + math.max(3, math.floor(L.pDropH * 0.18)), L.pDropW - 20, "left")
    UI._deckEditorDrop = { x = L.pDropX, y = L.pDropY, w = L.pDropW, h = L.pDropH }

    -- 牌池提示行（当前种类的说明 + 张数）
    love.graphics.setFont(UI.cjkFontSmall)
    love.graphics.setColor(0.7, 0.7, 0.75)
    local hintTxt = (curGroup and curGroup.desc ~= "" and curGroup.desc or "点击下方任意一张牌加入冠军牌组")
        .. "   共 " .. (curGroup and #curGroup.cards or 0) .. " 张"
    local hintShown = UI.fitTextEllipsis(hintTxt, UI.cjkFontSmall, L.pDropW,
        UI.cjkFontSmall:getHeight(), UI.cjkFontSmall:getHeight())
    love.graphics.printf(hintShown, L.pDropX, L.pDropY + L.pDropH + 4, L.pDropW, "left")

    -- ===== 牌池网格（下拉展开时让位给菜单，避免互相遮挡）=====
    UI._deckEditorPoolCards = {}
    if state.deckEditorDropOpen then
        UI._deckEditorDropItems = {}
        local gapI = math.max(2, math.floor(L.pGap * 0.6))
        local ih = math.max(20, math.floor(H * 0.045))
        if #pool > 0 then
            local fit = math.floor((L.pGridH - gapI * (#pool - 1)) / #pool)
            if fit > 0 and fit < ih then ih = fit end
        end
        for i, g in ipairs(pool) do
            local y = L.pGridY + (i - 1) * (ih + gapI)
            local hov = mx >= L.pGridX and mx <= L.pGridX + L.pDropW and my >= y and my <= y + ih
            local cur = (g.key == state.deckEditorType)
            love.graphics.setColor(cur and {0.35, 0.28, 0.55} or (hov and {0.26, 0.24, 0.36} or {0.16, 0.15, 0.22}))
            love.graphics.rectangle("fill", L.pGridX, y, L.pDropW, ih, 4)
            love.graphics.setColor(unpack(g.color or {1, 1, 1}))
            love.graphics.rectangle("fill", L.pGridX + 4, y + 4, math.max(3, math.floor(ih * 0.25)), ih - 8, 2)
            love.graphics.setColor(1, 1, 1)
            love.graphics.setFont(UI.cjkFontSmall)
            love.graphics.printf(g.name .. "（" .. #g.cards .. " 张）",
                L.pGridX + 12, y + math.max(2, math.floor(ih * 0.22)), L.pDropW - 20, "left")
            table.insert(UI._deckEditorDropItems,
                { key = g.key, x = L.pGridX, y = y, w = L.pDropW, h = ih })
        end
    else
        UI._deckEditorDropItems = nil
        local scroll = state.deckEditorScroll or 0
        if scroll > L.maxScroll then scroll = L.maxScroll; state.deckEditorScroll = scroll end
        if scroll < 0 then scroll = 0; state.deckEditorScroll = 0 end

        if curGroup then
            local firstIdx  = scroll * L.pCols + 1
            local lastRow   = math.min(math.ceil(#curGroup.cards / L.pCols), scroll + L.rowsVisible)
            for idx = firstIdx, lastRow * L.pCols do
                local card = curGroup.cards[idx]
                if card then
                    local c = (idx - 1) % L.pCols
                    local r = math.floor((idx - 1) / L.pCols) - scroll
                    local x = L.pGridX + c * (L.pCardW + L.pGap)
                    local y = L.pGridY + r * (L.pCardH + L.pGap)
                    local hov = mx >= x and mx <= x + L.pCardW and my >= y and my <= y + L.pCardH
                    drawMiniCard(card, x, y, L.pCardW, L.pCardH, hov)
                    table.insert(UI._deckEditorPoolCards,
                        { card = card, x = x, y = y, w = L.pCardW, h = L.pCardH })
                end
            end
        end

        -- 滚动提示（有更多行时才显示）
        if L.maxScroll > 0 then
            love.graphics.setFont(UI.cjkFontSmall)
            love.graphics.setColor(0.6, 0.6, 0.7)
            love.graphics.printf("滚轮翻页  " .. math.min(scroll + 1, L.maxScroll + 1) .. " / " .. (L.maxScroll + 1),
                L.pGridX, L.bodyBottom - UI.cjkFontSmall:getHeight(), L.pDropW, "right")
        end
    end

    love.graphics.setColor(1, 1, 1)
end

-- ============================================================
-- 主菜单
-- ============================================================
function UI.drawTitleScreen(state)
    local W = window_width; local H = window_height
    local cx = W / 2

    -- 深黑背景（替代绿色）
    love.graphics.setColor(0.04, 0.04, 0.06)
    love.graphics.rectangle("fill", 0, 0, W, H)

    -- 微弱径向光晕（暗红）
    love.graphics.setColor(0.12, 0.04, 0.04, 0.6)
    local haloR = math.min(H, W) * 0.6
    for i = 1, 10 do
        love.graphics.circle("fill", cx, H * 0.35, haloR + i * math.min(20, H * 0.05))
    end

    -- ========== 程序化红黑轮盘（静态，0 格为黑） ==========
    -- 全部按比例算，确保 Love 默认窗口 800×600 也能完整显示
    -- ========== 布局推算（绘制与热区共用同一份结果，绝不各算一遍） ==========
    -- 自底向上推：先从版本号上沿往上排出按钮块，再用「按钮块上方的剩余空间」反推轮盘半径
    local padTop    = math.max(10, H * 0.02)
    local padBottom = math.max(10, H * 0.02)
    local verTop    = H - 30                                    -- 版本号绘制位置（保持既有约定）

    -- 1) 按钮块：safeBottom - totalBtnH（矮窗口下不再被顶出屏幕）
    local btnCount  = 4
    local btnH      = math.max(22, math.min(40, H * 0.06))       -- 缩小：上限 40px 且 <= 窗口高 6%
    local gap       = math.max(8, math.min(20, H * 0.03))        -- 间距同样随窗口收缩
    local btnW      = math.min(280, W * 0.4, btnH * 7)           -- 宽度随高度等比收窄，避免细长条
    local btnX      = cx - btnW / 2
    local totalBtnH = btnH * btnCount + gap * (btnCount - 1)
    local safeBottom = verTop - padBottom                        -- 安全下界由版本号位置显式推导
    local btnY1 = safeBottom - totalBtnH
    local btnY2 = btnY1 + btnH + gap
    local btnY3 = btnY2 + btnH + gap
    local btnY4 = btnY3 + btnH + gap

    -- 2) 轮盘：用剩余空间反推半径，既不越窗口上边、也不压住按钮块
    local wheelCX = cx
    local wheelCY = H * 0.35
    local gapWheel = math.max(12, H * 0.02)
    local R = math.max(24, math.min(H * 0.28, W * 0.28, 210,
                                    wheelCY - padTop,            -- 圆不越窗口上边
                                    btnY1 - gapWheel - wheelCY)) -- 圆不压按钮块
    if wheelCY + R + gapWheel > btnY1 then
        -- 极矮窗口：半径已到下限仍放不下 → 轮盘整体上移兜底，绝不允许压住按钮
        wheelCY = math.max(padTop + R, btnY1 - gapWheel - R)
    end
    local innerR = R * 0.76                                     -- 内圈等比
    local sectors = 20            -- 10 红 + 10 黑交替，0 格为黑
    local wheelRed = { 0.88, 0.1, 0.1 }
    local wheelBlack = { 0.06, 0.06, 0.06 }
    local spoke = 1.0             -- 每格角度 = 2π / 20 = 0.314 rad ≈ 18°

    -- 画每个扇形（从 -π/2 即顶部开始顺时针）
    for i = 1, sectors do
        local aStart = -math.pi / 2 + (i - 1) * spoke
        local aEnd   = aStart + spoke
        -- 0 格（第 20 格末尾附近算成红 0 号的黑格）→ 黑；其余奇偶交替
        local isZero = (i == 1 or i == sectors)
        local isRed = not isZero and (i % 2 == 1)
        love.graphics.setColor(isRed and wheelRed or wheelBlack)

        -- 扇形多边形：圆心 + 外圈弧（用 2 个分段近似即可） + 内圈弧反向
        local pts = {}
        -- 外圈起点
        table.insert(pts, wheelCX + math.cos(aStart) * R)
        table.insert(pts, wheelCY + math.sin(aStart) * R)
        -- 外圈终点（加一个中间点让弧更圆）
        local aMid = (aStart + aEnd) / 2
        table.insert(pts, wheelCX + math.cos(aMid) * R)
        table.insert(pts, wheelCY + math.sin(aMid) * R)
        table.insert(pts, wheelCX + math.cos(aEnd) * R)
        table.insert(pts, wheelCY + math.sin(aEnd) * R)
        -- 内圈终点 → 圆心
        table.insert(pts, wheelCX + math.cos(aEnd) * innerR)
        table.insert(pts, wheelCY + math.sin(aEnd) * innerR)
        table.insert(pts, wheelCX)
        table.insert(pts, wheelCY)
        love.graphics.polygon("fill", pts)
    end

    -- 轮盘外描边 + 金色光圈
    love.graphics.setColor(0.5, 0.4, 0.1)
    love.graphics.setLineWidth(4)
    love.graphics.circle("line", wheelCX, wheelCY, R)
    love.graphics.setColor(1, 0.85, 0.2, 0.5)
    love.graphics.setLineWidth(1.5)
    love.graphics.circle("line", wheelCX, wheelCY, R + 6)

    -- 轮盘内圈描边
    love.graphics.setColor(0.5, 0.4, 0.1)
    love.graphics.setLineWidth(2)
    love.graphics.circle("line", wheelCX, wheelCY, innerR)

    -- ========== 中心标题 ==========
    love.graphics.setFont(UI.cjkFontTitle)
    love.graphics.setColor(1, 0.85, 0.2)
    love.graphics.printf("Blackjack Cheater", 0, wheelCY - 40, W, "center")

    -- ========== 按钮（4 个：开始 / 教程 / 冠军牌组 / 退出） ==========
    -- 坐标已在函数开头的「布局推算」段算好（绘制与热区共用同一份结果），此处只负责画

    local mx, my = love.mouse.getPosition()
    local function drawBtn(y, label, color, hoverColor)
        local hover = mx >= btnX and mx <= btnX + btnW and my >= y and my <= y + btnH
        love.graphics.setColor(hover and hoverColor or color)
        love.graphics.rectangle("fill", btnX, y, btnW, btnH, 8)
        love.graphics.setColor(1, 1, 1, hover and 1 or 0.5)
        love.graphics.rectangle("line", btnX, y, btnW, btnH, 8)
        love.graphics.setFont(UI.cjkFontMid)
        -- 按字体行高在按钮内垂直居中（按钮缩小后原来的 y + 10 会把文字顶出按钮）
        love.graphics.printf(label, btnX, y + (btnH - UI.cjkFontMid:getHeight()) / 2, btnW, "center")
    end

    -- 冠军牌组：未通关困难模式时画成灰色且点击被拦（提示「通关困难模式后解锁」）
    local champUnlocked = Champion.isUnlocked(state)

    drawBtn(btnY1, "开始游戏", {0.25, 0.55, 0.25}, {0.35, 0.75, 0.35})
    drawBtn(btnY2, "教程",     {0.2, 0.35, 0.65}, {0.3, 0.5, 0.85})
    drawBtn(btnY3, "冠军牌组",
            champUnlocked and {0.45, 0.35, 0.65} or {0.26, 0.26, 0.28},
            champUnlocked and {0.6, 0.5, 0.9}    or {0.26, 0.26, 0.28})
    drawBtn(btnY4, "退出",     {0.55, 0.18, 0.18}, {0.8, 0.28, 0.28})

    -- 版本号
    love.graphics.setFont(UI.cjkFontSmall)
    love.graphics.setColor(0.45, 0.45, 0.45)
    love.graphics.printf("v1.2  ·  Love2D 11.5", 0, H - 30, W, "center")

    -- 记录按钮区域（供 main.lua 点击检测；绘制与点击共用同一份坐标）
    UI._titleButtons = {
        start    = { x = btnX, y = btnY1, w = btnW, h = btnH },
        tutorial = { x = btnX, y = btnY2, w = btnW, h = btnH },
        champion = { x = btnX, y = btnY3, w = btnW, h = btnH, unlocked = champUnlocked },
        quit     = { x = btnX, y = btnY4, w = btnW, h = btnH },
    }
end

-- ============================================================
-- 教程叠加层 — 动态位置 + 零遮罩（不挡任何交互区）
-- ============================================================
function UI.drawTutorialOverlay(state)
    if not state.tutorial or not state.tutorial.active then return end
    local Tutorial = require("src.tutorial")
    local phase = Tutorial.currentPhase(state)
    if not phase then return end

    local W = window_width; local H = window_height
    local sidebar_width = W * 0.12

    if not phase then return end
    -- 动态位置：数据驱动（遗物选择要避开居中的 3 张卡；激活遗物要让玩家看右侧遗物栏）
    -- 旧版写死 phase == 4/5，重编号后失效 —— 现在按阶段自带字段判断
    local pos = phase.pos or "right_top"

    local cardW = 460
    local cardH = 230
    local cardX, cardY

    if pos == "left_top" then
        cardX = 10
        cardY = 75
    else
        -- right_top: 避开 sidebar 和中央游戏区
        cardX = W - sidebar_width - cardW - 15
        cardY = 75
    end

    -- 取消全屏遮罩（改为只给卡片做轻微半透明）

    -- 卡片背景（轻微半透明 + 细边框，不挡下方游戏元素）
    love.graphics.setColor(0.05, 0.05, 0.08, 0.78)
    love.graphics.rectangle("fill", cardX, cardY, cardW, cardH, 8)
    love.graphics.setColor(1, 0.85, 0.2, 0.6)
    love.graphics.setLineWidth(1.5)
    love.graphics.rectangle("line", cardX, cardY, cardW, cardH, 8)
    love.graphics.setLineWidth(1)

    -- 阶段进度（总数从数据表取 —— 旧版写死 10，扩到 20 步后会显示错）
    local totalPhases = #Tutorial.PHASES
    local currentPhase = state.tutorial.phase
    love.graphics.setFont(UI.cjkFontSmall)
    love.graphics.setColor(0.6, 0.6, 0.6)
    love.graphics.printf("教程 " .. currentPhase .. "/" .. totalPhases, cardX + 8, cardY + 6, cardW - 16, "right")

    -- "继续" 按钮几何（提前算出：正文的下界要用它；取值与原来完全一致）
    local btnW = 120; local btnH = 34
    local btnX = cardX + cardW - btnW - 12
    local btnY = cardY + cardH - btnH - 10

    -- 标题：可用高度到正文起始 y 为止，放不下则截断并以 "..." 结尾
    local titleY = cardY + 30
    local bodyY = cardY + 65
    love.graphics.setFont(UI.cjkFontMid)
    love.graphics.setColor(1, 0.85, 0.2)
    local titleShown = UI.fitTextEllipsis(phase.title, UI.cjkFontMid, cardW - 30, bodyY - titleY)
    love.graphics.printf(titleShown, cardX + 15, titleY, cardW - 30, "left")

    -- 正文：下界 = 阻塞提示那一行（btnY - 18），放不下则截断并以 "..." 结尾
    love.graphics.setFont(UI.cjkFontSmall)
    love.graphics.setColor(0.92, 0.92, 0.92)
    local bodyShown = UI.fitTextEllipsis(phase.body, UI.cjkFontSmall, cardW - 30, (btnY - 18) - bodyY)
    love.graphics.printf(bodyShown, cardX + 15, bodyY, cardW - 30, "left")

    -- "继续" 按钮（或阻塞提示）
    local mx, my = love.mouse.getPosition()
    local hover = mx >= btnX and mx <= btnX + btnW and my >= btnY and my <= btnY + btnH

    local blocked, hint = Tutorial.isBlockedContinue(state)

    if blocked then
        love.graphics.setColor(0.3, 0.3, 0.3, 0.8)
        love.graphics.rectangle("fill", btnX, btnY, btnW, btnH, 5)
        love.graphics.setColor(0.7, 0.7, 0.7)
        love.graphics.setFont(UI.cjkFontSmall)
        love.graphics.printf("[锁] 继续", btnX, btnY + 6, btnW, "center")

        love.graphics.setFont(UI.cjkFontSmall)
        love.graphics.setColor(1, 0.7, 0.3)
        love.graphics.printf(hint or "完成操作后继续", cardX + 15, btnY - 18, cardW - btnW - 40, "right")
    else
        love.graphics.setColor(hover and {0.3, 0.8, 0.3} or {0.18, 0.55, 0.18})
        love.graphics.rectangle("fill", btnX, btnY, btnW, btnH, 5)
        love.graphics.setColor(1, 1, 1)
        love.graphics.setFont(UI.cjkFontSmall)
        love.graphics.printf("继续 →", btnX, btnY + 6, btnW, "center")
    end

    UI._tutorialContinueBtn = { x = btnX, y = btnY, w = btnW, h = btnH }
end

return UI
