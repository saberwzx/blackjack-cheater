-- ui/screens/victory.lua : 通关（全屏）
local Theme = require("ui.theme")
local Draw = require("ui.draw")
local W = require("ui.widgets")
local C = require("ui.screens.common")
local Particles = require("ui.particles")

local S = { t = 0, burst = false }

function S.draw(g, st)
  C.bg(st)
  S.t = Theme.time
  local p = st.progress or {}
  Draw.title("通 关", Theme.vx(640), Theme.vy(150), Theme.px(58), "center")
  Draw.text("你洗劫了赌城三部曲，成为真正的千王。", Theme.vx(640), Theme.vy(226), Theme.px(17), Theme.colors.goldPale, "center")

  local stats = {
    { "最高阶段", tostring(p.maxStage or st.stage or 3) },
    { "最高筹码", C.money(p.maxChips or st.chips or 0) },
    { "总周目", tostring(p.totalRuns or 1) },
    { "通关困难", p.hardCleared and "已通关" or "未通关" },
  }
  local sw = Theme.v(214)
  local x0 = Theme.vx(640) - (sw * 4 + Theme.v(24) * 3) * 0.5
  for i, sdef in ipairs(stats) do
    C.stat(x0 + (i - 1) * (sw + Theme.v(24)), Theme.vy(300), sw, sdef[1], sdef[2], Theme.colors.goldBright)
  end

  if not S.burst then
    S.burst = true
    local UI = require("ui.ui")
    for i = 1, 3 do
      UI.particles:emit(Theme.vx(300 + i * 180), Theme.vy(200), { count = 40, speed = 150, life = 1.6, size = 4,
        color = { 0.98, 0.80, 0.36, 0.95 }, kind = "coin", grav = 120 })
    end
  end

  Draw.text("冠军牌组编辑器已解锁：通关困难后可在标题界面编辑并上架 36 张牌组。",
    Theme.vx(640), Theme.vy(430), Theme.px(13), Theme.colors.text, "center", Theme.v(760))

  W.button({ id = "vic.continue", x = Theme.vx(640) - Theme.v(150), y = Theme.vy(520), w = Theme.v(300), h = Theme.v(54),
    label = "返回标题（任意键）", tone = "gold", size = 18, hotkey = "Enter", pulse = true,
    tip = "回到标题", tipTitle = "继续" })
end

function S.onClick(g, st, hs) g:action("continue"); return true end
function S.onKey(g, st, key) g:action("continue"); return true end
function S.onWheel(g, st, dy) end
function S.onBackdrop(g, st, x, y) g:action("continue") end

return S
