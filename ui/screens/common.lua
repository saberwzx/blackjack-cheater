-- ui/screens/common.lua : shared screen furniture (background, top bar, modal frame,
-- relic rail, hand layout, key hints). Screens are authored in a virtual 1280x720 box.
local Theme = require("ui.theme")
local Draw = require("ui.draw")
local Hot = require("ui.hot")
local W = require("ui.widgets")
local Motifs = require("ui.motifs")
local Cards = require("ui.cards")
local lg = love.graphics

local C = {}
local TAU = math.pi * 2

C.V = function(x, y) return Theme.vx(x), Theme.vy(y) end
C.s = function(n) return Theme.v(n) end

function C.money(n)
  n = math.floor(tonumber(n) or 0)
  local sign = n < 0 and "-" or ""
  n = math.abs(n)
  local s = tostring(n)
  local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
  out = out:gsub("^,", "")
  return sign .. "$" .. out
end

function C.num(n)
  local s = tostring(math.floor(tonumber(n) or 0))
  return s:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
end

function C.clamp(v, a, b) return math.max(a, math.min(b, v)) end
function C.lerp(a, b, t) return a + (b - a) * t end
function C.wtext(s, size) return W.textWidth(s or "", Theme.px(size or 14)) end

-- ================= background =================
local bgStars = nil
local function stars()
  if bgStars then return bgStars end
  bgStars = {}
  local rnd = love.math.newRandomGenerator(99117)
  for i = 1, 80 do
    bgStars[i] = { x = rnd:random() * 1280, y = rnd:random() * 720, r = 0.5 + rnd:random() * 1.3, p = rnd:random() * TAU }
  end
  return bgStars
end

function C.bg(st, opt)
  opt = opt or {}
  Draw.set(Theme.colors.bg0)
  lg.rectangle("fill", 0, 0, Theme.W, Theme.H)
  local x, y, w, h = Theme.ox, Theme.oy, Theme.vw2(), Theme.vh2()
  Draw.gradientV(x, y, w, h, { 0.085, 0.026, 0.038 }, { 0.018, 0.010, 0.014 })
  Draw.glow(x + w * 0.5, y + h * 0.38, w * 0.66, { 0.62, 0.11, 0.18, 0.26 }, 1, h * 0.60)
  Draw.glow(x + w * 0.5, y - h * 0.10, w * 0.40, { 0.95, 0.72, 0.30, 0.10 }, 1, h * 0.34)
  if not opt.noStars then
    for _, s in ipairs(stars()) do
      local tw = 0.35 + 0.35 * math.sin(Theme.time * 1.4 + s.p)
      Draw.set({ 1.0, 0.86, 0.55, tw * 0.28 })
      lg.circle("fill", Theme.vx(s.x), Theme.vy(s.y), math.max(0.5, Theme.v(s.r)), 8)
    end
  end
  local vc = { 0, 0, 0, 0.55 }
  Draw.gradientV(x, y, w, Theme.v(110), vc, { 0, 0, 0, 0 })
  Draw.gradientV(x, y + h - Theme.v(150), w, Theme.v(150), { 0, 0, 0, 0 }, { 0, 0, 0, 0.72 })
  Draw.gradientH(x, y, Theme.v(150), h, vc, { 0, 0, 0, 0 })
  Draw.gradientH(x + w - Theme.v(150), y, Theme.v(150), h, { 0, 0, 0, 0 }, vc)
  if not opt.noFlourish then
    local sz = Theme.v(74)
    Motifs.cornerFlourish(Theme.vx(16), Theme.vy(16), sz, false, false, Theme.colors.goldDim, 0.45)
    Motifs.cornerFlourish(Theme.vx(1264), Theme.vy(16), sz, true, false, Theme.colors.goldDim, 0.45)
    Motifs.cornerFlourish(Theme.vx(16), Theme.vy(704), sz, false, true, Theme.colors.goldDim, 0.45)
    Motifs.cornerFlourish(Theme.vx(1264), Theme.vy(704), sz, true, true, Theme.colors.goldDim, 0.45)
  end
end

-- oval felt table with a gold inlay ring
function C.feltTable(cx, cy, rx, ry)
  Draw.set({ 0, 0, 0, 0.45 })
  lg.ellipse("fill", cx + Theme.v(3), cy + Theme.v(7), rx, ry, 64)
  Draw.set({ 0.34, 0.24, 0.09 }); lg.ellipse("fill", cx, cy, rx + Theme.v(9), ry + Theme.v(9), 72)
  Draw.set({ 0.60, 0.45, 0.16 }); lg.ellipse("fill", cx, cy, rx + Theme.v(4), ry + Theme.v(4), 72)
  Draw.set(Theme.colors.feltDark); lg.ellipse("fill", cx, cy, rx, ry, 72)
  Draw.set(Theme.colors.felt); lg.ellipse("fill", cx, cy, rx - Theme.v(6), ry - Theme.v(6), 72)
  Draw.set({ 0.11, 0.25, 0.18, 0.5 }); lg.ellipse("fill", cx, cy - ry * 0.22, rx * 0.88, ry * 0.60, 64)
  Draw.set({ 0.55, 0.42, 0.13, 0.55 }); lg.setLineWidth(math.max(1, Theme.v(1.4)))
  lg.ellipse("line", cx, cy, rx - Theme.v(12), ry - Theme.v(12), 72)
  Draw.set({ 0.30, 0.20, 0.07, 0.5 }); lg.setLineWidth(1)
  lg.ellipse("line", cx, cy, rx - Theme.v(20), ry - Theme.v(20), 72)
  -- inlaid felt lettering: quiet and below the player hand, which sits at
  -- cy + ry * 0.29 -- never under the cards where it is unreadable.
  Draw.text("BLACKJACK  PAYS  3 TO 2", cx, cy + ry * 0.61, Theme.px(14),
    { 0.74, 0.60, 0.28, 0.18 }, "center", rx * 1.3)
  Draw.text("庄家 21 点以下须补牌 · 保险不做", cx, cy + ry * 0.61 + Theme.px(19), Theme.px(11),
    { 0.66, 0.54, 0.26, 0.14 }, "center", rx * 1.3)
end

-- ================= top bar =================
-- draws stage/round/chips/bet and the I / D / ESC entries. returns bottom y (device px)
function C.topBar(st, opt)
  opt = opt or {}
  local x, y = Theme.vx(14), Theme.vy(10)
  local w, h = Theme.v(1252), Theme.v(54)
  Draw.panel(x, y, w, h, Theme.v(7), {
    bgTop = { 0.15, 0.065, 0.075, 0.96 }, bgBot = { 0.05, 0.028, 0.034, 0.96 },
    edge = Theme.colors.edge, edgeA = 0.8,
  })
  local cx = x + Theme.v(16)
  local ty = y + Theme.v(16)
  -- stage / mode badge
  local badge = (st.mode == "bar") and "酒吧模式" or ("第 " .. tostring(st.stage or 1) .. " 阶段")
  local btxt = badge .. ((st.stageName and st.mode ~= "bar") and (" · " .. st.stageName) or "")
  Draw.text(btxt, cx, ty, Theme.px(15), Theme.colors.goldBright, "left")
  cx = cx + C.wtext(btxt, 15) + Theme.v(20)
  Draw.set({ 0.7, 0.55, 0.25, 0.45 }); lg.setLineWidth(1)
  lg.line(cx, y + Theme.v(12), cx, y + h - Theme.v(12))
  cx = cx + Theme.v(18)

  local function stat(label, value, color, vw)
    Draw.text(label, cx, y + Theme.v(11), Theme.px(10.5), Theme.colors.textDim, "left")
    Draw.text(value, cx, y + Theme.v(25), Theme.px(16), color or Theme.colors.goldPale, "left")
    cx = cx + Theme.v(vw or 108)
  end

  if st.mode == "bar" then
    stat("回合", tostring(st.round or 0) .. " / " .. tostring((st.bar and st.bar.totalRounds) or 100), Theme.colors.goldPale, 120)
    stat("酒局胜", tostring((st.bar and st.bar.wins) or 0), Theme.colors.positive, 90)
    stat("酒局负", tostring((st.bar and st.bar.losses) or 0), Theme.colors.negative, 90)
    stat("赠礼概率", string.format("%.1f%%", ((st.bar and st.bar.prob) or 0) * 100), Theme.colors.cyan, 120)
  else
    stat("本阶段", tostring(st.roundsInStage or 0) .. " / " .. tostring(st.stageRounds or 0), Theme.colors.goldPale, 96)
    stat("总回合", tostring(st.round or 0), Theme.colors.goldPale, 76)
    stat("筹码", C.money(st.chips or 0), Theme.colors.goldBright, 148)
    stat("目标", C.money(st.stageTarget or 0), Theme.colors.textDim, 148)
    if st.bet and st.bet > 0 then
      stat("本局注", C.money(st.bet), Theme.colors.orange, 128)
    end
    stat("连胜", tostring(st.streak or 0), (st.streak or 0) > 1 and Theme.colors.hot or Theme.colors.textDim, 66)
  end

  -- right entries
  local bx = x + w - Theme.v(46)
  local by = y + h * 0.5
  W.iconButton({ id = "top.settings", x = bx, y = by, r = Theme.v(15), glyph = "设", glyphSize = 13,
    color = Theme.colors.gold, tip = "设置（ESC）", tipTitle = "设置", data = { action = "settings" } })
  if st.mode ~= "bar" then
    bx = bx - Theme.v(40)
    W.iconButton({ id = "top.deck", x = bx, y = by, r = Theme.v(15), glyph = "D", glyphSize = 15,
      color = Theme.colors.blue, tip = "牌堆总览（D）：查看全部手牌与特殊牌", tipTitle = "牌堆总览", data = { action = "deck" } })
    bx = bx - Theme.v(40)
    W.iconButton({ id = "top.shoe", x = bx, y = by, r = Theme.v(15), glyph = "I", glyphSize = 15,
      color = Theme.colors.cyan, tip = "情报面板（I）：顺序带 / 成分 / 爆率 / 弃牌堆", tipTitle = "情报", data = { action = "shoe" } })
  end
  return y + h
end

-- ================= modal frame =================
-- returns content x, content y, content w, content h (device px)
function C.modal(title, opts)
  opts = opts or {}
  local w = Theme.v(opts.w or 1000)
  local h = Theme.v(opts.h or 620)
  local x = Theme.vx((1280 - (opts.w or 1000)) * 0.5)
  local y = Theme.vy((720 - (opts.h or 620)) * 0.5)
  Draw.set({ 0, 0, 0, 0.62 })
  lg.rectangle("fill", 0, 0, Theme.W, Theme.H)
  Draw.glow(x + w * 0.5, y + h * 0.5, w * 0.62, { 0.75, 0.42, 0.14, 0.12 }, 1, h * 0.62)
  Draw.panel(x, y, w, h, Theme.v(10), {
    bgTop = { 0.13, 0.062, 0.072, 1 }, bgBot = { 0.035, 0.020, 0.026, 1 },
    edge = Theme.colors.gold, edgeA = 0.75, lw = Theme.v(1.6), shadowA = 0.7,
  })
  Draw.ornateFrame(x, y, w, h, Theme.v(10), Theme.colors.goldDim, 0.85)
  local barH = Theme.v(46)
  Draw.gradientV(x, y, w, barH, { 0.24, 0.11, 0.09, 1 }, { 0.10, 0.05, 0.05, 1 })
  Draw.hline(x + Theme.v(10), y + barH, w - Theme.v(20), Theme.colors.gold, 0.75, Theme.v(1.3))
  Draw.textOutline(title, x + w * 0.5, y + Theme.v(13), Theme.px(20), Theme.colors.goldBright, { 0.10, 0.04, 0.02, 0.95 }, "center", w - Theme.v(90), Theme.v(1.4))
  if opts.subtitle then
    Draw.text(opts.subtitle, x + w * 0.5, y + barH - Theme.v(2), Theme.px(11), Theme.colors.textDim, "center", w - Theme.v(90))
  end
  local ccx = x + w - Theme.v(26)
  W.iconButton({ id = (opts.id or "modal") .. ".close", x = ccx, y = y + barH * 0.5, r = Theme.v(13), glyph = "×",
    glyphSize = 17, color = Theme.colors.redBright, tip = opts.closeTip or "关闭（ESC）",
    tipTitle = "关闭", data = { action = opts.closeAction or "close_top" } })
  return x, y + barH, w, h - barH
end

-- ================= relic rail =================
-- rel = {x,y,w,h, interactive, vertical, showMark}
function C.relicBar(st, rel)
  local m = Theme.metrics
  local rw, rh = Theme.v(m.relicW * (rel.scale or 1)), Theme.v(m.relicH * (rel.scale or 1))
  local gap = Theme.v(rel.gap or 8)
  local list = st.relics or {}
  local n = #list
  local maxSlots = st.relicSlotMax or m.relicSlots
  local slots = math.max(maxSlots, n)
  local interactive = rel.interactive ~= false
  local cols = rel.cols or (rel.vertical and 1 or slots)
  cols = math.max(1, math.min(cols, slots))
  local function slotPos(idx)
    local c0 = (idx - 1) % cols
    local r0 = math.floor((idx - 1) / cols)
    return rel.x + c0 * (rw + gap), rel.y + r0 * (rh + gap)
  end
  local out = {}
  for i = 1, slots do
    local r = list[i]
    local x, y = slotPos(i)
    local empty = (r == nil)
    local active = r and (r._active or r.active) or false
    local usable = r and (r._consumable or r.consumable) and ((r._usesLeft or r.usesLeft or 0) > 0)
    local alpha = empty and 0.32 or (usable and 0.45 or 1)
    Draw.set({ 0, 0, 0, 0.45 })
    lg.rectangle("fill", x + Theme.v(2), y + Theme.v(3), rw, rh, Theme.v(5), Theme.v(5))
    local rarity = r and Theme.rarityColor(r.rarity) or { 0.32, 0.28, 0.26 }
    Draw.gradientV(x, y, rw, rh, { 0.14 + rarity[1] * 0.10, 0.07 + rarity[2] * 0.08, 0.07 + rarity[3] * 0.08 },
      { 0.045, 0.028, 0.030 })
    if r then
      if active then
        Draw.glow(x + rw * 0.5, y + rh * 0.5, rw * 0.92, { 1.0, 0.82, 0.34, 0.30 }, 1, rh * 0.72)
      end
      local iw, ih = rw * 0.72, rh * 0.52
      Motifs.relicIcon(x + (rw - iw) * 0.5, y + Theme.v(6), iw, ih, r, { grey = not alpha or alpha < 0.6 })
      Draw.text(r.name or "?", x + rw * 0.5, y + rh - Theme.v(26), Theme.px(10.5),
        active and Theme.colors.goldPale or Theme.colors.textDim, "center", rw - Theme.v(4))
      if usable then
        Draw.text("剩 " .. tostring(r._usesLeft or r.usesLeft), x + rw * 0.5, y + rh - Theme.v(14), Theme.px(9),
          Theme.colors.orange, "center", rw - Theme.v(4))
      elseif r._forged or r.forged then
        Draw.text("已锻造", x + rw * 0.5, y + rh - Theme.v(14), Theme.px(9), Theme.colors.purple, "center", rw - Theme.v(4))
      end
    else
      Draw.text("空", x + rw * 0.5, y + rh * 0.5 - Theme.px(8), Theme.px(12), { 0.4, 0.36, 0.34 }, "center", rw)
    end
    local edge = active and Theme.colors.goldBright or rarity
    Draw.frame(x, y, rw, rh, Theme.v(5), edge, alpha)
    if active then Draw.frame(x + Theme.v(1.5), y + Theme.v(1.5), rw - Theme.v(3), rh - Theme.v(3), Theme.v(4), Theme.colors.goldBright, 0.35, 1) end
    if r then
      local tipText = (r.desc or "")
      if r._consumable or r.consumable then
        tipText = tipText .. "\n消耗品 · 剩余 " .. tostring(r._usesLeft or r.usesLeft or 0) .. " 次"
      end
      if active then tipText = tipText .. "\n（已点亮 · 本小局生效）"
      elseif (r._consumable or r.consumable) then tipText = tipText .. "\n（点击使用）"
      else tipText = tipText .. "\n（点击点亮）" end
      local rr = { x = 0, y = 0, w = 0, h = 0 }
      if interactive then
        rr = Hot.btn({ id = string.format("relic.%d", i), x = x, y = y, w = rw, h = rh, kind = "relic",
          tip = tipText, tipTitle = r.name, data = { index = i, relic = r } })
      end
      out[i] = rr
    end
  end
  -- special mark slot
  if rel.showMark ~= false and st.specialMarks and st.specialMarks.held then
    local held = st.specialMarks.held
    local x, y = slotPos(slots + 1)
    local col = ({ red = Theme.colors.red, gold = Theme.colors.gold, purple = Theme.colors.purple,
      green = Theme.colors.green, grey = Theme.colors.grey })[held.color] or Theme.colors.gold
    Draw.set({ 0, 0, 0, 0.45 }); lg.rectangle("fill", x + 2, y + 3, rw, rh, Theme.v(5), Theme.v(5))
    Draw.gradientV(x, y, rw, rh, { 0.16, 0.08, 0.10 }, { 0.05, 0.03, 0.035 })
    Draw.glow(x + rw * 0.5, y + rh * 0.5, rw * 0.85, { col[1], col[2], col[3], 0.28 }, 1, rh * 0.7)
    Motifs.relicIcon(x + rw * 0.14, y + Theme.v(8), rw * 0.72, rh * 0.5, { icon = 6 }, {})
    Draw.text(held.name or "特殊标记", x + rw * 0.5, y + rh - Theme.v(26), Theme.px(10),
      Theme.colors.goldPale, "center", rw - Theme.v(4))
    Draw.text("剩 " .. tostring(held.usesLeft or 0), x + rw * 0.5, y + rh - Theme.v(14), Theme.px(9),
      Theme.colors.orange, "center", rw - Theme.v(4))
    Draw.frame(x, y, rw, rh, Theme.v(5), col, 1)
    Hot.btn({ id = "mark.special", x = x, y = y, w = rw, h = rh, kind = "mark",
      tip = "特殊标记：点击后选择要标记的牌（每局一次，不可被发现）", tipTitle = held.name or "特殊标记",
      data = { special = true, id = held.id } })
    out.special = { x = x, y = y, w = rw, h = rh }
  end
  return out
end

-- ================= hand layout =================
-- returns list of slot rects {x,y,w,h,card,index,hidden}
function C.hand(cards, cx, cy, opts)
  opts = opts or {}
  local m = Theme.metrics
  local cw = Theme.v(opts.w or m.cardW)
  local ch = Theme.v(opts.h or m.cardH)
  local maxW = Theme.v(opts.maxW or 420)
  local n = #cards
  if n == 0 then return {} end
  local step = cw + Theme.v(opts.gap or 6)
  if (n - 1) * step + cw > maxW then
    step = n > 1 and ((maxW - cw) / (n - 1)) or 0
  end
  local totalW = (n - 1) * step + cw
  local x0 = cx - totalW * 0.5
  local y0 = cy - ch * 0.5
  local out = {}
  for i, card in ipairs(cards) do
    local hidden = false
    if opts.hiddenIndex and opts.hiddenIndex(i) then hidden = true end
    out[i] = { x = x0 + (i - 1) * step, y = y0, w = cw, h = ch, card = card, index = i, hidden = hidden }
  end
  return out
end

function C.drawHand(st, slots, opts)
  opts = opts or {}
  local uivfx = require("ui.ui").vfx
  for i, s in ipairs(slots) do
    local tell = uivfx.tells["uid:" .. tostring(s.card and s.card.uid or "")]
    local anim = opts.animPrefix and uivfx.anims[opts.animPrefix .. ":" .. tostring(i)] or nil
    local x, y, a = s.x, s.y, 1
    if anim then
      local k = require("ui.ease").outCubic(math.min(1, anim.t / anim.dur))
      y = s.y - Theme.v(120) * (1 - k)
      x = s.x + Theme.v(40) * (1 - k)
      a = 0.25 + 0.75 * k
    end
    -- A 出千：暗牌位持续轻微抖动（真痕迹）。dA 是假痕迹，固定不抖。
    if tell and tell.kind == "A" and tell.real then
      local tt = tell.t or 0
      x = x + math.sin(tt * 40) * s.w * 0.02
      y = y + math.sin(tt * 37 + 1.3) * s.h * 0.008
    end
    Cards.draw(s.card, x, y, s.w, s.h, {
      hidden = s.hidden, alpha = a,
      selected = opts.selected and opts.selected[i] or false,
      dim = opts.dim and opts.dim[i] or false,
      mark = opts.mark and opts.mark[i] or nil,
      tell = tell,
      hover = Hot.isHover(opts.hotPrefix and (opts.hotPrefix .. "." .. i) or " "),
    })
  end
end

-- ================= hints =================
function C.hints(items, y)
  if not items or #items == 0 then return end
  local size = Theme.px(12)
  local gap = Theme.v(18)
  local total = 0
  for _, it in ipairs(items) do
    total = total + Theme.v(26) + C.wtext(it[2], 12) + gap
  end
  local x = Theme.vx(640) - total * 0.5
  local yy = Theme.vy(y)
  for _, it in ipairs(items) do
    local kw = Theme.v(22)
    local kh = Theme.v(19)
    Draw.set({ 0, 0, 0, 0.5 }); lg.rectangle("fill", x, yy, kw, kh, Theme.v(4), Theme.v(4))
    Draw.frame(x, yy, kw, kh, Theme.v(4), Theme.colors.gold, 0.75, 1)
    Draw.text(it[1], x + kw * 0.5, yy + (kh - Theme.px(13)) * 0.5, Theme.px(12), Theme.colors.goldBright, "center")
    x = x + kw + Theme.v(7)
    Draw.text(it[2], x, yy + (kh - Theme.px(13)) * 0.5, size, Theme.colors.textDim, "left")
    x = x + C.wtext(it[2], 12) + gap
  end
end

-- small stat chip used by several screens
function C.stat(x, y, w, label, value, color)
  local h = Theme.v(46)
  Draw.panel(x, y, w, h, Theme.v(5), { bgTop = { 0.13, 0.075, 0.075, 0.9 }, bgBot = { 0.05, 0.03, 0.035, 0.9 } })
  Draw.text(label, x + w * 0.5, y + Theme.v(5), Theme.px(10.5), Theme.colors.textDim, "center", w)
  Draw.text(value, x + w * 0.5, y + Theme.v(20), Theme.px(17), color or Theme.colors.goldBright, "center", w)
  return h
end

function C.sectionTitle(text, x, y, w, sub)
  Draw.text(text, x, y, Theme.px(17), Theme.colors.goldBright, "left")
  Draw.hline(x, y + Theme.px(23), w, Theme.colors.goldDim, 0.6, 1)
  if sub then Draw.text(sub, x, y + Theme.px(26), Theme.px(11), Theme.colors.textDim, "left") end
end

return C
