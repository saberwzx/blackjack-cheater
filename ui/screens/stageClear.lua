-- ui/screens/stageClear.lua : 阶段通过（全屏，任意键继续）
local Theme = require("ui.theme")
local Draw = require("ui.draw")
local W = require("ui.widgets")
local C = require("ui.screens.common")
local Motifs = require("ui.motifs")

local S = {}

local STAGE_NAMES = { "新手赌场", "老练赌场", "黑暗赌场" }

function S.draw(g, st)
  C.bg(st)
  Motifs.roulette(Theme.vx(640), Theme.vy(180), Theme.v(96), Theme.time, { spin = 0.22 })
  Draw.title("阶 段 通 过", Theme.vx(640), Theme.vy(276), Theme.px(44), "center")
  local stage = st.stage or 1
  local nextStage = math.min(3, stage + 1)
  Draw.text("你带着 " .. C.money(st.chips or 0) .. " 筹码走出了 " .. (STAGE_NAMES[stage] or ("第 " .. stage .. " 阶段")),
    Theme.vx(640), Theme.vy(348), Theme.px(16), Theme.colors.text, "center")

  local bw, bh = Theme.v(560), Theme.v(112)
  local bx, by = Theme.vx(640) - bw * 0.5, Theme.vy(388)
  Draw.panel(bx, by, bw, bh, Theme.v(8), { bgTop = { 0.13, 0.07, 0.07, 0.95 }, bgBot = { 0.05, 0.03, 0.035, 0.95 } })
  Draw.text("下一站：" .. (STAGE_NAMES[nextStage] or "终局"), bx + Theme.v(20), by + Theme.v(12), Theme.px(15), Theme.colors.goldBright, "left")
  Draw.text("目标 " .. C.money(nextStage == 2 and 20000 or (nextStage == 3 and 2000000 or 2000)),
    bx + bw - Theme.v(20), by + Theme.v(12), Theme.px(15), Theme.colors.goldPale, "right")
  Draw.text(stage == 2 and "阶段 2 → 3 之间将进行职阶选择（7 选 1）。" or "阶段推进：新赌场、新赔率、新风险。",
    bx + Theme.v(20), by + Theme.v(42), Theme.px(12.5), Theme.colors.text, "left", bw - Theme.v(40))
  Draw.text("阶段幸存者类遗物会在阶段完成时结算。", bx + Theme.v(20), by + Theme.v(66), Theme.px(12), Theme.colors.textDim, "left", bw - Theme.v(40))

  W.button({ id = "sc.continue", x = Theme.vx(640) - Theme.v(150), y = Theme.vy(548), w = Theme.v(300), h = Theme.v(54),
    label = "继续（任意键）", tone = "gold", size = 18, hotkey = "Enter", pulse = true,
    tip = "进入下一阶段", tipTitle = "继续" })
end

function S.onClick(g, st, hs)
  g:action("continue")
  return true
end

function S.onKey(g, st, key)
  g:action("continue")
  return true
end

function S.onWheel(g, st, dy) end
function S.onBackdrop(g, st, x, y) g:action("continue") end

return S
