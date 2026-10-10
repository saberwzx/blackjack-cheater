-- ui/ui.lua : screen manager, input priority chain, fx bridge, overlay stack.
local Theme = require("ui.theme")
local Draw = require("ui.draw")
local Hot = require("ui.hot")
local W = require("ui.widgets")
local Ease = require("ui.ease")
local Particles = require("ui.particles")
local Audio = require("ui.audio")
local lg = love.graphics

local UI = {}

UI.g = nil
UI.settingsOpen = false
UI.settingsPage = 1
UI.dialog = nil
UI.tutorialHint = nil
UI.toasts = {}
UI.vfx = {
  tells = {},        -- uid/slot key -> {kind, real, t}
  anims = {},        -- "target:index" -> {t, dur}
  slash = nil,       -- {t, dur, target}
  rod = nil,
  markFx = nil,
  accuse = nil,
  counter = {},
}
UI.screens = {}

local ParticlesNS = Particles
UI.particles = ParticlesNS.new(700)
UI.shake = ParticlesNS.Shake
UI.popups = ParticlesNS.Popups

-- ===== screen registry =====
local function screen(name)
  local m = UI.screens[name]
  if not m then
    m = require("ui.screens." .. name)
    UI.screens[name] = m
  end
  return m
end
UI.screen = screen

local FULL = {
  title = "title", modeSelect = "modeSelect", relic_select = "relicSelect",
  classSelect = "classSelect", shop = "shop", victory = "victory",
  stageClear = "stageClear", forceExit = "forceExit", deckEditor = "deckEditor",
  bar_brief = "bar", bar_gift = "bar", bar_drink = "bar", bar_ending = "bar",
  bar_alcpick = "bar",
}
local OVERLAY = {
  shoeInfo = "shoeInfo", deckOverview = "deckOverview", classOffer = "classOffer",
  -- 酒吧技能的两步 / 清单 / 冠军选牌面板：覆盖在牌桌之上，独占输入
  bar_pick = "bar",
}
local TABLE_STATES = {
  bet = true, player = true, dealer = true, result = true,
  shoeInfo = true, deckOverview = true, classOffer = true,
}

function UI.baseNameFor(st)
  local s = st.state
  -- title -> modeSelect is pure UI navigation (the core keeps state='title'
  -- until select_mode is accepted); closing it falls back to the title screen.
  if s == "title" and UI.localScreen == "modeSelect" then return "modeSelect" end
  if FULL[s] then return FULL[s] end
  if s == "title" then return "title" end
  if s == "modeSelect" and UI.localScreen == nil then UI.localScreen = "modeSelect" end
  return "table"
end

function UI.overlayNameFor(st)
  -- 覆盖层由核心的状态标志驱动（state 本身保持 bet/player/dealer/result）
  if st.shoeOpen then return "shoeInfo" end
  if st.deckOpen then return "deckOverview" end
  return OVERLAY[st.state]
end

function UI.init(g)
  UI.g = g
  Theme.setSize(love.graphics.getWidth(), love.graphics.getHeight())
  Audio.init({ volume = (g.state.settings and g.state.settings.volume) or 0.6 })
  UI.applyBGMForState()
end

function UI.applyBGMForState()
  local st = UI.g and UI.g.state
  if not st then return end
  if st.mode == "bar" or (st.state and st.state:sub(1, 4) == "bar_") then Audio.setBGM("bar")
  else
    local s = st.stage or 1
    Audio.setBGM(s >= 3 and "phase3" or (s == 2 and "phase2" or "phase1"))
  end
end

-- ===== notifications =====
function UI.notify(text, tone)
  if not text or text == "" then return end
  UI.toasts[#UI.toasts + 1] = { text = text, tone = tone or "info", t = 0, dur = 3.2 }
  if #UI.toasts > 4 then table.remove(UI.toasts, 1) end
end

function UI.confirm(opts)
  UI.dialog = {
    title = opts.title or "确认",
    text = opts.text or "",
    yes = opts.yesLabel or "确定",
    no = opts.noLabel or "取消",
    onYes = opts.onYes,
    onNo = opts.onNo,
    single = opts.single or false,
    danger = opts.danger or false,
  }
end

function UI.closeDialog()
  local d = UI.dialog
  UI.dialog = nil
  if d and d.onNo and not d._yes then d.onNo() end
end

-- ===== fx bridge =====
local function fxShake(amount)
  UI.shake.add(math.min(8, amount or 3), 0.4)
end

function UI.consumeFx()
  local g = UI.g
  if not g or not g.drainFx then return end
  local list = g:drainFx()
  if not list then return end
  local fxv = UI.vfx
  for _, fx in ipairs(list) do
    local kind = fx.kind
    if kind == "deal" or kind == "card_hit" then
      local key = tostring(fx.target) .. ":" .. tostring(fx.index or (#((g.state[fx.target] or {}).hand or {})))
      fxv.anims[key] = { t = 0, dur = 0.34, card = fx.card }
      Audio.play("deal")
    elseif kind == "card_discard" then
      Audio.play("card_slide")
    elseif kind == "score_popup" then
      UI.popups.add(fx.text or "", Theme.W * 0.5, Theme.H * 0.42,
        fx.value and fx.value < 0 and Theme.colors.negative or Theme.colors.goldBright, true)
    elseif kind == "counter" then
      UI.popups.add(tostring(fx.value or 0), Theme.W * 0.5 + Theme.px(120), Theme.H * 0.34, Theme.colors.goldBright, false)
    elseif kind == "shake" then
      fxShake(fx.amount)
    elseif kind == "sfx" then
      Audio.play(fx.name)
      if fx.name == "blackjack" then fxShake(7) end
    elseif kind == "bgm" then
      Audio.setBGM(fx.name)
    elseif kind == "message" then
      UI.notify(fx.text, fx.tone)
    elseif kind == "tell" then
      -- 契约：{kind="tell", tellKind="A".."E"/"dA".."dE", uid, slot, card, oldRank?, link?}
      -- real=false 由 d 前缀决定；link=true 表示这是"连线到玩家明牌"的那一半（E/dE 专用）。
      local key = fx.uid and ("uid:" .. tostring(fx.uid)) or ("slot:" .. tostring(fx.slot or "?"))
      local rec = {
        kind = fx.tellKind, real = not fx.tellKind:match("^d"), t = 0,
        slot = fx.slot, oldRank = fx.oldRank, link = fx.link, card = fx.card,
      }
      fxv.tells[key] = rec
      if fx.uid then fxv.tells["uid:" .. tostring(fx.uid)] = rec end
    elseif kind == "mark_fx" then
      fxv.markFx = { id = fx.markId, anchor = fx.anchor, card = fx.card, t = 0, dur = 0.9 }
    elseif kind == "class_fx" then
      if fx.fx == "saber_slash" then
        fxv.slash = { t = 0, dur = fx.duration or 0.9, side = fx.side, target = fx.target, card = fx.card }
        Audio.play("slash")
      end
    elseif kind == "saber_slash" then
      fxv.slash = { t = 0, dur = fx.duration or 0.9, side = fx.side, target = fx.target, card = fx.card }
      Audio.play("slash")
    elseif kind == "rod_fx" then
      fxv.rod = { t = 0, dur = 0.8, rodId = fx.rodId, count = fx.count }
      Audio.play("rod")
    elseif kind == "state" then
      if fx.to == "bet" then fxv.tells = {}; fxv.anims = {} end
      UI.applyBGMForState()
    end
  end
end

function UI.consumeLog()
  local g = UI.g
  if not g or not g.drainLog then return end
  local list = g:drainLog()
  if not list then return end
  for _, line in ipairs(list) do
    if type(line) == "string" and #line > 0 then UI.lastLog = line end
  end
end

-- ===== update =====
function UI.update(dt)
  Theme.dt = dt
  Theme.time = Theme.time + dt
  Ease.Tweens.update(dt)
  UI.particles:update(dt)
  UI.popups.update(dt)
  UI.shake.update(dt)
  UI.consumeFx()
  UI.consumeLog()

  local fxv = UI.vfx
  for _, v in pairs(fxv.anims) do v.t = v.t + dt end
  for _, v in pairs(fxv.tells) do v.t = v.t + dt end
  if fxv.slash then fxv.slash.t = fxv.slash.t + dt; if fxv.slash.t > fxv.slash.dur then fxv.slash = nil end end
  if fxv.rod then fxv.rod.t = fxv.rod.t + dt; if fxv.rod.t > fxv.rod.dur then fxv.rod = nil end end
  if fxv.markFx then fxv.markFx.t = fxv.markFx.t + dt; if fxv.markFx.t > fxv.markFx.dur then fxv.markFx = nil end end

  local i = 1
  while i <= #UI.toasts do
    local t = UI.toasts[i]
    t.t = t.t + dt
    if t.t >= t.dur then table.remove(UI.toasts, i) else i = i + 1 end
  end

  if UI.tutorialHint then
    UI.tutorialHint.t = UI.tutorialHint.t + dt
    if UI.tutorialHint.t > 2.0 then UI.tutorialHint = nil end
  end

  local base = screen(UI.baseNameFor(g_state()))
  if base.update then base.update(dt) end
  local ovName = UI.overlayNameFor(g_state())
  if ovName then
    local ov = screen(ovName)
    if ov.update then ov.update(dt) end
  end
end

function g_state()
  return UI.g and UI.g.state or { state = "title" }
end
UI.state = g_state

-- ===== draw =====
local function drawToasts()
  local y = Theme.px(60)
  for i, t in ipairs(UI.toasts) do
    local a = math.min(1, t.t / 0.18) * math.min(1, (t.dur - t.t) / 0.4)
    local tone = t.tone
    local col = tone == "error" and Theme.colors.negative or (tone == "success" and Theme.colors.positive or Theme.colors.goldBright)
    local size = Theme.px(15)
    local w = require("ui.fonts").get(size):getWidth(t.text) + Theme.px(34)
    local x = Theme.W * 0.5 - w * 0.5
    local h = Theme.px(30)
    Draw.set({ 0, 0, 0, 0.55 * a }); lg.rectangle("fill", x + 2, y + 3, w, h, Theme.px(4), Theme.px(4))
    Draw.gradientV(x, y, w, h, { 0.12, 0.08, 0.09, 0.95 * a }, { 0.05, 0.03, 0.04, 0.95 * a })
    Draw.set(col[1], col[2], col[3], 0.9 * a); lg.setLineWidth(1.2)
    lg.rectangle("line", x, y, w, h, Theme.px(4), Theme.px(4))
    Draw.set(col[1], col[2], col[3], a)
    lg.rectangle("fill", x, y, Theme.px(4), h, Theme.px(2), Theme.px(2))
    Draw.text(t.text, x + Theme.px(12), y + Theme.px(7), size, { col[1], col[2], col[3], a }, "left", w - Theme.px(20))
    y = y + h + Theme.px(6)
  end
end

-- Every hotspot / scroll region registered so far becomes inert, so the layer
-- drawn next owns input exclusively (mouse scope matches key scope).
local function blockRegistered()
  for i = 1, #Hot.btns do
    local id = Hot.btns[i].id
    if id then Hot.block(tostring(id)) end
  end
  for id in pairs(Hot.scrolls) do Hot.scrollBlock(id) end
end

function UI.draw()
  local g = UI.g
  local st = g_state()
  Hot.begin()

  lg.push()
  UI.shake.apply()

  local base = screen(UI.baseNameFor(st))
  if base.draw then base.draw(g, st) end

  -- tutorial overlay (does not lock play); drawn before modality blocking so a
  -- modal opened on top of it makes it inert.
  if st.tutorial and st.tutorial.active and not st.tutorial.done then
    screen("tutorial").draw(g, st)
  end

  local ovName = UI.overlayNameFor(st)
  if ovName then
    blockRegistered()
    local ov = screen(ovName)
    if ov.draw then ov.draw(g, st) end
  end

  if UI.settingsOpen then
    blockRegistered()
    screen("settings").draw(g, st)
  end

  if UI.dialog then
    blockRegistered()
    screen("dialog").draw(g, st, UI.dialog)
  end

  lg.pop()

  -- unshaken layers
  UI.particles:draw()
  UI.popups.draw()
  drawToasts()
  if UI.tutorialHint then
    Draw.text(UI.tutorialHint.text, Theme.W * 0.5, Theme.H - Theme.px(90), Theme.px(14),
      { Theme.colors.orange[1], Theme.colors.orange[2], Theme.colors.orange[3], math.min(1, 2 - UI.tutorialHint.t) }, "center")
  end

  Hot.finish()
  W.drawTooltip()
end

-- ===== input =====
local function overlayMod(st)
  local n = UI.overlayNameFor(st)
  return n and screen(n) or nil
end

local function tutorialMod()
  return screen("tutorial")
end

function UI.modalOpen()
  local st = g_state()
  return (UI.dialog ~= nil) or UI.settingsOpen or (UI.overlayNameFor(st) ~= nil)
end

-- The mouse chain mirrors the key chain exactly:
-- dialog -> settings -> overlay -> tutorial -> base state handler.
function UI.onClickHandler(hs)
  local g = UI.g
  local st = g_state()
  if UI.dialog then
    if screen("dialog").onClick(g, st, hs, UI.dialog) then return true end
    return true
  end
  if UI.settingsOpen then
    if screen("settings").onClick(g, st, hs) then return true end
    return true
  end
  local ov = overlayMod(st)
  if ov then
    if ov.onClick then ov.onClick(g, st, hs) end
    return true
  end
  if st.tutorial and st.tutorial.active and not st.tutorial.done then
    if tutorialMod().onClick and tutorialMod().onClick(g, st, hs) then return true end
  end
  local base = screen(UI.baseNameFor(st))
  if base.onClick and base.onClick(g, st, hs) then return true end
  -- 顶栏右上角全局入口（所有绘制 topBar 的界面共用同一热区表）
  local id = tostring(hs.id or "")
  if id == "top.settings" then UI.settingsOpen = true; return true end
  if id == "top.shoe" then
    if st.mode == "bar" then UI.notify("酒吧模式不提供情报面板。", "warn"); return true end
    g:action(st.shoeOpen and "close_shoe" or "open_shoe"); return true
  end
  if id == "top.deck" then
    if st.mode == "bar" then UI.notify("酒吧模式不提供牌堆总览。", "warn"); return true end
    g:action(st.deckOpen and "close_deck" or "open_deck"); return true
  end
  return false
end

function UI.mousepressed(x, y, button)
  if button ~= 1 then return end
  local hs = Hot.hit(x, y)
  if hs then
    Audio.play("click")
    if Hot.press(hs, x, y) then return end
    UI.onClickHandler(hs)
    return
  end
  -- no live hotspot: the topmost modal owns the click
  local st = g_state()
  if UI.dialog then UI.closeDialog(); return end
  if UI.settingsOpen then return end
  if UI.overlayNameFor(st) then
    local ov = overlayMod(st)
    if ov and ov.onBackdrop then ov.onBackdrop(UI.g, st, x, y) end
    return
  end
  local base = screen(UI.baseNameFor(st))
  if base.onBackdrop then base.onBackdrop(UI.g, st, x, y) end
end

function UI.mousemoved(x, y)
  Hot.mx, Hot.my = x, y
  Hot.dragMove(x, y)
end

function UI.mousereleased(x, y, button)
  if button ~= 1 then return end
  Hot.dragEnd()
end

function UI.wheelmoved(dx, dy)
  local st = g_state()
  if UI.dialog then return end
  if UI.settingsOpen then
    local s = screen("settings")
    if s.onWheel then s.onWheel(dy) end
    return
  end
  -- scroll regions from covered layers were blocked at draw time, so this only
  -- ever returns a region belonging to the live layer.
  local r = Hot.scrollAt(Hot.mx, Hot.my)
  if r then
    local step = r.step or 1
    r.set(math.max(0, math.min(r.max, (r.get() or 0) - dy * step)))
    return
  end
  local ov = overlayMod(st)
  if ov then
    if ov.onWheel then ov.onWheel(UI.g, st, dy) end
    return
  end
  local base = screen(UI.baseNameFor(st))
  if base.onWheel then base.onWheel(UI.g, st, dy) end
end

function UI.escape()
  local g = UI.g
  local st = g_state()
  -- 牌桌上的酒吧简报覆盖层优先关闭
  local barmod = UI.screens.bar
  if barmod and barmod.briefOpen and st and st.mode == "bar" then barmod.toggleBrief(); return end
  if UI.dialog then UI.closeDialog(); return end
  if UI.settingsOpen then UI.settingsOpen = false; return end
  if UI.overlayNameFor(st) then
    if st.state == "bar_pick" then g:action("bar_pick", { cancel = true }); return end
    g:action("close_top")
    return
  end
  -- title -> modeSelect is UI-side navigation; ESC must pop back to the title.
  if UI.localScreen == "modeSelect" then UI.localScreen = nil; return end
  if st.state == "deckEditor" then g:action("close_deck_editor"); return end
  if st.state == "shop" then g:action("leave_shop"); return end
  if tostring(st.state):sub(1, 4) == "bar_" then g:action("close_top"); return end
  if st.state == "classSelect" then return end
  if st.state == "title" or st.state == "modeSelect" then return end
  if st.state == "victory" or st.state == "stageClear" or st.state == "forceExit" then return end
  UI.settingsOpen = true
end

-- Strict priority, nothing passes through a modal:
-- forceExit 演出 -> 说明弹窗 -> 设置页(独占) -> 覆盖层(独占, 允许关闭键) -> 教程门控 -> 基础状态处理器
function UI.keypressed(key)
  local g = UI.g
  local st = g_state()

  -- 0. forceExit 演出: any key advances.
  if st.state == "forceExit" then g:action("continue"); return end

  -- 1. 说明弹窗 (exclusive)
  if UI.dialog then
    if key == "return" or key == "kpenter" or key == "space" then
      local d = UI.dialog
      UI.dialog = nil
      if d.single then
        if d.onNo then d.onNo() end
      else
        d._yes = true
        if d.onYes then d.onYes() end
      end
    elseif key == "escape" then
      UI.closeDialog()
    end
    return
  end

  -- 2. 设置页 (exclusive)
  if UI.settingsOpen then
    if key == "escape" then UI.settingsOpen = false; return end
    local s = screen("settings")
    if s.onKey then s.onKey(g, st, key) end
    return
  end

  -- 3. 覆盖层: 情报 / 牌堆总览 / 职阶替换 (exclusive; close keys allowed)
  local ov = overlayMod(st)
  if ov then
    if key == "escape" then UI.escape(); return end
    if ov.onKey and ov.onKey(g, st, key) then return end
    return
  end

  -- 4. escape on the table / editors / bar modals
  if key == "escape" then UI.escape(); return end

  -- 5. 教程门控 (does not lock play: the tutorial only consumes keys it handles)
  if st.tutorial and st.tutorial.active and not st.tutorial.done then
    if tutorialMod().onKey and tutorialMod().onKey(g, st, key) then return end
  end

  -- 6. 基础状态处理器
  local base = screen(UI.baseNameFor(st))
  if base.onKey and base.onKey(g, st, key) then return end

  -- 7. 全局面板开关 I / D (never inside the editor or bar)
  local inEditor = (st.state == "deckEditor")
  local inBar = st.mode == "bar" or tostring(st.state):sub(1, 4) == "bar_"
  if not inEditor and not inBar then
    if key == "i" then
      if st.state == "shoeInfo" then g:action("close_shoe") else g:action("open_shoe") end
      return
    elseif key == "d" then
      if st.state == "deckOverview" then g:action("close_deck") else g:action("open_deck") end
      return
    end
  end

  -- 8. 左上角入口
  if key == "f1" then UI.settingsOpen = true; return end
end

function UI.textinput(t) end

return UI
