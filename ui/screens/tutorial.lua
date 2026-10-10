-- ui/screens/tutorial.lua : 14 步教程浮层（不锁定玩法，只消费自己处理的按键）
local Theme = require("ui.theme")
local lg = love.graphics
local Draw = require("ui.draw")
local Fonts = require("ui.fonts")
local W = require("ui.widgets")
local UI = require("ui.ui")

local T = {}

local function phaseOf(st)
  local tu = st.tutorial
  if not tu then return nil end
  return tu.phase or {}
end

function T.draw(g, st)
  local tu = st.tutorial
  if not tu or not tu.active or tu.done then return end
  local ph = phaseOf(st)
  local x, y = Theme.vx(14), Theme.vy(76)
  local w = Theme.v(392)

  local font = Fonts.get(Theme.px(13))
  local lines = Fonts.wrap(ph.text or "", font, w - Theme.v(34))
  local lh = Fonts.height(font, Theme.v(4))
  local bodyH = math.max(Theme.v(46), #lines * lh)
  local missing = ph.requireAction and true or false
  local h = Theme.v(52) + bodyH + Theme.v(missing and 64 or 46)

  Draw.set({ 0, 0, 0, 0.5 })
  lg.rectangle("fill", x + Theme.v(3), y + Theme.v(4), w, h, Theme.v(8), Theme.v(8))
  Draw.panel(x, y, w, h, Theme.v(8), {
    bgTop = { 0.15, 0.07, 0.075, 0.97 }, bgBot = { 0.05, 0.028, 0.034, 0.97 },
    edge = Theme.colors.gold, edgeA = 0.85, lw = Theme.v(1.4), shadowA = 0.6,
  })
  Draw.gradientV(x, y, w, Theme.v(38), { 0.28, 0.14, 0.10, 1 }, { 0.12, 0.06, 0.05, 1 })
  Draw.text("教 程", x + Theme.v(14), y + Theme.v(10), Theme.px(15), Theme.colors.goldBright, "left")
  local step, total = tu.step or (ph.index or 1), tu.total or 14
  Draw.text(string.format("%d / %d", step, total), x + w - Theme.v(14), y + Theme.v(11), Theme.px(13),
    Theme.colors.textDim, "right")

  -- progress dots
  local dy = y + Theme.v(30)
  local dotR = Theme.v(2.6)
  local spanW = w - Theme.v(28)
  for i = 1, total do
    local px = x + Theme.v(14) + (i - 1) * (spanW / math.max(1, total - 1))
    local col = (i < step) and Theme.colors.goldDim or (i == step and Theme.colors.goldBright or { 0.32, 0.26, 0.24 })
    Draw.set(col[1], col[2], col[3], i <= step and 1 or 0.7)
    lg.circle("fill", px, dy, dotR)
  end

  local ty = y + Theme.v(42)
  Draw.text(ph.title or "教程", x + Theme.v(14), ty, Theme.px(15), Theme.colors.goldPale, "left", w - Theme.v(28))
  ty = ty + Theme.v(22)
  Draw.set(Theme.colors.text[1], Theme.colors.text[2], Theme.colors.text[3], 1)
  for i, ln in ipairs(lines) do
    Draw.text(ln, x + Theme.v(14), ty + (i - 1) * lh, Theme.px(13), Theme.colors.text, "left", w - Theme.v(28))
  end
  ty = ty + bodyH

  if missing then
    local hint = ph.actionHint or "请先完成当前操作"
    Draw.text("需要操作：" .. hint, x + Theme.v(14), ty + Theme.v(4), Theme.px(12.5), Theme.colors.orange, "left", w - Theme.v(28))
    ty = ty + Theme.v(22)
  end

  W.button({
    id = "tut.next", x = x + Theme.v(14), y = ty + Theme.v(4), w = w - Theme.v(28), h = Theme.v(36),
    label = missing and "请先完成操作" or "继续", sub = missing and nil or "Enter / 空格",
    tone = missing and "dark" or "gold", size = 15,
    enabled = not missing,
    tip = missing and ("教程要求你先完成：" .. (ph.actionHint or "对应操作")) or "进入教程下一步",
    tipTitle = "教程",
    data = { tutorial = true, blocked = missing },
  })
end

function T.advance(g, st)
  local ph = phaseOf(st)
  if ph.requireAction then
    UI.tutorialHint = { text = "请先完成：" .. (ph.actionHint or "对应操作"), t = 0 }
    UI.notify("教程要求先完成：" .. (ph.actionHint or "对应操作"), "warn")
    return true
  end
  if g.action then g:action("tutorial_advance") end
  return true
end

function T.onClick(g, st, hs)
  if hs.id == "tut.next" then
    if hs.data and hs.data.blocked then
      return T.advance(g, st)
    end
    return T.advance(g, st)
  end
  return false
end

function T.onKey(g, st, key)
  if key == "return" or key == "kpenter" or key == "space" then
    return T.advance(g, st)
  end
  return false
end

return T
