-- ui/screens/dialog.lua : 通用确认弹窗（UI.dialog），独占输入
local Theme = require("ui.theme")
local lg = love.graphics
local Draw = require("ui.draw")
local Fonts = require("ui.fonts")
local W = require("ui.widgets")
local C = require("ui.screens.common")
local UI = require("ui.ui")

local D = {}

function D.draw(g, st, d)
  if not d then return end
  Draw.set({ 0, 0, 0, 0.66 })
  lg.rectangle("fill", 0, 0, Theme.W, Theme.H)
  local w, h = Theme.v(560), Theme.v(260)
  local x = Theme.vx(640) - w * 0.5
  local y = Theme.vy(360) - h * 0.5
  local accent = d.danger and Theme.colors.negative or Theme.colors.gold
  Draw.glow(x + w * 0.5, y + h * 0.5, w * 0.6, { accent[1], accent[2], accent[3], 0.16 }, 1, h * 0.6)
  Draw.panel(x, y, w, h, Theme.v(9), {
    bgTop = { 0.14, 0.065, 0.075, 1 }, bgBot = { 0.035, 0.020, 0.026, 1 },
    edge = accent, edgeA = 0.9, lw = Theme.v(1.6), shadowA = 0.75,
  })
  Draw.ornateFrame(x, y, w, h, Theme.v(9), accent, 0.8)
  Draw.gradientV(x, y, w, Theme.v(44), { 0.26, 0.11, 0.10, 1 }, { 0.10, 0.05, 0.05, 1 })
  Draw.textOutline(d.title or "确认", x + w * 0.5, y + Theme.v(12), Theme.px(19), Theme.colors.goldBright,
    { 0.10, 0.04, 0.02, 0.95 }, "center", w - Theme.v(60), Theme.v(1.4))
  Draw.hline(x + Theme.v(14), y + Theme.v(44), w - Theme.v(28), accent, 0.7, Theme.v(1.2))

  if d.text and d.text ~= "" then
    local font = Fonts.get(Theme.px(15))
    local lines = Fonts.wrap(d.text, font, w - Theme.v(70))
    local lh = Fonts.height(font, Theme.v(5))
    local ty = y + Theme.v(78)
    for i, ln in ipairs(lines) do
      Draw.text(ln, x + w * 0.5, ty + (i - 1) * lh, Theme.px(15), Theme.colors.text, "center", w - Theme.v(70))
    end
  end

  local bh = Theme.v(42)
  local by = y + h - bh - Theme.v(26)
  if d.single then
    W.button({ id = "dialog.yes", x = x + w * 0.5 - Theme.v(90), y = by, w = Theme.v(180), h = bh,
      label = d.yes or "确定", tone = d.danger and "red" or "gold", size = 16, hotkey = "Enter" })
  else
    W.button({ id = "dialog.yes", x = x + w * 0.5 - Theme.v(196), y = by, w = Theme.v(184), h = bh,
      label = d.yes or "确定", tone = d.danger and "red" or "gold", size = 16, hotkey = "Enter" })
    W.button({ id = "dialog.no", x = x + w * 0.5 + Theme.v(12), y = by, w = Theme.v(184), h = bh,
      label = d.no or "取消", tone = "dark", size = 16, hotkey = "Esc" })
  end
end

function D.onClick(g, st, hs, d)
  if not d or not hs then return false end
  if hs.id == "dialog.yes" then
    local yes = d.onYes
    d._yes = true
    UI.dialog = nil
    if yes then yes() end
    return true
  end
  if hs.id == "dialog.no" then
    UI.closeDialog()
    return true
  end
  return false
end

function D.onKey(g, st, key) return false end

return D
