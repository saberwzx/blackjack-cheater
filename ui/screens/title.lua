local Theme = require("ui.theme")
local Draw = require("ui.draw")
local Hot = require("ui.hot")
local W = require("ui.widgets")
local Motifs = require("ui.motifs")
local Audio = require("ui.audio")
local C = require("ui.screens.common")
local lg = love.graphics

local M = {}

-- ===== 标题：程序化 20 格轮盘 + 金色标题 + 四个入口 =====
local T = { spin = 0 }

function T.update(dt)
  T.spin = (T.spin or 0) + dt
end

function T.draw(g, st)
  C.bg(st)
  local cx, cy = Theme.vx(640), Theme.vy(190)
  local r = Theme.v(116)
  Motifs.roulette(cx, cy, r, T.spin or Theme.time, { spin = 0.16 })
  -- 名牌横匾（压在轮盘上，保留轮盘可见）
  local pw, ph = Theme.v(452), Theme.v(104)
  local px, py = cx - pw * 0.5, cy - ph * 0.5
  Draw.set({ 0, 0, 0, 0.55 }); lg.rectangle("fill", px - Theme.v(3), py - Theme.v(3), pw + Theme.v(6), ph + Theme.v(6), Theme.v(7), Theme.v(7))
  Draw.gradientV(px, py, pw, ph, { 0.10, 0.035, 0.045, 0.94 }, { 0.035, 0.016, 0.022, 0.94 })
  Draw.ornateFrame(px, py, pw, ph, Theme.v(7), Theme.colors.gold, 0.9)
  Draw.textOutline("Blackjack Cheater", cx, py + Theme.v(12), Theme.px(42), Theme.colors.goldBright,
    { 0.14, 0.05, 0.02, 0.95 }, "center", pw - Theme.v(20), Theme.v(2))
  Draw.text("千 王 之 路", cx, py + Theme.v(60), Theme.px(15), Theme.colors.gold, "center", pw - Theme.v(20))
  Draw.text("21 点 · 出千 · 赌城三部曲", cx, py + Theme.v(82), Theme.px(10.5),
    { 0.74, 0.64, 0.42, 0.9 }, "center", pw - Theme.v(20))

  -- 入口
  local bw, bh = Theme.v(296), Theme.v(46)
  local bx = Theme.vx(640) - bw * 0.5
  local by = Theme.vy(346)
  local gap = Theme.v(12)
  local unlocked = st.progress and st.progress.hardCleared

  W.button({ id = "title.start", x = bx, y = by, w = bw, h = bh, label = "开始游戏", tone = "gold",
    size = 19, hotkey = "Enter", pulse = true,
    tip = "选择基础 / 困难 / 酒吧模式，开始新的一周目。", tipTitle = "开始游戏" })
  by = by + bh + gap
  W.button({ id = "title.tutorial", x = bx, y = by, w = bw, h = bh, label = "教程", tone = "blue",
    size = 17, hotkey = "T",
    tip = "14 步新手教程：强制基础模式、无庄家职阶、无遗物，逐步讲解玩法。", tipTitle = "教程" })
  by = by + bh + gap
  W.button({ id = "title.champion", x = bx, y = by, w = bw, h = bh, label = "冠军牌组", tone = unlocked and "purple" or "grey",
    size = 17, hotkey = "C", enabled = unlocked and true or false,
    sub = unlocked and nil or "通关困难模式后解锁",
    tip = unlocked and "编辑并保存 36 张冠军牌组（牌面池 290 张）。" or "尚未解锁：通关一次困难模式即可开启冠军牌组编辑器。",
    tipTitle = "冠军牌组" })
  by = by + bh + gap
  W.button({ id = "title.exit", x = bx, y = by, w = bw, h = bh, label = "退出", tone = "dark",
    size = 17, hotkey = "Esc",
    tip = "关闭游戏。", tipTitle = "退出" })

  -- 元进度
  local pr = st.progress or {}
  local y = Theme.vy(628)
  local sw = Theme.v(210)
  local sx = Theme.vx(640) - (sw * 4 + Theme.v(12) * 3) * 0.5
  C.stat(sx, y, sw, "通关困难", pr.hardCleared and ("已通关 " .. tostring(pr.hardClearCount or 0) .. " 次") or "未通关",
    pr.hardCleared and Theme.colors.positive or Theme.colors.textDim)
  sx = sx + sw + Theme.v(12)
  C.stat(sx, y, sw, "最高阶段", "第 " .. tostring(pr.maxStage or 1) .. " 阶段", Theme.colors.goldBright)
  sx = sx + sw + Theme.v(12)
  C.stat(sx, y, sw, "最高筹码", C.money(pr.maxChips or 0), Theme.colors.goldBright)
  sx = sx + sw + Theme.v(12)
  C.stat(sx, y, sw, "总周目", tostring(pr.totalRuns or 0) .. " 局", Theme.colors.text)

  Draw.text("v1.0 · core-api v1.1", Theme.vx(1262), Theme.vy(694), Theme.px(10.5),
    { 0.55, 0.48, 0.34, 0.8 }, "right", Theme.v(200))
  Audio.setBGM("phase1")
end

local function tryAction(g, name, arg)
  local ok = g:action(name, arg)
  return ok and true or false
end

function T.onClick(g, st, hs)
  local id = hs.id
  if id == "title.start" then
    local UI = require("ui.ui")
    -- 核心若在 title 屏接受 select_mode 之外的开门动作，优先用它
    UI.localScreen = "modeSelect"
    return true
  elseif id == "title.tutorial" then
    if not tryAction(g, "start_tutorial") then
      require("ui.ui").notify("核心拒绝了 start_tutorial", "error")
    end
    return true
  elseif id == "title.champion" then
    if not tryAction(g, "open_deck_editor") then
      require("ui.ui").notify("冠军牌组未解锁或核心拒绝", "error")
    end
    return true
  elseif id == "title.exit" then
    love.event.quit(0)
    return true
  end
  return false
end

function T.onKey(g, st, key)
  local UI = require("ui.ui")
  if key == "return" or key == "kpenter" or key == "space" then UI.localScreen = "modeSelect"; return true end
  if key == "t" then g:action("start_tutorial"); return true end
  if key == "c" and st.progress and st.progress.hardCleared then g:action("open_deck_editor"); return true end
  return false
end

return T
