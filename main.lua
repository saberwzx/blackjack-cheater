-- ============================================================
-- main.lua — Love2D 入口（组合根 + 输入分发层）
--
-- 分层结构（谁调用谁）:
--   main.lua      本文件：love.* 回调 → 读 UI 写入的热区 → 调 GameState 的规则函数
--   ui/ui.lua     表现层：只读 state 绘制画面，可点区域写进 UI._xxxBtns 热区表
--   src/          规则层：game_state（核心规则）/ bar_mode（酒吧模式）/ 其余叶子模块
--
-- 输入分发顺序（mousepressed / keypressed）：forceExit → 模态弹窗（说明弹窗、
-- 编辑器、替换面板、酒吧模态、设置页、情报面板）→ 左上角入口 → 各状态处理器。
-- 点击热区永远来自 ui.lua 绘制时写入的同一份数据（hitRect 单一数据源）。
-- ============================================================

math.lerp = function(a, b, t) return a + (b - a) * math.min(t, 1) end

-- 本地调试桥（lovepilot，不入库）：设 BJC_MCP=1 时开启游戏内 TCP 服务（端口 12345），
-- 供外部工具实时查看状态 / 注入输入 / 截图 / 执行 Lua / 热更代码。发布版走空实现。
local mcp_bridge
if os.getenv("BJC_MCP") == "1" then
    local ok, mod = pcall(require, "mcp_bridge")
    mcp_bridge = ok and mod or nil
end
if not mcp_bridge then
    mcp_bridge = {
        init = function() end,
        setObjectGetter = function() end,
        update = function() end,
        captureIfPending = function() end,
        shutdown = function() end,
    }
end

local EventManager = require("src.event_manager")
local GameState = require("src.game_state")
local Relics = require("src.relics")
local Tween = require("src.tween")
local Persist = require("src.persist")
local Champion = require("src.champion")
local BarLines = require("src.bar_lines")

local state = nil
local UI = nil

-- 下注滑条状态
local sliderDragging = false
local sliderBetAmount = 0

-- AABB 热区命中：b 为 ui.lua 绘制时写入的矩形热区表（单一数据源），nil 视为未命中
local function hitRect(b, x, y)
    return b ~= nil and x >= b.x and x <= b.x + b.w and y >= b.y and y <= b.y + b.h
end

-- 教程动作上报：tutorial 未激活时静默忽略
local function notifyTutorial(st, event)
    if st.tutorial and st.tutorial.active then
        require("src.tutorial").onPlayerAction(st, event)
    end
end

function love.load()
    love.keyboard.setTextInput(false)
    love.keyboard.setKeyRepeat(true)

    -- ===== 统一随机种子 =====
    -- Lua 原生 math.random 默认种子固定（每次启动序列相同，会产生"庄家职阶总抽到同一个"
    -- 之类的偏置现象）。这里显式播种，且全工程统一改用 love.math.random。
    local seed = os.time() + math.floor(love.timer.getTime() * 1000)
    love.math.setRandomSeed(seed)
    math.randomseed(seed)

    state = GameState.new()
    game = state

    -- MCP 桥：初始化 TCP 服务，并把状态 / UI 模块暴露给外部工具
    -- （run_lua 的沙箱环境里可通过 objects.state / objects.UI 访问）
    mcp_bridge.init(12345)
    mcp_bridge.setObjectGetter(function()
        return { state = state, game = game, UI = UI, GS = GameState, BarLines = BarLines }
    end)

    -- ===== 加载存档（游玩记录 + 冠军牌组）=====
    -- 存档目录不存在 / 文件损坏 / 目录不可写 时一律静默降级为默认值，不报错退出
    Persist.applyToState(state)
    print("[persist] 存档目录: " .. Persist.getDir()
          .. (Persist.dirExists() and "  (已存在)" or "  (尚未创建)"))

    local ok, UI_module = pcall(require, 'ui.ui')
    if not ok then error("UI 加载失败: " .. tostring(UI_module)) end
    UI = UI_module

    -- 按存档恢复分辨率 / 全屏（无存档时是默认值，等价于不改窗口）
    local savedRes = UI.RESOLUTIONS[state.settings.resolutionIndex or 1]
    if savedRes and love.window and love.window.setMode then
        local curW, curH = love.graphics.getWidth(), love.graphics.getHeight()
        local curFs = love.window.getFullscreen and love.window.getFullscreen() or false
        if curW ~= savedRes.w or curH ~= savedRes.h or curFs ~= state.settings.fullscreen then
            love.window.setMode(savedRes.w, savedRes.h,
                { fullscreen = state.settings.fullscreen, resizable = true })
        end
    end

    UI.refreshLayout()   -- 统一刷新坐标

    UI.loadResources()

    -- 初始化 BGM
    local BGM = require("src.bgm")
    BGM.init()
    _G.BGM = BGM

    -- 初始化音效（程序化合成，无需外部文件）
    local Sfx = require("src.sfx")
    Sfx.init()
    _G.Sfx = Sfx

    -- 应用设置初始值
    if state.settings and state.settings.volume and love.audio and love.audio.setVolume then
        love.audio.setVolume(state.settings.volume)
        BGM.setVolume(state.settings.volume)
    end
    -- 初始状态是 title 主菜单，玩家点击后才开始游戏
    print("[main.lua] 初始化完成 — 等待主菜单输入")
end

-- 窗口大小变化时（用户拖窗口 / 最大化 / setMode 后 LÖVE 内部也会触发）
function love.resize(w, h)
    UI.refreshLayout()
end

function love.update(dt)
    mcp_bridge.update()   -- MCP：轮询外部命令（必须在每帧调用）
    Tween.updateAll(dt)
    GameState.updateVisuals(state, dt)

    -- 音效盖过 BGM：播放期间 BGM 让位（暂停），播完从暂停处续播。
    -- 必须在 BGM.update 之前判定：forceExit 帧里 update 会先把阶段曲 stop 掉，那样就没有进度可续。
    if Sfx.isOverlayPlaying() then
        BGM.yieldToSfx(state.state == "forceExit")
    elseif BGM.isYielding() then
        BGM.resumeFromSfx()
    end

    BGM.update(state)

    -- 下注滑条拖拽中
    if sliderDragging and state.state == "bet" then
        local mx = love.mouse.getX()
        -- 赊账上限与 placeBet / drawBetSlider 同一口径（Relics.getCreditInfo）
        local _, creditLimit = Relics.getCreditInfo(state)
        sliderBetAmount = UI.updateSliderBet(mx, state.player.chips + creditLimit)
    end
    -- 同步到 state 让 UI 绘制
    state._sliderBet = sliderBetAmount

    if state.state == "forceExit" then
        state.quitTimer = state.quitTimer - dt
        if state.quitTimer <= 0 then
            -- 破产 → 回标题界面（不是退出进程）
            state.state = "title"
            state.quitTimer = nil
            state.exitReason = ""
        end
    end

    if UI and UI.dealer and UI.dealer.bounceVel then
        local d = UI.dealer
        d.currY = d.currY + d.bounceVel * dt
        d.bounceVel = d.bounceVel + d.gravity * dt
        if d.currY > d.groundY then
            d.currY = d.groundY
            d.bounceVel = -d.bounceVel * d.damp
            if math.abs(d.bounceVel) < 50 then d.bounceVel = 0 end
        end
    end
end

function love.draw()
    if state.screenShake and state.screenShake > 0 then
        love.graphics.push()
        love.graphics.translate(
            (math.random() - 0.5) * state.screenShake,
            (math.random() - 0.5) * state.screenShake
        )
    end

    love.graphics.setBackgroundColor(0.2, 0.5, 0.2)
    if UI and UI.drawAll then
        UI.drawAll(state)
    end

    -- 视觉爽感：数字弹出
    if state.scorePopups then
        love.graphics.setFont(UI and UI.splash and UI.splash.titleFont or love.graphics.newFont(48))
        for _, p in ipairs(state.scorePopups) do
            local alpha = math.max(0, 1 - p.t / p.life)
            love.graphics.setColor(p.color[1], p.color[2], p.color[3], alpha)
            love.graphics.printf(p.text, p.x - 100 * p.scale, p.y, 200 * p.scale, "center")
        end
        love.graphics.setColor(1, 1, 1)
    end

    if state.screenShake and state.screenShake > 0 then
        love.graphics.pop()
    end

    if state.state == "forceExit" then
        -- 全屏红色背景闪烁
        local blink = math.sin(love.timer.getTime() * 8) * 0.15 + 0.35  -- 0.2~0.5 闪烁
        love.graphics.setColor(blink, 0, 0, 0.9)
        love.graphics.rectangle("fill", 0, 0, love.graphics.getWidth(), love.graphics.getHeight())

        local W, H = love.graphics.getWidth(), love.graphics.getHeight()
        -- 纵向锚点按屏高推导（800×600 时与旧版固定值逐一相等）
        local isBar = (state.gameMode == "bar")
        local hugeFont = (UI and UI.cjkFontTitle) or (UI and UI.cjkFontLarge) or love.graphics.newFont(80)
        local midFont = (UI and UI.cjkFontMid) or love.graphics.newFont(28)

        if isBar then
            -- 酒吧模式：被酒保请出去（不得出现「没钱」，不显示最终筹码）
            love.graphics.setFont(hugeFont)
            love.graphics.setColor(1, 0.08, 0.08)
            love.graphics.printf("被请出去了", 0, H * 13 / 30, W, "center")

            love.graphics.setFont(midFont)
            love.graphics.setColor(1, 0.85, 0.85)
            local reason = state.exitReason
            if not reason or reason == "" then
                reason = "调酒栏空了 —— 酒保把你请了出去。"
            end
            love.graphics.printf(reason, 0, H * 19 / 30, W, "center")
            love.graphics.printf("倒计时 " .. math.ceil(state.quitTimer) .. " 秒退出...",
                0, H * 7 / 10, W, "center")
        else
            -- 超级大红色字
            love.graphics.setFont(hugeFont)
            love.graphics.setColor(1, 0.08, 0.08)
            love.graphics.printf("卧槽没钱给我滚出去！", 0, H * 13 / 30, W, "center")

            -- 倒计时 + 最终筹码
            love.graphics.setFont(midFont)
            love.graphics.setColor(1, 0.85, 0.85)
            love.graphics.printf(
                "倒计时 " .. math.ceil(state.quitTimer) .. " 秒退出...    最终筹码: $" .. state.player.chips,
                0, H * 2 / 3, W, "center")
        end
    end

    -- MCP：处理挂起的截图请求（必须是 love.draw 的最后一行，保证截到完整画面）
    mcp_bridge.captureIfPending()
end

-- ============================================================
-- 鼠标
-- ============================================================
function love.mousepressed(x, y, button)
    if state.state == "forceExit" then return end

    -- 阶段 2 说明弹窗（模态，独占输入，优先级最高）：纯阅读，唯一出口是点确认
    if state._stage2BriefOpen then
        if hitRect(UI._stage2BriefBtn, x, y) then
            state._stage2BriefOpen = false
        end
        return
    end

    -- 冠军牌组编辑界面（模态，独占输入，优先级等同 classOffer）
    if state.state == "deckEditor" then
        handleDeckEditorClick(x, y); return
    end

    -- Caster 遗物替换面板（模态，独占输入，盖在所有东西之上）
    if state.state == "classOffer" then
        handleClassOfferClick(x, y); return
    end

    -- ========== 酒吧模式：独占输入分发（热区由 ui.lua 绘制时写入，单一数据源）==========
    -- handleBarModeClick 返回 true = 点击已消费（模态吞掉或命中热区）；
    -- false = 放行（如 player 阶段未命中任何酒吧热区，继续走下方原有逻辑）
    if state.gameMode == "bar" and handleBarModeClick(x, y) then return end

    -- 设置页打开时拦截所有点击（总是吞掉：按钮命中执行 onClick，点弹窗外关闭）
    if state.settingsOpen then
        handleSettingsClick(x, y); return
    end

    -- 牌堆总览弹窗打开时拦截点击（点关闭按钮或弹窗外关闭，总是吞掉）
    if state.deckOverviewOpen then
        handleDeckOverviewClick(x, y); return
    end

    -- 牌靴情报面板打开时拦截点击（点关闭按钮或面板外关闭，总是吞掉）
    if state._shoeInfoOpen then
        handleShoeInfoClick(x, y); return
    end

    -- 左上角设置入口按钮（非 modal 状态下可点）
    if UI._settingsEntryBtn and not state.settingsOpen then
        if hitRect(UI._settingsEntryBtn, x, y) then
            state.settingsOpen = true; return
        end
    end

    -- 左上角小牌堆入口按钮（点击复用 D 键逻辑）
    if UI._deckEntryBtn and not state.deckOverviewOpen then
        if hitRect(UI._deckEntryBtn, x, y) then
            state.deckOverviewOpen = true
            state._shoeInfoOpen = false   -- 同级互斥
            notifyTutorial(state, "deck_opened")   -- 教程追踪：点击打开也算 deck_opened
            return
        end
    end

    -- 牌靴情报入口按钮（牌堆入口正下方；点击与 I 键同逻辑）
    if UI._shoeEntryBtn and not state._shoeInfoOpen then
        if hitRect(UI._shoeEntryBtn, x, y) then
            state._shoeInfoOpen = true
            state.deckOverviewOpen = false   -- 同级互斥
            return
        end
    end

    -- 主菜单
    if state.state == "title" then
        local btns = UI._titleButtons
        if btns then
            if hitRect(btns.start, x, y) then
                state.state = "modeSelect"; return   -- 先选模式，再开始
            elseif hitRect(btns.tutorial, x, y) then
                GameState.startTutorial(state); return
            elseif btns.champion and hitRect(btns.champion, x, y) then
                -- 未通关困难模式时按钮灰色不可用：点击只提示，不进入编辑器
                if Champion.isUnlocked(state) then
                    GameState.openDeckEditor(state)
                else
                    state._flashMsg = { text = "通关困难模式后解锁", expires = love.timer.getTime() + 2 }
                end
                return
            elseif hitRect(btns.quit, x, y) then
                love.event.quit(); return
            end
        end
        return
    end

    -- 模式选择（选完 startNewGame 由这里统一调）
    if state.state == "modeSelect" then
        handleModeSelectClick(x, y); return
    end

    -- 教程叠加层的"继续"按钮（覆盖在所有游戏逻辑之上）
    if state.tutorial and state.tutorial.active then
        if hitRect(UI._tutorialContinueBtn, x, y) then
            require("src.tutorial").onClickContinue(state)
            return
        end
    end

    -- 开局遗物选择
    if state.state == "relic_select" and state.pendingRelics then
        handleStarterRelicClick(x, y)
        notifyTutorial(state, "relic_picked")   -- 教程追踪: Phase 4 遗物选择
        return
    end

    -- 商店
    if state.state == "shop" then
        handleShopClick(x, y)
        notifyTutorial(state, "shop_bought")   -- 教程追踪
        return
    end

    -- 结算 / 阶段 / 通关（含职阶选择）：点击推进流程
    if handleFlowStateClick(x, y) then return end

    -- 爆注开关（阶段3）：下注阶段点击切换（与 B 键同逻辑）
    if state.state == "bet" and UI._bustBetBtn and hitRect(UI._bustBetBtn, x, y) then
        state._bustBetOn = not state._bustBetOn
        return
    end

    -- 下注状态 — 检查滑条（未命中放行给底部金额按钮）
    if state.state == "bet" and handleBetSliderClick(x, y) then return end

    -- 牌桌明牌点击 → 花标记费做记号（三入口之一：牌桌 / 牌库槽位 / 弃牌堆）
    if state.state == "player" and UI._handMarkBtns then
        for _, hb in ipairs(UI._handMarkBtns) do
            if hitRect(hb, x, y) then
                GameState.markHandCard(state, hb.side, hb.index)
                return
            end
        end
    end

    -- player / bet 状态 — 点击遗物 toggle 激活（职阶残卷要在下注前点亮才赶得上发牌时机）
    if (state.state == "player" or state.state == "bet") and #state.relics > 0 then
        local hit = UI.hitTestRelicBar(x, y, state)
        if hit then
            GameState.toggleRelicActive(state, hit.index)
            notifyTutorial(state, "relic_activated")   -- 教程追踪: Phase 5 激活遗物
            return
        end
    end

    -- 游戏按钮
    if state.state == "bet" then
        handleBetButtons(x, y)
    elseif state.state == "player" then
        handleGameButtons(x, y)
    end
end

function love.mousereleased(x, y, button)
    sliderDragging = false
end

function love.quit()
    mcp_bridge.shutdown()   -- MCP：退出前关掉 TCP 服务
end

function love.mousemoved(x, y)
    if sliderDragging then
        sliderBetAmount = UI.updateSliderBet(x, state.player.chips)
    end
end

function love.wheelmoved(x, y)
    -- 冠军牌组编辑界面：滚轮滚动牌池（模态，独占输入）
    if state.state == "deckEditor" then
        local maxScroll = UI.getDeckEditorMaxScroll and UI.getDeckEditorMaxScroll(state) or 0
        local s = (state.deckEditorScroll or 0) + (y > 0 and -1 or 1)
        if s < 0 then s = 0 end
        if s > maxScroll then s = maxScroll end
        state.deckEditorScroll = s
        return
    end
    -- 主动技能选牌模态：滚轮滚动候选列表（模态独占）
    if state.state == "bar_alcpick" then
        local pick = state._barAlcPick
        if pick then
            local maxScroll = UI._barAlcPickMaxScroll or 0
            local s = (pick.scroll or 0) + (y > 0 and -1 or 1)
            if s < 0 then s = 0 end
            if s > maxScroll then s = maxScroll end
            pick.scroll = s
        end
        return
    end
    -- 主动技能展开列表：光标落在列表内时滚轮滚动（生效酒多时列表限高，滚轮翻看）
    -- 滚动状态 UI._alcMenuScroll / 上限 UI._alcMenuMaxScroll 由 ui.lua 绘制时写入，单一数据源
    if state.gameMode == "bar" and state._barAlcOpen then
        local rect = UI._alcMenuRect
        local mx, my = love.mouse.getPosition()
        if rect and hitRect(rect, mx, my) then
            local maxScroll = UI._alcMenuMaxScroll or 0
            local s = (UI._alcMenuScroll or 0) + (y > 0 and -1 or 1)
            if s < 0 then s = 0 end
            if s > maxScroll then s = maxScroll end
            UI._alcMenuScroll = s
            return
        end
    end
    if state.deckOverviewOpen then
        if y > 0 then state.deckOverviewScroll = (state.deckOverviewScroll or 0) - 1
        else        state.deckOverviewScroll = (state.deckOverviewScroll or 0) + 1 end
    end
    -- 牌靴情报面板·顺序带/弃牌堆页签：滚轮翻页（行步进，钳制在 ui.lua 绘制时做）
    if state._shoeInfoOpen and state._shoeInfoTab == "discard" then
        if y > 0 then state._shoeInfoDiscardScroll = (state._shoeInfoDiscardScroll or 0) - 1
        else        state._shoeInfoDiscardScroll = (state._shoeInfoDiscardScroll or 0) + 1 end
    end
    if state._shoeInfoOpen and (state._shoeInfoTab == "strip" or state._shoeInfoTab == nil) then
        if y > 0 then state._shoeInfoStripScroll = (state._shoeInfoStripScroll or 0) - 1
        else        state._shoeInfoStripScroll = (state._shoeInfoStripScroll or 0) + 1 end
    end
end

-- ============================================================
-- 键盘
-- ============================================================
function love.keypressed(key)
    if state.state == "forceExit" then return end

    -- ========== 酒吧模式：模态独占输入（吞掉所有按键，避免点穿到设置页）==========
    -- handleBarModeKey 返回 true = 按键已消费；false = 放行（非模态状态照常走后续链）
    if state.gameMode == "bar" and handleBarModeKey(key) then return end

    -- 阶段 2 说明弹窗（模态，独占输入）：纯阅读，ESC 也不跳过，只吞掉所有按键
    if state._stage2BriefOpen then
        if key == "return" or key == "space" or key == "kpenter" then
            state._stage2BriefOpen = false
        end
        return
    end

    -- 冠军牌组编辑界面（模态，独占输入）：ESC 关闭编辑器回主界面（丢弃未保存的改动）
    if state.state == "deckEditor" then
        if key == "escape" then GameState.closeDeckEditor(state) end
        return
    end

    -- ========== 最高优先级：modal 状态独占输入 ==========
    -- modal = shop / relic_select — 这些状态下所有其他浮层/热键必须让位
    local isModal = (state.state == "shop") or (state.state == "relic_select") or (state.state == "classOffer")
    if isModal then
        -- modal 里必须先关掉任何残留的浮层（防止它们吃掉按键）
        if state.settingsOpen then state.settingsOpen = false end
        if state.deckOverviewOpen then state.deckOverviewOpen = false end
        if state._shoeInfoOpen then state._shoeInfoOpen = false end
        if state.state == "shop" then handleShopKey(key); return end
        if state.state == "classOffer" then
            -- 1/2/3 = 选候选（必须先点过自己要被替换的遗物，否则 no-op）
            -- ESC / Enter = 不换（关闭面板，回到打开前的状态）
            if key >= "1" and key <= "3" then
                GameState.takeClassOffer(state, tonumber(key))
            elseif key == "escape" or key == "return" then
                GameState.closeClassOffer(state)
            end
            return
        end
        if state.state == "relic_select" and state.pendingRelics then
            if key >= "1" and key <= "3" then
                GameState.selectStarterRelic(state, tonumber(key))
            end
            -- ESC 不能跳过！必须选一个遗物才能开局
            return
        end
    end

    -- ========== ESC 浮层优先级链（modal 之外）==========
    if state.settingsOpen then
        if key == "escape" then state.settingsOpen = false; return end
        return  -- 设置页开时拦截所有其他按键
    end

    -- 2. D 键 toggle 牌堆总览（必须在 deckOverviewOpen 拦截之前，否则 toggle 会被吃掉）
    if key == "d" or key == "D" then
        local wasOpen = state.deckOverviewOpen == true
        state.deckOverviewOpen = not state.deckOverviewOpen
        if state.deckOverviewOpen then state._shoeInfoOpen = false end   -- 两个面板同级互斥
        -- 教程追踪：区分"打开"和"关闭"两个独立动作
        if not wasOpen and state.deckOverviewOpen then
            notifyTutorial(state, "deck_opened")
        elseif wasOpen and not state.deckOverviewOpen then
            notifyTutorial(state, "deck_closed")
        end
        return
    end

    -- 2.5 I 键 toggle 牌靴情报面板（与牌堆总览同级互斥）
    if key == "i" or key == "I" then
        state._shoeInfoOpen = not state._shoeInfoOpen
        if state._shoeInfoOpen then state.deckOverviewOpen = false end
        return
    end

    -- 3. 牌堆总览浮层（次顶层）
    if state.deckOverviewOpen then
        handleDeckOverviewKey(key); return
    end

    -- 3.5 牌靴情报浮层（次顶层，ESC 关闭、顺序带/弃牌堆可翻页，拦截其余按键）
    if state._shoeInfoOpen then
        if key == "escape" then
            state._shoeInfoOpen = false
        elseif state._shoeInfoTab == "discard" then
            if key == "up" then state._shoeInfoDiscardScroll = (state._shoeInfoDiscardScroll or 0) - 1
            elseif key == "down" then state._shoeInfoDiscardScroll = (state._shoeInfoDiscardScroll or 0) + 1
            elseif key == "pageup" then state._shoeInfoDiscardScroll = (state._shoeInfoDiscardScroll or 0) - 3
            elseif key == "pagedown" then state._shoeInfoDiscardScroll = (state._shoeInfoDiscardScroll or 0) + 3 end
        else
            -- 顺序带（默认页）：后拉/前推
            if key == "up" or key == "pageup" then state._shoeInfoStripScroll = (state._shoeInfoStripScroll or 0) - 3
            elseif key == "down" then state._shoeInfoStripScroll = (state._shoeInfoStripScroll or 0) + 1
            elseif key == "pagedown" then state._shoeInfoStripScroll = (state._shoeInfoStripScroll or 0) + 3 end
        end
        return
    end

    -- 4. 所有浮层都关了 → ESC 默认行为
    if key == "escape" then
        if state.state == "modeSelect" then
            state.state = "title"; return
        end
        state.settingsOpen = true; return
    end

    -- 结算 / 阶段 / 通关：任意键推进
    if handleFlowStateKey(key) then return end

    -- 下注状态 — 数字键快捷金额
    if state.state == "bet" then
        handleBetKey(key); return
    end

    -- 玩家行动
    if state.state == "player" then
        handlePlayerActionKey(key)
    end
end

-- ============================================================
-- 按钮
-- ============================================================

-- 酒吧模式点击分发（热区由 ui.lua 绘制时写入，绘制与点击同源）。
-- 返回 true = 点击已消费；false = 放行（未命中任何酒吧热区，继续原有逻辑）
function handleBarModeClick(x, y)
    -- 说明弹窗（两页，模态）：唯一出口是「下一页 / 开始」按钮
    if state.state == "bar_brief" then
        if hitRect(UI._barBriefBtn, x, y) then
            GameState.barBriefNext(state)
        end
        return true
    end
    -- 结局画面：点按钮或任意处都回主界面
    if state.state == "bar_ending" then
        state.state = "title"
        state.barEnding = nil
        return true
    end
    -- 赠酒三选一弹窗（模态）
    if state.state == "bar_gift" then
        if UI._barGiftBtns then
            for _, btn in ipairs(UI._barGiftBtns) do
                if hitRect(btn, x, y) then
                    GameState.barPickGift(state, btn._index)
                    return true
                end
            end
        end
        return true   -- 模态独占：未命中也不许点穿
    end
    -- 喝酒选择弹窗（模态）
    if state.state == "bar_drink" then
        if UI._barDrinkBtns then
            for _, btn in ipairs(UI._barDrinkBtns) do
                if hitRect(btn, x, y) then
                    GameState.barPickDrink(state, btn._index)
                    return true
                end
            end
        end
        return true   -- 模态独占：未命中也不许点穿
    end
    -- 主动技能选牌模态（独占输入）：取消 / 确认 / 选牌，一律不许点穿
    if state.state == "bar_alcpick" then
        handleBarAlcPickClick(x, y)
        return true
    end
    -- 要牌阶段点调酒栏 → 主动喝一口（未命中则放行，允许顺手点遗物栏 / 牌桌按钮）
    if state.state == "player"
       and not (state._barBriefOpen or state._barGiftOpen or state._barDrinkOpen)
       and not state.settingsOpen and not state.deckOverviewOpen and not state._shoeInfoOpen then
        -- 顶栏右「说明」入口 → 重看开局两页说明（模态；关闭后回 player，不动小局数据）
        -- 与调酒键同时命中时以「说明」优先：它只占顶栏一条，不会和牌桌按钮重叠
        local hb = UI._barHelpBtn
        if hb and hb.enabled and hitRect(hb, x, y) then
            GameState.barOpenBrief(state)
            return true
        end
        -- 调酒键 + 主动技能展开列表（热区同源：ui.lua 绘制时写入）
        local ab = UI._alcBtn
        if ab and hitRect(ab, x, y) then
            if state._barAlcOpen then
                state._barAlcOpen = nil          -- 再点一次键 → 收起
            else
                state._barAlcOpen = true         -- 打开时清掉其它浮层，避免叠在一起
                state.settingsOpen = false
                state.deckOverviewOpen = false
                state._shoeInfoOpen = false
            end
            return true
        end
        if state._barAlcOpen then
            local hitRow = false
            if UI._alcMenuBtns then
                for _, btn in ipairs(UI._alcMenuBtns) do
                    if hitRect(btn, x, y) then
                        hitRow = true
                        if btn.enabled then GameState.barAbilityRun(state, btn.id) end
                        break
                    end
                end
            end
            if hitRow then return true end       -- 命中行（含灰显行）一律吞掉
            state._barAlcOpen = nil              -- 列表内空白处 / 列表外 → 收起
            if hitRect(UI._alcMenuRect, x, y) then
                return true
            end
            -- 列表外收起后继续往下走（允许顺手点调酒栏喝一口）
        end
        if UI._barCupsBtns then
            for _, btn in ipairs(UI._barCupsBtns) do
                if hitRect(btn, x, y) then
                    GameState.barManualDrink(state, btn._index)
                    return true
                end
            end
        end
    end
    return false
end

-- 设置页点击：按钮命中执行 onClick，点弹窗外关闭；总是吞掉
function handleSettingsClick(x, y)
    if UI._settingsBtns then
        for _, btn in ipairs(UI._settingsBtns) do
            if hitRect(btn, x, y) then
                btn.onClick(); return
            end
        end
    end
    -- 点弹窗外关闭
    local area = UI._settingsArea
    if area and not hitRect(area, x, y) then
        state.settingsOpen = false; return
    end
end

-- 牌堆总览点击：关闭按钮 / 弹窗外关闭；总是吞掉
function handleDeckOverviewClick(x, y)
    if hitRect(UI._deckOverviewCloseBtn, x, y) then
        state.deckOverviewOpen = false
        notifyTutorial(state, "deck_closed")
        return
    end
    local area = UI._deckOverviewArea
    if area and not hitRect(area, x, y) then
        -- 点弹窗外面也关
        state.deckOverviewOpen = false
        notifyTutorial(state, "deck_closed")
        return
    end
    -- 弹窗内其他点击都拦截
end

-- 牌靴情报面板点击：页签 / 标记槽位 / 关闭按钮 / 面板外关闭；总是吞掉
function handleShoeInfoClick(x, y)
    if hitRect(UI._shoeInfoCloseBtn, x, y) then
        state._shoeInfoOpen = false
        return
    end
    -- 页签切换
    if UI._shoeInfoTabBtns then
        if hitRect(UI._shoeInfoTabBtns.strip, x, y) then
            state._shoeInfoTab = "strip"; return
        end
        if hitRect(UI._shoeInfoTabBtns.ledger, x, y) then
            state._shoeInfoTab = "ledger"; return
        end
        if hitRect(UI._shoeInfoTabBtns.discard, x, y) then
            state._shoeInfoTab = "discard"; return
        end
    end
    -- 顺序带槽位：钓具武装时点击已标记的牌 = 目标；否则标记 / 取消（tryMarkCard 内部路由）
    if UI._shoeSlotBtns then
        for _, s in ipairs(UI._shoeSlotBtns) do
            if hitRect(s, x, y) then
                if s.enabled then
                    if state._rodArmed and s.marked then
                        GameState.rodTarget(state, s.slotIndex, s.x + s.w / 2, s.y + s.h / 2)
                    elseif state._rodArmed then
                        state._flashMsg = { text = "钓具武装中：请点击已标记的牌",
                                            expires = love.timer.getTime() + 2 }
                    else
                        GameState.markCardAt(state, s.slotIndex)
                    end
                end
                return
            end
        end
    end
    -- 弃牌堆卡牌：打捞武装时 = 选定打出目标；否则标记 / 取消（tryMarkCard 内部路由）
    if UI._shoeDiscardBtns then
        for _, s in ipairs(UI._shoeDiscardBtns) do
            if hitRect(s, x, y) then
                if s.enabled then
                    if state._salvagerArmed then
                        GameState.salvagePick(state, s.index)
                    else
                        GameState.markDiscardAt(state, s.index)
                    end
                end
                return
            end
        end
    end
    local area = UI._shoeInfoArea
    if area and not hitRect(area, x, y) then
        state._shoeInfoOpen = false
        return
    end
    -- 面板内其他点击都拦截
end

-- 模式选择点击：命中即按模式开局；总是吞掉
function handleModeSelectClick(x, y)
    if UI._modeSelectBtns then
        for _, btn in ipairs(UI._modeSelectBtns) do
            if hitRect(btn, x, y) then
                state.settings.gameMode = btn._mode
                -- 酒吧模式不写存档（需求：不累计游玩局数）；基础/困难模式行为不变
                if btn._mode ~= "bar" then
                    Persist.startRun(state)           -- 累计游玩局数 +1 并写盘
                end
                GameState.startNewGame(state)  -- 内部会读 state.settings.gameMode
                return
            end
        end
    end
end

-- 结算 / 阶段 / 通关 / 职阶选择：点击推进流程；返回是否消费点击
function handleFlowStateClick(x, y)
    if state.state == "result" then
        GameState.resetRound(state); return true
    end
    if state.state == "stageClear" then
        GameState.resetRound(state)
        notifyTutorial(state, "stage_cleared")   -- 教程追踪
        return true
    end
    if state.state == "classSelect" then
        -- 点卡片选职阶
        if UI._classSelectCards then
            for _, c in ipairs(UI._classSelectCards) do
                if hitRect(c, x, y) then
                    local Classes = require("src.classes")
                    -- 用运行时副本：避免把 _consumed 等运行时标记写进 Classes.ALL 全局定义
                    state.class = Classes.getRuntime(c.id)
                    state.classCharges = (state.class and state.class.charges) or 0
                    GameState.resetRound(state)
                    return true
                end
            end
        end
        return true
    end
    if state.state == "victory" then
        state.state = "title"; return true
    end
    return false
end

-- 下注滑条点击：拖拽滑条或确认下注；返回是否命中（未命中放行给底部金额按钮）
function handleBetSliderClick(x, y)
    -- 滑条区域？
    if UI.isInSlider(x, y) then
        sliderDragging = true
        sliderBetAmount = UI.updateSliderBet(x, state.player.chips)
        return true
    end
    -- 确认下注按钮？
    if UI.isInSliderConfirm(x, y) and sliderBetAmount >= 1 then
        GameState.placeBet(state, sliderBetAmount)
        sliderBetAmount = 0
        notifyTutorial(state, "bet_placed")   -- 教程追踪: Phase 1 下注
        return true
    end
    return false
end

-- 酒吧模式按键分发：模态状态一律吞掉；返回是否消费
function handleBarModeKey(key)
    if state.state == "bar_brief" then
        -- 两页说明：ESC / 空格 / 回车都能前进（第 1 页只翻页，不关闭）
        if key == "return" or key == "space" or key == "kpenter" or key == "escape" then
            GameState.barBriefNext(state)
        end
        return true
    end
    if state.state == "bar_ending" then
        if key == "return" or key == "space" or key == "kpenter" or key == "escape" then
            state.state = "title"
            state.barEnding = nil
        end
        return true
    end
    if state.state == "bar_alcpick" then
        -- 模态独占：ESC = 取消（不消耗次数），其余按键一律吞掉
        if key == "escape" then
            GameState.barAbilityPickCancel(state)
        end
        return true
    end
    if state.state == "bar_gift" or state.state == "bar_drink" then
        return true   -- 模态独占：纯鼠标选择，吞掉所有按键
    end
    -- 主动技能展开列表：ESC 收起（列表不是模态，其余按键照常放行）
    if state._barAlcOpen and key == "escape" then
        state._barAlcOpen = nil
        return true
    end
    return false
end

-- 牌堆总览按键：ESC 关闭 + 滚动快捷键；总是拦截
function handleDeckOverviewKey(key)
    if key == "escape" then
        state.deckOverviewOpen = false
        notifyTutorial(state, "deck_closed")   -- 教程追踪：ESC 关闭也算 deck_closed
        return
    end
    if key == "up"       then state.deckOverviewScroll = (state.deckOverviewScroll or 0) - 1; return end
    if key == "down"     then state.deckOverviewScroll = (state.deckOverviewScroll or 0) + 1; return end
    if key == "pageup"   then state.deckOverviewScroll = (state.deckOverviewScroll or 0) - 5; return end
    if key == "pagedown" then state.deckOverviewScroll = (state.deckOverviewScroll or 0) + 5; return end
end

-- 结算 / 阶段 / 通关：任意键推进；返回是否消费
function handleFlowStateKey(key)
    if state.state == "result" then GameState.resetRound(state); return true end
    if state.state == "stageClear" then GameState.resetRound(state); return true end
    if state.state == "victory" then state.state = "title"; return true end
    return false
end

-- 下注快捷键：数字键金额 + 回车确认滑条金额
function handleBetKey(key)
    local amounts = { ["1"] = 50, ["2"] = 100, ["3"] = 200, ["4"] = 500, ["5"] = 1000 }
    local amount = amounts[key]
    if amount and state.player.chips >= amount then
        GameState.placeBet(state, amount)
    end
    if key == "return" and sliderBetAmount >= 1 and state.player.chips >= sliderBetAmount then
        GameState.placeBet(state, sliderBetAmount)
    end
    if key == "b" then
        state._bustBetOn = not state._bustBetOn   -- 阶段3 爆注开关（粘滞）
    end
end

-- 玩家行动键：要牌 / 停牌 / 加倍 / 指认 / 投降 / rider 跳过
function handlePlayerActionKey(key)
    if key == "h" or key == "space" then
        GameState.hitPlayer(state)
    elseif key == "s" or key == "enter" then
        GameState.standPlayer(state)
    elseif key == "b" then
        GameState.doubleDown(state)     -- 阶段3 加倍：首两张注码翻倍，只再要一张
    elseif key == "c" then
        GameState.accuseDealer(state)
    elseif key == "u" then
        GameState.surrenderPlayer(state)   -- 遗物"后期投降"：小于 18 点时可投降，退回一半下注
    elseif key == "r" then
        GameState.skipRound(state)   -- Rider 职阶 3 次跳过 / 骑之残卷点亮后本局跳过一次（内部守卫）
    end
end

function handleBetButtons(x, y)
    if not UI or not UI.buttons or not UI.buttons.bet then return end
    for _, btn in ipairs(UI.buttons.bet) do
        if hitRect(btn, x, y) then
            local amounts = { bet50 = 50, bet100 = 100, bet200 = 200 }
            local amount = amounts[btn.id]
            if amount and GameState.placeBet(state, amount) then return end
        end
    end
end

function handleGameButtons(x, y)
    if not UI or not UI.buttons or not UI.buttons.game then return end
    for _, btn in ipairs(UI.buttons.game) do
        if hitRect(btn, x, y) then
            if btn.id == "hit" then GameState.hitPlayer(state)
            elseif btn.id == "stand" then GameState.standPlayer(state)
            elseif btn.id == "double" then GameState.doubleDown(state) end
        end
    end
    -- 反出千按钮（坐标与 ui.lua 绘制同源：UI.buttons.accuse）
    -- 酒吧模式没有庄家出千与指认，跳过（与 ui.lua 不绘制该按钮一致）
    if state.gameMode ~= "bar" then
        local acc = UI.buttons and UI.buttons.accuse
        if acc and hitRect(acc, x, y) then
            GameState.accuseDealer(state)
        end
        -- 投降按钮（遗物"后期投降"，坐标与 ui.lua 绘制同源：UI.buttons.surrender）
        local sur = UI.buttons and UI.buttons.surrender
        if sur and hitRect(sur, x, y) then
            GameState.surrenderPlayer(state)
        end
    end
end

-- 主动技能选牌模态点击（热区由 ui.lua 的 drawBarAlcPick 写入，绘制与点击同源）
function handleBarAlcPickClick(x, y)
    local pick = state._barAlcPick

    -- 取消：不消耗本小局的使用次数，回到玩家回合
    if hitRect(UI._barAlcPickCancel, x, y) then
        GameState.barAbilityPickCancel(state); return
    end
    -- 确认：仅「透牌」的勾选式需要（arg 传勾选表）
    if hitRect(UI._barAlcPickConfirm, x, y) and pick then
        GameState.barAbilityPickSelect(state, pick.marked or {}); return
    end
    if UI._barAlcPickBtns then
        for _, b in ipairs(UI._barAlcPickBtns) do
            if hitRect(b, x, y) then
                if b.toggle then
                    if pick then
                        if not pick.marked then pick.marked = {} end
                        pick.marked[b.arg] = (not pick.marked[b.arg]) or nil
                    end
                else
                    GameState.barAbilityPickSelect(state, b.arg)
                end
                return
            end
        end
    end
    return   -- 模态独占：未命中也不许点穿
end

-- Caster 遗物替换面板点击（热区由 ui.lua 的 drawClassOffer 写入）
function handleClassOfferClick(x, y)
    -- 候选遗物
    if UI._classOfferCards then
        for _, c in ipairs(UI._classOfferCards) do
            if hitRect(c, x, y) then
                GameState.takeClassOffer(state, c.index); return
            end
        end
    end
    -- 自己的遗物（选中"被替换"）
    if UI._classOfferRelics then
        for _, c in ipairs(UI._classOfferRelics) do
            if hitRect(c, x, y) then
                GameState.selectClassOfferTarget(state, c.index); return
            end
        end
    end
    -- 不换按钮
    if UI._classOfferButtons then
        for _, b in ipairs(UI._classOfferButtons) do
            if hitRect(b, x, y) then
                if b.action == "keep" then GameState.closeClassOffer(state); return end
            end
        end
    end
end

-- 冠军牌组编辑器点击（热区全部由 ui.lua 的 drawDeckEditor 写入，绘制与点击同源）
function handleDeckEditorClick(x, y)
    -- 下拉菜单展开时它优先（它是覆盖在牌池区上的菜单，点别处先收起，避免误加牌）
    if state.deckEditorDropOpen then
        if UI._deckEditorDropItems then
            for _, it in ipairs(UI._deckEditorDropItems) do
                if hitRect(it, x, y) then
                    state.deckEditorType     = it.key
                    state.deckEditorScroll   = 0
                    state.deckEditorDropOpen = false
                    return
                end
            end
        end
        state.deckEditorDropOpen = false   -- 表头再点一次 / 点其他位置都收起
        return
    end

    -- 下拉菜单表头
    if hitRect(UI._deckEditorDrop, x, y) then
        state.deckEditorDropOpen = true; return
    end

    -- 顶部按钮（保存 / 返回）
    if UI._deckEditorButtons then
        for _, b in ipairs(UI._deckEditorButtons) do
            if hitRect(b, x, y) then
                if b.action == "save" then GameState.saveDeckEditor(state)
                elseif b.action == "close" then GameState.closeDeckEditor(state) end
                return
            end
        end
    end

    -- 牌池：点击一张 → 加入冠军牌组
    if UI._deckEditorPoolCards then
        for _, it in ipairs(UI._deckEditorPoolCards) do
            if hitRect(it, x, y) then
                if Champion.addCard(state._deckEditorCards, it.card) then
                    state._flashMsg = {
                        text = "已加入（" .. Champion.count(state._deckEditorCards) .. " / " .. Champion.SIZE .. "）",
                        expires = love.timer.getTime() + 1,
                    }
                else
                    state._flashMsg = {
                        text = "最多 " .. Champion.SIZE .. " 张，请先移除一些牌",
                        expires = love.timer.getTime() + 1.5,
                    }
                end
                return
            end
        end
    end

    -- 牌组栏：点击一张已选的牌 → 移除
    if UI._deckEditorSlots then
        for _, s in ipairs(UI._deckEditorSlots) do
            if hitRect(s, x, y) then
                Champion.removeCard(state._deckEditorCards, s.index)
                return
            end
        end
    end
end

function handleStarterRelicClick(x, y)
    if not state.pendingRelics then return end
    local card_w, card_h, spacing = 160, 200, 50
    local total_w = card_w * 3 + spacing * 2
    local start_x = (love.graphics.getWidth() - total_w) / 2
    local card_y = love.graphics.getHeight() / 2 - card_h / 2 + 50
    for i = 1, 3 do
        local rx = start_x + (i - 1) * (card_w + spacing)
        if hitRect({ x = rx, y = card_y, w = card_w, h = card_h }, x, y) then
            GameState.selectStarterRelic(state, i); return
        end
    end
    GameState.selectStarterRelic(state, nil)
end

function handleShopClick(x, y)
    -- 铸造选择面板（模态）：优先处理；点取消/面板外即关闭（不扣款）
    if state.forgeSelectOpen then
        if UI._forgeBtns then
            for _, b in ipairs(UI._forgeBtns) do
                if hitRect(b, x, y) then
                    if b.cancel then
                        state.forgeSelectOpen = nil
                    else
                        GameState.forgeRelic(state, b.target)
                    end
                    return
                end
            end
        end
        state.forgeSelectOpen = nil
        return
    end

    -- 混排卡片点击检测（遗物 + 牌组）
    if UI._shopCards then
        for _, card in ipairs(UI._shopCards) do
            if hitRect(card, x, y) then
                if card.kind == "relic" then
                    for i, r in ipairs(state.shopOfferings or {}) do
                        if r == card.relic then GameState.buyRelic(state, i); return end
                    end
                elseif card.kind == "deck" then
                    for i, o in ipairs(state.shopDeckOfferings or {}) do
                        if o == card.offer then GameState.buyDeck(state, i); return end
                    end
                end
            end
        end
    end

    -- 重刷 / 铸造 / 离开按钮（单一数据源：drawShop 写入 UI._shopButtons）
    if UI._shopButtons then
        for _, b in ipairs(UI._shopButtons) do
            if hitRect(b, x, y) then
                if b.action == "reroll" then GameState.rerollShop(state); return
                elseif b.action == "forge" then GameState.tryOpenForge(state); return
                elseif b.action == "leave" then GameState.leaveShop(state); return
                end
            end
        end
    end
end

function handleShopKey(key)
    -- 铸造选择面板打开时：ESC 只关面板，不离开商店
    if state.forgeSelectOpen then
        if key == "escape" then state.forgeSelectOpen = nil end
        return
    end
    if key == "r" then GameState.rerollShop(state)
    elseif key == "enter" or key == "escape" then GameState.leaveShop(state)
    elseif key >= "1" and key <= "5" then GameState.buyRelic(state, tonumber(key))
    end
end
