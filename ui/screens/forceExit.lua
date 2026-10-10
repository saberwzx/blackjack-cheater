-- ui/screens/forceExit.lua : 破产 / 被请出场（全屏）
local Theme = require("ui.theme")
local Draw = require("ui.draw")
local W = require("ui.widgets")
local C = require("ui.screens.common")
local Motifs = require("ui.motifs")

local S = {}

function S.draw(g, st)
  C.bg(st, { noStars = false })
  Motifs.glass(Theme.vx(640), Theme.vy(210), Theme.v(120), "wine", 1.0, { 0.55, 0.10, 0.14, 0.95 }, Theme.time)
  Draw.title("被 请 出 场", Theme.vx(640), Theme.vy(292), Theme.px(42), "center")
  local p = st.progress or {}
  Draw.text(st.mode == "bar" and "酒喝光了，酒吧的账单到此为止。" or "筹码耗尽，赌场保安把你礼送出门。",
    Theme.vx(640), Theme.vy(360), Theme.px(16), Theme.colors.text, "center")

  local bw, bh = Theme.v(560), Theme.v(120)
  local bx, by = Theme.vx(640) - bw * 0.5, Theme.vy(398)
  Draw.panel(bx, by, bw, bh, Theme.v(8), { bgTop = { 0.13, 0.07, 0.07, 0.95 }, bgBot = { 0.05, 0.03, 0.035, 0.95 } })
  local lines = {
    "结算筹码：" .. C.money(st.chips or 0),
    "到达阶段：" .. tostring(st.stage or 1) .. " / 3　·　本局回合：" .. tostring(st.round or 0),
    "历史最高筹码：" .. C.money(p.maxChips or 0),
  }
  for i, ln in ipairs(lines) do
    Draw.text(ln, bx + Theme.v(20), by + Theme.v(14) + (i - 1) * Theme.v(28), Theme.px(14), Theme.colors.text, "left")
  end

  W.button({ id = "fx.continue", x = Theme.vx(640) - Theme.v(150), y = Theme.vy(548), w = Theme.v(300), h = Theme.v(54),
    label = "返回标题（任意键）", tone = "dark", size = 18, hotkey = "Enter", pulse = true,
    tip = "回到标题", tipTitle = "继续" })
end

function S.onClick(g, st, hs) g:action("continue"); return true end
function S.onKey(g, st, key) g:action("continue"); return true end
function S.onWheel(g, st, dy) end
function S.onBackdrop(g, st, x, y) g:action("continue") end

return S
