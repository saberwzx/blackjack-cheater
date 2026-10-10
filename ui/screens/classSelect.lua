-- ui/screens/classSelect.lua : 第 2 阶段达成后的 7 选 1 职阶选择
local Theme = require("ui.theme")
local lg = love.graphics
local Draw = require("ui.draw")
local Fonts = require("ui.fonts")
local W = require("ui.widgets")
local C = require("ui.screens.common")
local Hot = require("ui.hot")

local S = {}

-- 静态职阶资料（GDD E1）。核心若通过 getView 提供 classList，则以其为准。
local CLASS_DATA = {
  { id = "saber",     name = "剑客",   letter = "S", color = "red",      desc = "结算前斩掉庄家最小的一张牌。" },
  { id = "lancer",    name = "枪兵",   letter = "L", color = "blue",     desc = "起手多发一张牌。" },
  { id = "archer",    name = "弓手",   letter = "A", color = "orange",   desc = "下注阶段即可预览牌堆第一张。" },
  { id = "rider",     name = "骑士",   letter = "R", color = "green",    desc = "每局可跳过发牌，仅退款本局注（3 次）。" },
  { id = "caster",    name = "术士",   letter = "C", color = "purple",   desc = "每 3 连胜可三选一替换遗物。" },
  { id = "assassin",  name = "刺客",   letter = "X", color = "grey",     desc = "庄家看不见你的牌，封锁其换牌与镜影出千。" },
  { id = "berserker", name = "狂战士", letter = "B", color = "dark",     desc = "25 点以内不爆；只要不爆且高于庄家即胜。" },
}

local function classList(st)
  if st.classList and #st.classList > 0 then return st.classList end
  return CLASS_DATA
end

local function colorOf(c)
  local t = Theme.colors
  return t[c] or t.gold
end

local COLS = 4
local function layout(i, n)
  local cw, chh = Theme.v(268), Theme.v(206)
  local gap = Theme.v(18)
  local rows = math.ceil(n / COLS)
  local ri = math.ceil(i / COLS)
  local inRow = (ri == rows) and (n - (rows - 1) * COLS) or COLS
  local c0 = (i - 1) % COLS
  local totalW = inRow * cw + (inRow - 1) * gap
  local x0 = Theme.vx(640) - totalW * 0.5
  local y0 = Theme.vy(196) + (ri - 1) * (chh + gap)
  return x0 + c0 * (cw + gap), y0, cw, chh
end

function S.draw(g, st)
  C.bg(st)
  C.topBar(st, {})
  Draw.text("选 择 职 阶", Theme.vx(640), Theme.vy(104), Theme.px(30), Theme.colors.goldBright, "center", Theme.v(700))
  Draw.text("第 2 阶段达成 · 职阶效果贯穿黑暗赌场 · 谨慎选择", Theme.vx(640), Theme.vy(142), Theme.px(14),
    Theme.colors.textDim, "center", Theme.v(900))

  local list = classList(st)
  local chosen = st.playerClass and st.playerClass.id or nil
  for i, c in ipairs(list) do
    local x, y, cw, chh = layout(i, #list)
    local hovered = Hot.isHover("cls.card." .. i)
    local y2 = y - (hovered and Theme.v(6) or 0)
    local col = colorOf(c.color)
    Draw.set({ 0, 0, 0, 0.5 })
    lg.rectangle("fill", x + Theme.v(4), y2 + Theme.v(5), cw, chh, Theme.v(9), Theme.v(9))
    Draw.panel(x, y2, cw, chh, Theme.v(9), {
      bgTop = { 0.14, 0.075, 0.078, 1 }, bgBot = { 0.045, 0.028, 0.032, 1 },
      edge = hovered and Theme.colors.goldBright or col, edgeA = 0.9, lw = Theme.v(1.4),
    })
    if hovered then Draw.glow(x + cw * 0.5, y2 + Theme.v(52), cw * 0.5, { col[1], col[2], col[3], 0.24 }, 1, Theme.v(60)) end

    -- 职阶徽记
    local cxx, cyy, rr = x + Theme.v(46), y2 + Theme.v(52), Theme.v(28)
    Draw.set(col[1], col[2], col[3], 0.18)
    lg.circle("fill", cxx, cyy, rr)
    Draw.set(col[1], col[2], col[3], 0.95); lg.setLineWidth(Theme.v(2))
    lg.circle("line", cxx, cyy, rr)
    Draw.text(c.letter or "?", cxx, cyy - Theme.px(13), Theme.px(22), col, "center")

    Draw.text((c.name or "?"), x + Theme.v(84), y2 + Theme.v(24), Theme.px(21), Theme.colors.goldBright, "left", cw - Theme.v(96))
    Draw.text(c.id or "", x + Theme.v(84), y2 + Theme.v(50), Theme.px(11), Theme.colors.textDim, "left", cw - Theme.v(96))

    local font = Fonts.get(Theme.px(12.5))
    local lines = Fonts.wrap(c.desc or "", font, cw - Theme.v(34))
    local lh = Fonts.height(font, Theme.v(4))
    for k, ln in ipairs(lines) do
      if k > 5 then break end
      Draw.text(ln, x + Theme.v(18), y2 + Theme.v(84) + (k - 1) * lh, Theme.px(12.5), Theme.colors.text, "left", cw - Theme.v(36))
    end

    if chosen == c.id then
      Draw.text("已选择", x + cw * 0.5, y2 + chh - Theme.v(30), Theme.px(12), Theme.colors.positive, "center", cw)
    end
    Hot.btn({
      id = "cls.card." .. i, x = x, y = y2, w = cw, h = chh, kind = "class",
      tip = (c.desc or "") .. "\n\n点击选择该职阶（不可更改）", tipTitle = (c.name or "职阶") .. " " .. (c.letter or ""),
      data = { index = i, id = c.id },
    })
    W.button({
      id = "cls.pick." .. i, x = x + Theme.v(18), y = y2 + chh - Theme.v(42), w = cw - Theme.v(36), h = Theme.v(32),
      label = "选择 " .. (c.name or ""), tone = hovered and "gold" or "dark", size = 14,
      data = { index = i, id = c.id }, hotkey = tostring(i),
      tip = "确认选择 " .. (c.name or ""), tipTitle = "职阶",
    })
  end

  C.hints({ { "1-7", "选择职阶" }, { "H/S", "发牌 / 停牌" } }, 690)
end

function S.onClick(g, st, hs)
  local id = hs.id
  local i = id:match("^cls%.pick%.(%d)$") or id:match("^cls%.card%.(%d)$")
  if i then
    local list = classList(st)
    local entry = list[tonumber(i)]
    if entry then
      local ok, err = g:action("choose_class", entry.id)
      if ok == false or (ok == nil and err ~= nil) then
        require("ui.ui").notify("无法选择该职阶：" .. tostring(err or "不可用"), "error")
      else
        require("ui.ui").notify("已选择职阶：" .. (entry.name or entry.id), "success")
      end
    end
    return true
  end
  return false
end

function S.onKey(g, st, key)
  local i = tonumber(key)
  local list = classList(st)
  if i and i >= 1 and i <= #list then
    g:action("choose_class", list[i].id)
    return true
  end
  return false
end

return S
