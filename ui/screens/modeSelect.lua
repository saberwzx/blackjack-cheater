local Theme = require("ui.theme")
local Draw = require("ui.draw")
local Hot = require("ui.hot")
local W = require("ui.widgets")
local Motifs = require("ui.motifs")
local Audio = require("ui.audio")
local C = require("ui.screens.common")
local lg = love.graphics

local M = {}

-- ===== 模式选择：基础 / 困难 / 酒吧 =====
local MODES = {
  {
    id = "normal", name = "基础", en = "NORMAL", tone = "gold",
    lines = { "共 60 小局：15 + 15 + 30", "三个赌场逐级递进", "只有你能选择职阶", "庄家从第 1 阶段就拥有职阶" },
    goal = "新手赌场 $2,000 → 老练赌场 $20,000 → 黑暗赌场 $2,000,000",
    note = "标准难度：出千概率 0% → 20% → 45%",
  },
  {
    id = "hard", name = "困难", en = "HARD", tone = "red",
    lines = { "共 60 小局：15 + 15 + 30", "庄家从第 1 阶段起拥有职阶", "每次阶段切换庄家换职阶", "目标与基础相同" },
    goal = "新手赌场 $2,000 → 老练赌场 $20,000 → 黑暗赌场 $2,000,000",
    note = "庄家职阶全程压制，通关后解锁冠军牌组",
  },
  {
    id = "bar", name = "酒吧", en = "BAR", tone = "purple",
    lines = { "共 100 小局纯酒局", "没有筹码、下注、遗物与阶段", "不会破产，也无需在意目标", "每局可用 1 次调酒技能" },
    goal = "喝光 6 杯调酒会离开酒吧；撑到最后按剩余酒量结算结局",
    note = "宿醉、赠酒、34 款调酒与塔罗牌技能",
  },
}

local S = {}

function S.draw(g, st)
  C.bg(st)
  local UI = require("ui.ui")
  Draw.title("选择模式", Theme.vx(640), Theme.vy(44), Theme.px(34), "center", Theme.v(600))
  Draw.text("每种模式的赌场节奏一致，区别在于庄家的强度与规则限制", Theme.vx(640), Theme.vy(88),
    Theme.px(12.5), Theme.colors.textDim, "center", Theme.v(900))

  local cw, chh = Theme.v(348), Theme.v(420)
  local gap = Theme.v(26)
  local total = cw * 3 + gap * 2
  local x = Theme.vx(640) - total * 0.5
  local y = Theme.vy(126)

  for _, m in ipairs(MODES) do
    local hs = Hot.btn({ id = "mode." .. m.id, x = x, y = y, w = cw, h = chh, kind = "card",
      tip = m.goal .. "\n" .. m.note, tipTitle = m.name .. "模式",
      data = { mode = m.id } })
    local hovered = (Hot.hover == hs)
    local lift = hovered and Theme.v(6) or 0
    local yy = y - lift
    Draw.set({ 0, 0, 0, 0.5 }); lg.rectangle("fill", x + Theme.v(3), yy + Theme.v(5), cw, chh, Theme.v(10), Theme.v(10))
    local top = hovered and { 0.20, 0.09, 0.10 } or { 0.13, 0.062, 0.072 }
    Draw.gradientV(x, yy, cw, chh, top, { 0.035, 0.020, 0.026 })
    local accent = (m.tone == "gold" and Theme.colors.gold) or (m.tone == "red" and Theme.colors.redBright) or Theme.colors.purple
    if hovered then Draw.glow(x + cw * 0.5, yy + chh * 0.35, cw * 0.62, { accent[1], accent[2], accent[3], 0.22 }, 1, chh * 0.5) end
    Draw.gradientV(x, yy, cw, Theme.v(90), { accent[1], accent[2], accent[3], 0.30 }, { accent[1], accent[2], accent[3], 0 })
    Draw.frame(x, yy, cw, chh, Theme.v(10), accent, hovered and 1 or 0.65, hovered and Theme.v(2) or Theme.v(1.4))

    Draw.text(m.en, x + cw * 0.5, yy + Theme.v(18), Theme.px(12), { accent[1], accent[2], accent[3], 0.9 }, "center", cw)
    Draw.title(m.name, x + cw * 0.5, yy + Theme.v(36), Theme.px(34), "center", cw)
    Draw.hline(x + Theme.v(28), yy + Theme.v(92), cw - Theme.v(56), accent, 0.5, 1)

    local ly = yy + Theme.v(108)
    for _, line in ipairs(m.lines) do
      Draw.set(accent); lg.circle("fill", x + Theme.v(30), ly + Theme.px(7), Theme.v(2.6), 10)
      Draw.text(line, x + Theme.v(42), ly, Theme.px(13), Theme.colors.text, "left", cw - Theme.v(58))
      ly = ly + Theme.px(21)
    end
    ly = ly + Theme.v(10)
    Draw.text("目标", x + Theme.v(24), ly, Theme.px(11), Theme.colors.textDim, "left")
    Draw.wrapped(m.goal, x + Theme.v(24), ly + Theme.px(16), Theme.px(11.5), Theme.colors.goldBright, cw - Theme.v(48), 1.3)
    ly = ly + Theme.v(64)
    Draw.wrapped("· " .. m.note, x + Theme.v(24), ly, Theme.px(11), Theme.colors.textDim, cw - Theme.v(48), 1.3)

    W.button({ id = "mode.pick." .. m.id, x = x + Theme.v(24), y = yy + chh - Theme.v(62),
      w = cw - Theme.v(48), h = Theme.v(44), label = "选择" .. m.name, tone = m.tone, size = 17,
      hotkey = m.id == "normal" and "1" or (m.id == "hard" and "2" or "3"),
      tip = "以" .. m.name .. "模式开始新周目", tipTitle = m.name, data = { mode = m.id } })
    x = x + cw + gap
  end

  W.button({ id = "mode.back", x = Theme.vx(24), y = Theme.vy(30), w = Theme.v(110), h = Theme.v(38),
    label = "返回", tone = "dark", size = 15, hotkey = "Esc",
    tip = "回到标题画面", tipTitle = "返回" })
  C.hints({ { "1", "基础" }, { "2", "困难" }, { "3", "酒吧" }, { "Esc", "返回" } }, 672)
end

local function pick(g, mode)
  local UI = require("ui.ui")
  local ok = g:action("select_mode", mode)
  if not ok then
    if g:action("open_mode_select") then ok = g:action("select_mode", mode) end
  end
  if ok then
    UI.localScreen = nil
  else
    UI.localScreen = "modeSelect"
    UI.notify("核心未接受 select_mode（需要 title → modeSelect 的开屏动作）", "error")
  end
end

function S.onClick(g, st, hs)
  local id = hs.id
  local m = id:match("^mode%.pick%.(%w+)$") or id:match("^mode%.(%w+)$")
  if m then pick(g, m); return true end
  if id == "mode.back" then require("ui.ui").localScreen = nil; return true end
  return false
end

function S.onKey(g, st, key)
  local UI = require("ui.ui")
  if key == "1" then pick(g, "normal"); return true end
  if key == "2" then pick(g, "hard"); return true end
  if key == "3" then pick(g, "bar"); return true end
  if key == "escape" then UI.localScreen = nil; return true end
  return false
end

return S
