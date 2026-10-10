-- ui/screens/table.lua : the card table (bet / player / dealer / result).
-- Single source of hotspots: every button rect is written here, and the click
-- handler reads back the same cached hotspot table.
local Theme = require("ui.theme")
local Draw = require("ui.draw")
local Hot = require("ui.hot")
local W = require("ui.widgets")
local Motifs = require("ui.motifs")
local Cards = require("ui.cards")
local C = require("ui.screens.common")
local lg = love.graphics

local T = {}
local TOUT = { player = "你赢了", dealer = "庄家赢", push = "和局" }
local TOUT_COLOR = { player = "positive", dealer = "negative", push = "textGold" }
local KIND_COLOR = { base = "goldPale", mult = "cyan", x_mult = "orange", add = "positive" }

local betSlider = nil

-- Availability source of truth.
-- src/game_state.lua GS:can() answers "true" for every action it does not know,
-- so an unknown action must never be treated as available: each action is
-- gated here from public view fields, and g:can() can only subtract (AND).
local function hasRelic(st, id, lit)
  for _, rel in ipairs(st.relics or {}) do
    if rel.id == id then
      if not lit then return true end
      return (rel._active or rel.active) and true or false
    end
  end
  return false
end

local CAN_UI = {
  -- Rider class (3 uses) or the lit 骑之残卷 shard relic
  skip_round = function(st)
    local c = st.playerClass
    if c and c.id == "rider" and (c.usesLeft or 0) > 0 then return true end
    if hasRelic(st, "class_rider_shard", true) and not (st.flags and st.flags.riderUsedThisRound) then return true end
    return false
  end,
  -- lit 后期投降 relic and a total below 18
  surrender = function(st)
    local p = st.player or {}
    if st.state ~= "player" or p.stood or p.busted or p.surrendered then return false end
    if not hasRelic(st, "late_surrender", true) then return false end
    return (p.total or 0) < 18
  end,
}

local function can(g, name, arg)
  local st = g.getView and g:getView() or nil
  local ui = CAN_UI[name]
  if ui then return (st ~= nil) and ui(st) and true or false end
  if not (g.can and st) then return false end
  return g:can(name, arg) == true
end

local function isMarked(card)
  if not card then return false end
  return card.mark or card._mark or card.marked or card.markColor
end

local function totalColor(v, busted, blackjack)
  if busted then return Theme.colors.redBright end
  if blackjack then return Theme.colors.goldBright end
  return Theme.colors.textGold
end

local function badge(cx, cy, label, value, v, busted, blackjack)
  local r = Theme.v(26)
  Draw.set({ 0, 0, 0, 0.55 }); lg.circle("fill", cx + 2, cy + 3, r, 28)
  Draw.set({ 0.10, 0.06, 0.05 }); lg.circle("fill", cx, cy, r, 28)
  local col = totalColor(v, busted, blackjack)
  if busted or blackjack then Draw.glow(cx, cy, r * 1.5, { col[1], col[2], col[3], 0.30 }, 1) end
  Draw.circleLine(cx, cy, r, col, 0.95, math.max(1.4, Theme.v(1.6)))
  Draw.text(label, cx, cy - Theme.v(17), Theme.px(9.5), Theme.colors.textDim, "center")
  Draw.text(tostring(v or 0), cx, cy - Theme.v(6), Theme.px(18), col, "center")
end

-- ================= hands =================
local lastSlots = { dealer = {}, player = {} }

local function findSlot(side, card)
  local slots = lastSlots[side] or {}
  if card then
    for _, s in ipairs(slots) do
      if s.card and card.uid and s.card.uid == card.uid then return s end
    end
    for _, s in ipairs(slots) do
      if s.card and not card.uid and card.rank == s.card.rank and card.suit == s.card.suit then return s end
    end
  end
  return nil
end

-- 键名必须是核心里 emit 的 markId 原值（src/marks.lua 的 id / src/game_state.lua:547-607）
local MARK_COLOR = {
  mark_vanish = { 0.70, 0.70, 0.74 },
  mark_bomb = { 0.92, 0.28, 0.22 },
  mark_flame = { 0.96, 0.62, 0.22 },
  mark_void = { 0.62, 0.38, 0.92 },
  mark_bounty = { 0.36, 0.82, 0.46 },
  black_hole = { 0.24, 0.12, 0.34 },
}

local function handCenter(side)
  return Theme.vx(616), Theme.vy(side == "dealer" and 168 or 398)
end

-- 职阶 / 标记特效：拔刀斩与 5 种特种标记的 0.9s 演出
local function combatFx(g, st)
  local UI = require("ui.ui")
  local Ease = require("ui.ease")
  local vfx = UI.vfx
  if vfx.slash then
    local fx = vfx.slash
    local t = C.clamp(fx.t / (fx.dur or 0.9), 0, 1)
    local side = (fx.side == "player") and "player" or "dealer"
    local s = findSlot(side, fx.card)
    local x, y, w, h
    if s then
      x, y, w, h = s.x, s.y, s.w, s.h
    else
      local cx, cy = handCenter(side)
      x, y, w, h = cx - Theme.v(215), cy - Theme.v(47), Theme.v(430), Theme.v(94)
    end
    local a = math.sin(t * math.pi)
    -- 牌面被斩中的白闪
    if a > 0.05 then
      Draw.set(1, 1, 1, a * 0.35)
      lg.rectangle("fill", x, y, w, h, Theme.v(4))
    end
    local x1, y1 = x - w * 0.15 + w * 1.3 * t, y + h * 0.05 + h * 0.9 * t
    local x2, y2 = x1 - w * 0.42, y1 - h * 0.30
    Draw.set({ 1, 0.95, 0.72, a })
    lg.setLineWidth(math.max(2.5, Theme.v(4.2)))
    lg.line(x1, y1, x2, y2)
    Draw.set({ 1, 0.55, 0.30, a * 0.7 })
    lg.setLineWidth(math.max(1.5, Theme.v(2)))
    lg.line(x1 + Theme.v(3), y1 + Theme.v(2), x2 + Theme.v(3), y2 + Theme.v(2))
    lg.setLineWidth(1)
    Draw.text("拔刀斩", x + w * 0.5, y - Theme.v(20), Theme.px(15), { 1, 0.85, 0.55, a }, "center", w)
  end

  local mf = vfx.markFx
  if mf then
    local t = C.clamp(mf.t / (mf.dur or 0.9), 0, 1)
    local cx, cy
    if mf.anchor == "shoe" then
      cx, cy = Theme.vx(978), Theme.vy(126)
    else
      local side = (mf.anchor == "dealer") and "dealer" or "player"
      local s = findSlot(side, mf.card)
      if s then cx, cy = s.x + s.w * 0.5, s.y + s.h * 0.5 else cx, cy = handCenter(side) end
    end
    local col = MARK_COLOR[mf.id] or { 0.85, 0.75, 0.4 }
    local rr = Theme.v(12) + Theme.v(58) * Ease.outCubic(t)
    Draw.set(col[1], col[2], col[3], (1 - t) * 0.9)
    lg.setLineWidth(math.max(2, Theme.v(3) * (1 - t * 0.5)))
    lg.circle("line", cx, cy, rr, 40)
    Draw.set(col[1], col[2], col[3], (1 - t) * 0.5)
    lg.circle("line", cx, cy, rr * 0.62, 36)
    lg.setLineWidth(1)
    Draw.set(col[1], col[2], col[3], (1 - t) * 0.35)
    lg.circle("fill", cx, cy, rr * 0.35, 30)
    if not mf._burst then
      mf._burst = true
      UI.particles:emit(cx, cy, { count = 18, speed = 90, life = 0.7, size = 3, color = { col[1], col[2], col[3], 0.95 }, kind = "spark" })
    end
  end
end

local function handBlock(g, st, side)
  local isDealer = (side == "dealer")
  local ent = isDealer and st.dealer or st.player
  local hand = ent.hand or {}
  local cy = isDealer and 168 or 398
  local cx = 616
  local slots = C.hand(hand, Theme.vx(cx), Theme.vy(cy), {
    w = 66, h = 94, maxW = 430, gap = 7,
    hiddenIndex = isDealer and function(i) return i == 1 and not ent.holeRevealed end or nil,
  })
  local markedFlags = {}
  for i, s in ipairs(slots) do
    markedFlags[i] = isMarked(s.card)
    local zone = isDealer and "dealer" or "player"
    local clickable = (not s.hidden)
    local tip
    if s.hidden then tip = "暗牌：不可见，也不可能被标记。"
    else
      tip = "点击打墨水标记（消耗筹码）；再次点击取消标记。"
      if st.state ~= "player" and st.state ~= "bet" then tip = "标记只在可以出千的行动阶段生效。" end
    end
    Hot.btn({ id = string.format("tbl.%s.%d", zone, i), x = s.x, y = s.y, w = s.w, h = s.h,
      enabled = clickable, kind = "card", tip = tip,
      tipTitle = (isDealer and "庄家" or "你的") .. "第 " .. i .. " 张牌",
      data = { zone = zone, index = i, card = s.card } })
  end
  C.drawHand(st, slots, {
    animPrefix = side,
    mark = markedFlags,
    hotPrefix = "tbl." .. side,
  })

  lastSlots[side] = slots
  -- 弓手预视：核心把玩家已经看过的牌标上 _peek，只给玩家自己看
  if not isDealer then
    for i, s in ipairs(slots) do
      if s.card and s.card._peek then
        local col = { 0.30, 0.86, 0.96, 0.95 }
        Draw.set(col)
        lg.setLineWidth(math.max(2, Theme.v(2)))
        lg.rectangle("line", s.x - Theme.v(2), s.y - Theme.v(2), s.w + Theme.v(4), s.h + Theme.v(4), Theme.v(4))
        lg.setLineWidth(1)
        Draw.diamond(s.x + s.w - Theme.v(10), s.y + Theme.v(10), Theme.v(6), col, 1)
        Draw.text("预视", s.x + s.w * 0.5, s.y - Theme.v(13), Theme.px(10), col, "center", s.w)
      end
    end
  end

  -- total badge + side label.
  -- While the dealer's first card is face down only the public cards may be
  -- summed; the unknown remainder is shown as "?" so the hole card never leaks.
  local shownValue, shownTotal = ent.total, ent.total
  if isDealer and not ent.holeRevealed then
    local vis = {}
    for i = 2, #hand do vis[#vis + 1] = hand[i] end
    local ok, v = pcall(function() return require("src.blackjack").handTotal(vis) end)
    if ok and type(v) == "number" then
      shownValue, shownTotal = tostring(v) .. "?", v
    else
      shownValue, shownTotal = "?", 0
    end
  end
  local bx = Theme.vx(cx) + Theme.v(430) * 0.5 + Theme.v(56)
  local by = Theme.vy(cy) - Theme.v(6)
  badge(bx, by, isDealer and "庄家" or "你", shownValue,
    shownTotal, ent.busted, isDealer and (ent.blackjack and ent.holeRevealed) or false)
  local sub = {}
  if ent.blackjack then sub[#sub + 1] = "Blackjack" end
  if ent.busted then sub[#sub + 1] = "爆牌" end
  if ent.stood then sub[#sub + 1] = "停牌" end
  if ent.doubled then sub[#sub + 1] = "加倍" end
  if ent.surrendered then sub[#sub + 1] = "投降" end
  if ent.is67 then sub[#sub + 1] = "67 组合" end
  if ent.isRps then sub[#sub + 1] = "石头剪刀布" end
  if #sub > 0 then
    Draw.text(table.concat(sub, " · "), bx, by + Theme.v(30), Theme.px(10.5), Theme.colors.textDim, "center", Theme.v(120))
  end
  -- class chip
  local cls = isDealer and st.dealerClass or st.playerClass
  if cls then
    local cxc = Theme.vx(cx) - Theme.v(430) * 0.5 - Theme.v(52)
    Draw.set({ 0, 0, 0, 0.45 }); lg.circle("fill", cxc, Theme.vy(cy), Theme.v(22), 24)
    Draw.circleLine(cxc, Theme.vy(cy), Theme.v(22), Theme.colors.gold, 0.7, Theme.v(1.3))
    Draw.text(cls.letter or "?", cxc, Theme.vy(cy) - Theme.v(11), Theme.px(17), Theme.colors.goldBright, "center")
    Draw.text(cls.name or "", cxc, Theme.vy(cy) + Theme.v(24), Theme.px(10), Theme.colors.textDim, "center", Theme.v(110))
  end
end

-- ================= bar mode helpers =================
local function barRemaining(cup)
  local ok, BM = pcall(require, "src.bar_mode")
  if ok and BM and BM.remaining then return BM.remaining(cup) end
  return math.max(0, 5 - (cup.mouth or 0))
end

local function barTotalRemaining(st)
  local b = st.bar or {}
  local n = 0
  for _, c in ipairs(b.cups or {}) do n = n + barRemaining(c) end
  return n
end

local function barColor(cup)
  local c = cup and cup.color
  if type(c) == "table" then
    return { c[1] or c.r or 0.85, c[2] or c.g or 0.55, c[3] or c.b or 0.25 }
  end
  return { 0.85, 0.6, 0.3 }
end

local function barGlassKind(glass)
  if glass == "martini" or glass == "flute" or glass == "hurricane" then return "martini" end
  if glass == "wine" then return "wine" end
  return "rocks"
end

-- 调酒栏（左栏）：6 个杯位；点击杯位喝 1 口，右侧按钮使用该酒技能
local function barCups(g, st)
  local x, y = Theme.vx(14), Theme.vy(78)
  local w, h = Theme.v(190), Theme.v(506)
  Draw.panel(x, y, w, h, Theme.v(7), { bgTop = { 0.11, 0.06, 0.05, 0.94 }, bgBot = { 0.04, 0.024, 0.022, 0.94 } })
  local b = st.bar or {}
  local total = barTotalRemaining(st)
  Draw.text("调酒栏", x + Theme.v(12), y + Theme.v(12), Theme.px(12), Theme.colors.goldBright, "left")
  Draw.text(tostring(#(b.cups or {})) .. " / 6", x + w - Theme.v(12), y + Theme.v(12), Theme.px(11), Theme.colors.textDim, "right")
  Draw.text("剩余 " .. tostring(total) .. " 口", x + Theme.v(12), y + Theme.v(30), Theme.px(11),
    total <= 5 and Theme.colors.negative or Theme.colors.text, "left")
  if b.usedAbilityThisRound then
    Draw.text("本局技能已用", x + w - Theme.v(12), y + Theme.v(30), Theme.px(10), Theme.colors.orange, "right")
  end

  local canDrink = (st.state == "player")
  local rowY = y + Theme.v(52)
  for i = 1, 6 do
    local cup = (b.cups or {})[i]
    local ry, rh = rowY, Theme.v(72)
    Draw.set({ 0, 0, 0, 0.28 }); lg.rectangle("fill", x + Theme.v(8), ry, w - Theme.v(16), rh, Theme.v(5), Theme.v(5))
    if cup then
      local col = barColor(cup)
      local rem = barRemaining(cup)
      -- 固定深色底：技能小字必须在任何酒色下都读得清，颜色只做左侧身份条
      Draw.set({ 0.085, 0.050, 0.046, 0.94 })
      lg.rectangle("fill", x + Theme.v(8), ry, w - Theme.v(16), rh, Theme.v(5), Theme.v(5))
      Draw.set(col[1], col[2], col[3], rem > 0 and 0.95 or 0.38)
      lg.rectangle("fill", x + Theme.v(8), ry + Theme.v(4), Theme.v(3), rh - Theme.v(8), Theme.v(1.5), Theme.v(1.5))
      lg.setLineWidth(Theme.v(1.2))
      Draw.set(col[1], col[2], col[3], rem > 0 and 0.78 or 0.30)
      lg.rectangle("line", x + Theme.v(8), ry, w - Theme.v(16), rh, Theme.v(5), Theme.v(5))
      lg.setLineWidth(1)
      Motifs.glass(x + Theme.v(30), ry + Theme.v(32), Theme.v(34), barGlassKind(cup.glass),
        math.max(0, rem / 5), col, Theme.time)
      Draw.text(cup.name or cup.drink or "?", x + Theme.v(52), ry + Theme.v(6), Theme.px(12.5),
        rem > 0 and Theme.colors.goldBright or Theme.colors.textDim, "left", w - Theme.v(76))
      local ab = cup.ability or {}
      local f9 = require("ui.fonts").get(Theme.px(9))
      local lines = require("ui.fonts").wrap((ab.name or "技能") .. "：" .. (ab.desc or ""), f9, w - Theme.v(76))
      for li = 1, math.min(2, #lines) do
        Draw.text(lines[li], x + Theme.v(52), ry + Theme.v(21) + (li - 1) * Theme.v(10), Theme.px(9),
          { 0.86, 0.79, 0.64, 1 }, "left", w - Theme.v(76))
      end
      -- 剩余口数圆点
      local dx = x + Theme.v(54)
      for d = 1, 5 do
        local on = d <= rem
        if on then Draw.set(col[1], col[2], col[3], 0.95) else Draw.set(1, 1, 1, 0.16) end
        lg.circle("fill", dx + (d - 1) * Theme.v(11), ry + rh - Theme.v(12), Theme.v(4), 12)
      end
      local buff = cup.buffLeft or 0
      Draw.text(buff > 0 and ("技能 " .. buff .. " 局") or "未解锁", x + Theme.v(52) + Theme.v(64), ry + rh - Theme.v(17),
        Theme.px(9.5), buff > 0 and Theme.colors.cyan or { 0.80, 0.74, 0.60, 1 }, "left")
      -- 喝一口（行热区不含技能按钮）
      Hot.btn({ id = "bar.cup." .. i, x = x + Theme.v(8), y = ry, w = w - Theme.v(46), h = rh,
        enabled = canDrink and rem > 0, kind = "row",
        tip = rem > 0 and ("喝一口「" .. tostring(cup.name or "") .. "」：解锁 / 刷新该酒技能 5 局（本杯余 " .. rem .. " 口）。")
          or "这杯已经空了。",
        tipTitle = "喝一口", data = { cup = i } })
      -- 使用技能（独立热区，不与行重叠）
      local abReady = canDrink and buff > 0 and not b.usedAbilityThisRound
      W.button({ id = "bar.ab." .. i, x = x + w - Theme.v(36), y = ry + Theme.v(6), w = Theme.v(24), h = Theme.v(24),
        label = "技", size = 11, tone = abReady and "purple" or "dark",
        enabled = canDrink, data = { cup = i },
        tip = (ab.name or "技能") .. "：" .. (ab.desc or "") ..
          (buff > 0 and ("（剩 " .. buff .. " 局）") or "（需先喝一口解锁）") ..
          (b.usedAbilityThisRound and " · 本局已使用" or ""),
        tipTitle = "使用技能" })
    else
      Draw.text("空杯位", x + Theme.v(54), ry + Theme.v(28), Theme.px(11), Theme.colors.textDim, "left")
    end
    rowY = rowY + rh + Theme.v(4)
  end
end

-- 酒吧右栏：数据 + 当前 buff + 酒保台词
local function barRail(g, st)
  local x, y = Theme.vx(1052), Theme.vy(78)
  local w = Theme.v(214)
  Draw.panel(x, y, w, Theme.v(506), Theme.v(7), { bgTop = { 0.11, 0.06, 0.05, 0.94 }, bgBot = { 0.04, 0.024, 0.022, 0.94 } })
  local b = st.bar or {}
  Draw.text("酒吧数据", x + Theme.v(12), y + Theme.v(12), Theme.px(12), Theme.colors.goldBright, "left")
  local cy = y + Theme.v(36)
  local rows = {
    { "第几局", tostring(b.round or 0) .. " / " .. tostring(b.totalRounds or 100) },
    { "剩余口数", tostring(barTotalRemaining(st)) },
    { "酒杯数", tostring(b.cupCount or #(b.cups or {})) .. " / 6" },
    { "赠礼概率", string.format("%.1f%%", (b.prob or 0) * 100) },
    { "胜 / 负", tostring(b.wins or 0) .. " / " .. tostring(b.losses or 0) },
  }
  for _, r in ipairs(rows) do
    Draw.text(r[1], x + Theme.v(12), cy, Theme.px(11), Theme.colors.textDim, "left")
    Draw.text(r[2], x + w - Theme.v(12), cy, Theme.px(13), Theme.colors.goldPale, "right")
    cy = cy + Theme.v(22)
  end
  Draw.hline(x + Theme.v(10), cy + Theme.v(2), w - Theme.v(20), Theme.colors.goldDim, 0.5, 1)
  cy = cy + Theme.v(14)

  Draw.text("技能计时", x + Theme.v(12), cy, Theme.px(11.5), Theme.colors.goldBright, "left")
  cy = cy + Theme.v(20)
  local any = false
  for _, cup in ipairs(b.cups or {}) do
    if (cup.buffLeft or 0) > 0 then
      any = true
      Draw.text(cup.name or "", x + Theme.v(12), cy, Theme.px(10.5), Theme.colors.text, "left", w - Theme.v(72))
      Draw.text(cup.buffLeft .. " 局", x + w - Theme.v(12), cy, Theme.px(10.5), Theme.colors.cyan, "right")
      cy = cy + Theme.v(17)
    end
  end
  if not any then
    Draw.text("暂无激活技能：喝一口即可点亮。", x + Theme.v(12), cy, Theme.px(10), Theme.colors.textDim, "left", w - Theme.v(24))
    cy = cy + Theme.v(17)
  end

  cy = cy + Theme.v(8)
  Draw.text("宿醉", x + Theme.v(12), cy, Theme.px(11.5), Theme.colors.goldBright, "left")
  cy = cy + Theme.v(18)
  if b.hangover then
    local names = table.concat(b.hangoverNames or {}, "、")
    Draw.text("牌面模糊中（仅视觉）：" .. names, x + Theme.v(12), cy, Theme.px(10), Theme.colors.orange, "left", w - Theme.v(24))
    cy = cy + Theme.v(28)
  else
    Draw.text("清醒", x + Theme.v(12), cy, Theme.px(10.5), Theme.colors.textDim, "left")
    cy = cy + Theme.v(18)
  end

  Draw.hline(x + Theme.v(10), cy, w - Theme.v(20), Theme.colors.goldDim, 0.5, 1)
  cy = cy + Theme.v(10)
  Draw.text("酒保", x + Theme.v(12), cy, Theme.px(11.5), Theme.colors.goldBright, "left")
  cy = cy + Theme.v(18)
  local f = require("ui.fonts").get(Theme.px(10.5))
  for _, ln in ipairs(require("ui.fonts").wrap(b.lastLine or "……", f, w - Theme.v(24))) do
    Draw.text(ln, x + Theme.v(12), cy, Theme.px(10.5), Theme.colors.text, "left", w - Theme.v(24))
    cy = cy + Theme.v(15)
  end
end

-- ================= left panel =================
local function leftPanel(g, st)
  if st.mode == "bar" then return barCups(g, st) end
  local x, y = Theme.vx(14), Theme.vy(78)
  local w, h = Theme.v(190), Theme.v(506)
  Draw.panel(x, y, w, h, Theme.v(7), { bgTop = { 0.11, 0.055, 0.062, 0.94 }, bgBot = { 0.04, 0.022, 0.028, 0.94 } })
  local cy = y + Theme.v(12)
  Draw.text("本阶段进度", x + Theme.v(12), cy, Theme.px(12), Theme.colors.goldBright, "left")
  cy = cy + Theme.px(20)
  local rounds = st.roundsInStage or 0
  local maxRounds = st.stageRounds or 1
  Draw.bar(x + Theme.v(12), cy, w - Theme.v(24), Theme.v(9), maxRounds > 0 and rounds / maxRounds or 0, Theme.colors.gold, { 0, 0, 0, 0.5 })
  cy = cy + Theme.v(14)
  Draw.text(rounds .. " / " .. maxRounds .. " 局", x + Theme.v(12), cy, Theme.px(10.5), Theme.colors.textDim, "left")
  cy = cy + Theme.px(20)
  Draw.text("阶段目标", x + Theme.v(12), cy, Theme.px(12), Theme.colors.goldBright, "left")
  cy = cy + Theme.px(19)
  local target = math.max(1, st.stageTarget or 1)
  Draw.bar(x + Theme.v(12), cy, w - Theme.v(24), Theme.v(9), math.min(1, (st.chips or 0) / target), Theme.colors.green, { 0, 0, 0, 0.5 })
  cy = cy + Theme.v(13)
  Draw.text(C.money(st.chips or 0), x + Theme.v(12), cy, Theme.px(11), Theme.colors.goldBright, "left")
  Draw.text("/ " .. C.money(target), x + w - Theme.v(12), cy, Theme.px(10), Theme.colors.textDim, "right")
  Draw.hline(x + Theme.v(10), cy + Theme.px(20), w - Theme.v(20), Theme.colors.goldDim, 0.5, 1)
  cy = cy + Theme.v(28)

  local dp = st.deck and (#(st.deck.drawPile or {})) or 0
  local disc = st.deck and (#(st.deck.discardPile or {})) or 0
  Draw.text("牌靴剩余", x + Theme.v(12), cy, Theme.px(11), Theme.colors.textDim, "left")
  Draw.text(tostring(dp), x + w - Theme.v(12), cy, Theme.px(14), Theme.colors.goldBright, "right")
  cy = cy + Theme.px(18)
  Draw.text("弃牌堆", x + Theme.v(12), cy, Theme.px(11), Theme.colors.textDim, "left")
  Draw.text(tostring(disc), x + w - Theme.v(12), cy, Theme.px(14), Theme.colors.text, "right")
  cy = cy + Theme.px(18)
  Draw.text("洗牌次数", x + Theme.v(12), cy, Theme.px(11), Theme.colors.textDim, "left")
  Draw.text(tostring((st.deck and st.deck.shuffleCount) or 0), x + w - Theme.v(12), cy, Theme.px(14), Theme.colors.text, "right")
  Draw.hline(x + Theme.v(10), cy + Theme.px(20), w - Theme.v(20), Theme.colors.goldDim, 0.5, 1)
  cy = cy + Theme.v(28)

  Draw.text("连胜", x + Theme.v(12), cy, Theme.px(11), Theme.colors.textDim, "left")
  Draw.text(tostring(st.streak or 0), x + w - Theme.v(12), cy, Theme.px(14), (st.streak or 0) > 0 and Theme.colors.hot or Theme.colors.text, "right")
  cy = cy + Theme.px(22)

  local held = st.specialMarks and st.specialMarks.held
  Draw.text("特种标记", x + Theme.v(12), cy, Theme.px(11), Theme.colors.textDim, "left")
  cy = cy + Theme.px(16)
  if held then
    Draw.text((held.name or "特种标记") .. " · 剩 " .. tostring(held.usesLeft or 0),
      x + Theme.v(12), cy, Theme.px(10.5), Theme.colors.purple, "left", w - Theme.v(24))
  else
    Draw.text("无", x + Theme.v(12), cy, Theme.px(10.5), Theme.colors.text, "left", w - Theme.v(24))
  end
  cy = cy + Theme.px(22)

  -- last / current settlement
  Draw.hline(x + Theme.v(10), cy, w - Theme.v(20), Theme.colors.goldDim, 0.5, 1)
  cy = cy + Theme.v(8)
  Draw.text("结算区", x + Theme.v(12), cy, Theme.px(12), Theme.colors.goldBright, "left")
  cy = cy + Theme.px(19)
  local res = st.result
  if res then
    local oc = Theme.colors[TOUT_COLOR[res.outcome] or "textGold"]
    Draw.text(TOUT[res.outcome] or res.outcome, x + Theme.v(12), cy, Theme.px(15), oc, "left")
    cy = cy + Theme.px(22)
    Draw.text("净变化", x + Theme.v(12), cy, Theme.px(10.5), Theme.colors.textDim, "left")
    Draw.text((res.netChange or 0) >= 0 and ("+" .. C.money(res.netChange)) or C.money(res.netChange),
      x + w - Theme.v(12), cy, Theme.px(12), (res.netChange or 0) >= 0 and Theme.colors.positive or Theme.colors.negative, "right")
    cy = cy + Theme.px(18)
    Draw.text("结算筹码", x + Theme.v(12), cy, Theme.px(10.5), Theme.colors.textDim, "left")
    Draw.text(C.money(res.chips or st.chips or 0), x + w - Theme.v(12), cy, Theme.px(12), Theme.colors.goldBright, "right")
    cy = cy + Theme.px(18)
    Draw.text("倍率", x + Theme.v(12), cy, Theme.px(10.5), Theme.colors.textDim, "left")
    Draw.text("+" .. tostring(res.mult or 0) .. " / x" .. string.format("%.2f", res.xMult or 1),
      x + w - Theme.v(12), cy, Theme.px(12), Theme.colors.cyan, "right")
  else
    Draw.text("本局尚未结算", x + Theme.v(12), cy, Theme.px(11), Theme.colors.textDim, "left", w - Theme.v(24))
  end
end

-- ================= right rail =================
local function rightPanel(g, st)
  if st.mode == "bar" then return barRail(g, st) end
  local x, y = Theme.vx(1052), Theme.vy(78)
  local w = Theme.v(214)
  Draw.panel(x, y, w, Theme.v(506), Theme.v(7), { bgTop = { 0.11, 0.055, 0.062, 0.94 }, bgBot = { 0.04, 0.022, 0.028, 0.94 } })
  Draw.text("遗物栏", x + Theme.v(12), y + Theme.v(12), Theme.px(12), Theme.colors.goldBright, "left")
  Draw.text(tostring(#(st.relics or {})) .. " / " .. tostring(st.relicSlotMax or 5),
    x + w - Theme.v(12), y + Theme.v(12), Theme.px(11), Theme.colors.textDim, "right")
  C.relicBar(st, { x = x + Theme.v(12), y = y + Theme.v(34), cols = 2, gap = 7, scale = 0.94 })

  -- bust bet panel
  local by = y + Theme.v(360)
  Draw.hline(x + Theme.v(10), by, w - Theme.v(20), Theme.colors.goldDim, 0.5, 1)
  local bb = st.bustBet or {}
  Draw.text("爆注（庄家爆牌）", x + Theme.v(12), by + Theme.v(8), Theme.px(11.5), Theme.colors.goldBright, "left")
  Draw.text("本金 " .. C.money(bb.amount or 0), x + Theme.v(12), by + Theme.v(28), Theme.px(11), Theme.colors.text, "left")
  local oddsText = bb.odds and string.format("赔率 %.2fx", bb.odds) or "赔率未锁定"
  Draw.text(oddsText, x + w - Theme.v(12), by + Theme.v(28), Theme.px(11),
    bb.locked and Theme.colors.cyan or Theme.colors.textDim, "right")
  W.toggle({ id = "tbl.bustbet", x = x + Theme.v(12), y = by + Theme.v(50), w = Theme.v(46), h = Theme.v(22),
    value = bb.on and true or false, tip = "爆注：押庄家本局会爆牌。赔率在发牌后锁定；命中返还本金 + 本金×赔率，未命中损失本金。",
    tipTitle = "爆注" })
  Draw.text(bb.on and "已开启" or "已关闭", x + Theme.v(66), by + Theme.v(54), Theme.px(11),
    bb.on and Theme.colors.positive or Theme.colors.textDim, "left")
  W.button({ id = "tbl.bustbet.key", x = x + w - Theme.v(60), y = by + Theme.v(50), w = Theme.v(48), h = Theme.v(24),
    label = "B", size = 12, tone = "dark", tip = "快捷键 B：切换爆注", tipTitle = "爆注", data = {} })

  -- action availability helpers
  local ay = by + Theme.v(84)
  Draw.hline(x + Theme.v(10), ay, w - Theme.v(20), Theme.colors.goldDim, 0.5, 1)
  Draw.text("快速入口", x + Theme.v(12), ay + Theme.v(8), Theme.px(11.5), Theme.colors.goldBright, "left")
  W.button({ id = "tbl.shoe", x = x + Theme.v(12), y = ay + Theme.v(28), w = Theme.v(90), h = Theme.v(30),
    label = "情报 I", size = 12, tone = "blue", tip = "顺序带 / 成分 / 爆率 / 弃牌堆（I）", tipTitle = "情报面板", data = {} })
  W.button({ id = "tbl.deck", x = x + Theme.v(112), y = ay + Theme.v(28), w = Theme.v(90), h = Theme.v(30),
    label = "牌堆 D", size = 12, tone = "purple", tip = "查看全部手牌与特殊牌（D）", tipTitle = "牌堆总览", data = {} })
end

-- ================= result overlay =================
local function resultOverlay(g, st)
  local res = st.result
  if not res then return end
  local w, h = Theme.v(560), Theme.v(300)
  local x, y = Theme.vx(640) - w * 0.5, Theme.vy(200)
  Draw.set({ 0, 0, 0, 0.55 }); lg.rectangle("fill", x + Theme.v(4), y + Theme.v(6), w, h, Theme.v(10), Theme.v(10))
  Draw.gradientV(x, y, w, h, { 0.14, 0.055, 0.06, 0.96 }, { 0.035, 0.018, 0.024, 0.96 })
  Draw.ornateFrame(x, y, w, h, Theme.v(10), Theme.colors.gold, 0.85)
  local oc = Theme.colors[TOUT_COLOR[res.outcome] or "textGold"]
  Draw.title(TOUT[res.outcome] or res.outcome, x + w * 0.5, y + Theme.v(14), Theme.px(30), "center", w - Theme.v(40))
  local cy = y + Theme.v(60)
  Draw.text("注金 " .. C.money(res.bet or 0), x + Theme.v(24), cy, Theme.px(12), Theme.colors.text, "left")
  Draw.text("结算 " .. C.money(res.winnings or 0), x + w - Theme.v(24), cy, Theme.px(12), Theme.colors.goldBright, "right")
  cy = cy + Theme.px(24)
  Draw.hline(x + Theme.v(20), cy, w - Theme.v(40), Theme.colors.goldDim, 0.6, 1)
  cy = cy + Theme.v(8)
  for _, row in ipairs(res.breakdown or {}) do
    Draw.set(Theme.colors[KIND_COLOR[row.kind] or "text"]); lg.circle("fill", x + Theme.v(28), cy + Theme.px(7), Theme.v(2.6), 10)
    Draw.text(row.label or "", x + Theme.v(40), cy, Theme.px(12.5), Theme.colors.text, "left", w - Theme.v(160))
    local val = row.value
    local txt
    if row.kind == "mult" then txt = "+" .. tostring(val)
    elseif row.kind == "x_mult" then txt = "x" .. string.format("%.2f", val)
    else txt = (tonumber(val) or 0) >= 0 and ("+" .. C.money(val)) or C.money(val) end
    Draw.text(txt, x + w - Theme.v(24), cy, Theme.px(12.5),
      Theme.colors[KIND_COLOR[row.kind] or "text"], "right")
    cy = cy + Theme.px(21)
  end
  if res.bustBet and res.bustBet.on then
    Draw.text("爆注 " .. (res.bustBet.hit and ("命中 +" .. C.money(res.bustBet.payout or 0)) or "未命中 -" .. C.money(res.bustBet.amount or 0)),
      x + Theme.v(40), cy, Theme.px(11.5), res.bustBet.hit and Theme.colors.positive or Theme.colors.negative, "left", w - Theme.v(60))
    cy = cy + Theme.px(20)
  end
  if res.accuse and res.accuse.attempted then
    Draw.text(res.accuse.correct and ("指认成功 +" .. C.money(res.accuse.bonus or 0)) or "指认失败（本局作废，另处罚金）",
      x + Theme.v(40), cy, Theme.px(11.5), res.accuse.correct and Theme.colors.positive or Theme.colors.negative, "left", w - Theme.v(60))
    cy = cy + Theme.px(20)
  end
  if res.marks and (res.marks.discovered or 0) > 0 then
    Draw.text("墨水标记被发现 · 罚金 " .. C.money(res.marks.penalty or 0), x + Theme.v(40), cy, Theme.px(11.5), Theme.colors.negative, "left", w - Theme.v(60))
  end
  local net = res.netChange or 0
  Draw.text((net >= 0 and "净收益 +" or "净损失 ") .. C.money(net), x + w * 0.5, y + h - Theme.v(34), Theme.px(18),
    net >= 0 and Theme.colors.positive or Theme.colors.negative, "center", w - Theme.v(40))
end

-- ================= bottom bar =================
local function bottomBar(g, st)
  local x, y = Theme.vx(14), Theme.vy(596)
  local w, h = Theme.v(1252), Theme.v(114)
  Draw.panel(x, y, w, h, Theme.v(7), { bgTop = { 0.12, 0.058, 0.065, 0.95 }, bgBot = { 0.04, 0.022, 0.028, 0.95 } })
  local inBet = (st.state == "bet")
  local inPlayer = (st.state == "player")
  local inDealer = (st.state == "dealer")
  local inResult = (st.state == "result")

  if inDealer then
    Draw.text("庄家行动中…", x + w * 0.5, y + Theme.v(46), Theme.px(20), Theme.colors.goldBright, "center")
  elseif inResult then
    W.button({ id = "tbl.continue", x = x + w * 0.5 - Theme.v(120), y = y + Theme.v(30), w = Theme.v(240), h = Theme.v(52),
      label = "继续", tone = "gold", size = 19, hotkey = "Enter", pulse = true,
      tip = "推进到商店 / 下一局", tipTitle = "继续" })
  elseif st.mode == "bar" then
    -- 酒吧模式：只有要牌 / 停牌 + 调酒栏操作；加倍永远灰色，指认与投降不存在
    local by = y + Theme.v(14)
    local bh = Theme.v(50)
    W.button({ id = "tbl.hit", x = x + Theme.v(16), y = by, w = Theme.v(126), h = bh,
      label = "要牌", sub = "H / 空格", size = 17, tone = "gold", enabled = can(g, "hit"),
      tip = "再要一张牌。超过 21 点即爆牌。", tipTitle = "要牌" })
    W.button({ id = "tbl.stand", x = x + Theme.v(150), y = by, w = Theme.v(126), h = bh,
      label = "停牌", sub = "S / Enter", size = 17, tone = "blue", enabled = can(g, "stand"),
      tip = "停牌并把行动交给酒保。", tipTitle = "停牌" })
    W.button({ id = "tbl.bar.double", x = x + Theme.v(284), y = by, w = Theme.v(126), h = bh,
      label = "加倍", sub = "不可用", size = 17, tone = "grey", enabled = false,
      tip = "酒吧模式不计筹码，无法加倍。", tipTitle = "加倍" })
    W.button({ id = "tbl.bar.brief", x = x + w - Theme.v(292), y = by, w = Theme.v(126), h = bh,
      label = "简报", sub = "重看规则", size = 15, tone = "dark",
      tip = "重看酒吧玩法说明（不消耗任何资源）。", tipTitle = "酒单简报" })
    Draw.text("点击左侧杯位喝一口（每杯 5 口）· 杯位右侧「技」使用该酒技能（每局一次）",
      x + w * 0.5, by + bh + Theme.v(8), Theme.px(11.5), Theme.colors.textDim, "center", Theme.v(620))
    C.hints({ { "H", "要牌" }, { "S", "停牌" }, { "点击杯位", "喝一口" }, { "技", "使用技能" } }, y + h - Theme.v(22))
  elseif inBet then
    Draw.text("注金", x + Theme.v(18), y + Theme.v(10), Theme.px(12), Theme.colors.textDim, "left")
    Draw.text(C.money(st.bet or 0), x + Theme.v(18), y + Theme.v(26), Theme.px(22), Theme.colors.goldBright, "left")
    local minBet = st.betMin or ((st.stage or 1) >= 3 and math.floor((st.chips or 0) / 2) or 0)
    local maxBet = math.max(minBet, math.min(st.chips or 0, st.betMax or (st.chips or 0)))
    if maxBet <= 0 then maxBet = minBet end
    if not betSlider or betSlider.max ~= maxBet or betSlider.min ~= minBet then
      betSlider = { min = minBet, max = maxBet, value = C.clamp(st.bet or minBet, minBet, maxBet) }
    end
    betSlider.value = C.clamp(st.bet or betSlider.value, minBet, maxBet)
    W.slider({ id = "tbl.betslider", x = x + Theme.v(150), y = y + Theme.v(40), w = Theme.v(330), h = Theme.v(14),
      min = minBet, max = maxBet, step = 50, int = true, value = betSlider.value,
      label = "拖动调整 · 空格确认",
      marks = { minBet, maxBet },
      onChange = function(v) g:action("bet_set", v) end,
      tip = "本局注金。第 3 阶段起注金不得低于筹码的一半。", tipTitle = "注金" })
    -- presets
    local presets = { 50, 100, 200, 500, 1000 }
    local bx = x + Theme.v(496)
    for i, p in ipairs(presets) do
      W.button({ id = "tbl.preset." .. i, x = bx, y = y + Theme.v(24), w = Theme.v(62), h = Theme.v(34),
        label = C.money(p), size = 12, tone = "dark", hotkey = tostring(i),
        enabled = (p <= (st.chips or 0)) or p == 50,
        tip = "设为 " .. C.money(p) .. "（" .. i .. " 键）", tipTitle = "快捷注金",
        data = { preset = i } })
      bx = bx + Theme.v(66)
    end
    -- confirm
    W.button({ id = "tbl.confirm", x = x + Theme.v(836), y = y + Theme.v(22), w = Theme.v(160), h = Theme.v(44),
      label = "确认下注并发牌", tone = "gold", size = 14, sub = "Enter", pulse = true,
      enabled = (st.bet or 0) > 0,
      tip = "确认注金并进入发牌。若为自然 Blackjack 按 1.5 倍返还。", tipTitle = "确认下注" })
    -- bust bet toggle + skip round
    W.button({ id = "tbl.bustbet.toggle", x = x + Theme.v(1006), y = y + Theme.v(22), w = Theme.v(118), h = Theme.v(44),
      label = "爆注", sub = (st.bustBet and st.bustBet.on) and "已开启 B" or "已关闭 B", size = 13,
      tone = (st.bustBet and st.bustBet.on) and "red" or "dark",
      tip = "爆注：押庄家本局爆牌，赔率发牌后锁定。快捷键 B。", tipTitle = "爆注",
      data = {} })
    W.button({ id = "tbl.skip", x = x + Theme.v(1132), y = y + Theme.v(22), w = Theme.v(104), h = Theme.v(44),
      label = "跳过本局", sub = "R", size = 12, tone = "green", enabled = can(g, "skip_round"),
      tip = "Rider 或骑之残卷：退还全部注金并跳过本小局。", tipTitle = "跳过本局" })
    C.hints({ { "1-5", "快捷注金" }, { "Enter", "确认" }, { "B", "爆注" }, { "R", "跳过" }, { "I", "情报" }, { "D", "牌堆" } }, y + h + Theme.v(0))
  elseif inPlayer then
    local bx = x + Theme.v(16)
    local by = y + Theme.v(16)
    local bw, bh = Theme.v(126), Theme.v(50)
    local gap = Theme.v(8)
    local function act(id, label, hotkey, tone, enabled, tip)
      W.button({ id = id, x = bx, y = by, w = bw, h = bh, label = label, sub = hotkey, size = 17, tone = tone,
        enabled = enabled, tip = tip, tipTitle = label })
      bx = bx + bw + gap
    end
    act("tbl.hit", "要牌", "H / 空格", "gold", can(g, "hit"), "再要一张牌。超过 21 点即爆牌落败。")
    act("tbl.stand", "停牌", "S / Enter", "blue", can(g, "stand"), "停牌并把行动交给庄家。")
    act("tbl.double", "加倍", "B", "red", can(g, "double"), "仅在两张牌、非自然 Blackjack、非 67、筹码足够时可加倍：注金翻倍并只补一张牌。")
    act("tbl.surrender", "投降", "U", "grey", can(g, "surrender"), "后期投降遗物点亮且点数 < 18 时可投降，返还一半注金，记为和局。")
    act("tbl.accuse", "指认", "C", "purple", can(g, "accuse"), "每小局一次：若庄家本局真的出千，你直接获胜并按遗物加成奖励；误判则损失注金并处罚金。")
    act("tbl.skip2", "跳过", "R", "green", can(g, "skip_round"), "退还注金并跳过本小局。")
    -- right side controls
    W.button({ id = "tbl.bustbet.toggle2", x = x + w - Theme.v(268), y = by, w = Theme.v(122), h = bh,
      label = "爆注", sub = (st.bustBet and st.bustBet.on) and "已开启 B" or "已关闭 B", size = 13,
      tone = (st.bustBet and st.bustBet.on) and "red" or "dark",
      tip = "切换爆注。", tipTitle = "爆注" })
    W.button({ id = "tbl.shoe2", x = x + w - Theme.v(138), y = by, w = Theme.v(122), h = bh,
      label = "情报", sub = "I", size = 16, tone = "blue",
      tip = "顺序带 / 成分 / 爆率 / 弃牌堆", tipTitle = "情报面板" })
    C.hints({ { "H", "要牌" }, { "S", "停牌" }, { "B", "加倍" }, { "C", "指认" }, { "U", "投降" }, { "R", "跳过" } }, y + h - Theme.v(26))
  end

  if st.message and st.message ~= "" then
    local tone = st.messageTone or "info"
    local col = tone == "error" and Theme.colors.negative or (tone == "success" and Theme.colors.positive or Theme.colors.goldBright)
    Draw.text(st.message, x + w * 0.5, y - Theme.v(24), Theme.px(13), col, "center", w - Theme.v(40))
  end
end

-- ================= main =================
function T.draw(g, st)
  C.bg(st, { noFlourish = true })
  C.topBar(st)
  C.feltTable(Theme.vx(640), Theme.vy(330), Theme.v(392), Theme.v(238))
  -- shoe + discard pile on the felt, right side
  local shoeX, shoeY = Theme.vx(978), Theme.vy(126)
  Motifs.shoe(shoeX - Theme.v(46), shoeY, Theme.v(86), Theme.v(66),
    math.min(1, ((st.deck and #(st.deck.drawPile or {})) or 0) / math.max(1, (st.deck and (#(st.deck.drawPile or {}) + #(st.deck.discardPile or {}))) or 52)), Theme.time)
  Draw.text("牌靴", shoeX, shoeY + Theme.v(38), Theme.px(10), Theme.colors.textDim, "center")
  if st.dealerClass then
    Draw.text("庄家职阶：" .. (st.dealerClass.name or ""), Theme.vx(978), Theme.vy(206), Theme.px(10.5),
      Theme.colors.redBright, "center", Theme.v(180))
  end

  handBlock(g, st, "dealer")
  handBlock(g, st, "player")
  leftPanel(g, st)
  rightPanel(g, st)
  resultOverlay(g, st)
  bottomBar(g, st)
  combatFx(g, st)

  -- 酒吧层：简报覆盖层 + 宿醉全屏滤镜（只影响显示，不改变任何计算）
  if st.mode == "bar" then
    require("ui.screens.bar").tableOverlay(g, st)
  end

  -- 弓手预视：st.classPreview.player 是牌对象，只展示玩家自己的一侧，绝不显示庄家暗牌
  local cp = st.classPreview
  if cp and cp.player and (st.state == "bet" or st.state == "player") then
    local w, h = Theme.v(46), Theme.v(66)
    local x, y = Theme.vx(640) - w * 0.5, Theme.vy(84)
    Draw.panel(x - Theme.v(66), y - Theme.v(6), w + Theme.v(132), h + Theme.v(30), Theme.v(6),
      { bgTop = { 0.10, 0.07, 0.09, 0.9 }, bgBot = { 0.05, 0.03, 0.04, 0.9 }, edge = Theme.colors.cyan, edgeA = 0.6 })
    Cards.draw(cp.player, x, y, w, h, {})
    Draw.text("弓手预视 · 下一张归你", Theme.vx(640), y + h + Theme.v(6), Theme.px(11), Theme.colors.cyan, "center")
  end
end

-- ================= input =================
local function act(g, name, arg, why)
  if not can(g, name, arg) then
    if why then require("ui.ui").notify(why, "warn") end
    return true
  end
  g:action(name, arg)
  return true
end

function T.onClick(g, st, hs)
  local id = hs.id
  -- 牌桌上的酒吧简报覆盖层（由 bar.lua 在表末绘制，热区仍归牌桌分发）
  if id:match("^bar%.brief") then
    return require("ui.screens.bar").onBriefClick(id)
  end
  local zone, idx = id:match("^tbl%.([a-z]+)%.(%d+)$")
  if zone == "player" or zone == "dealer" then
    if st.mode == "bar" then
      require("ui.ui").notify("酒吧模式不支持墨水标记。", "warn")
      return true
    end
    if st.state == "player" or st.state == "bet" then
      g:action("mark_card", { zone = zone, index = tonumber(idx) })
    else
      require("ui.ui").notify("标记只在下注或你的行动阶段可用。", "warn")
    end
    return true
  end
  if id == "tbl.confirm" then g:action("bet_confirm"); return true end
  if id == "tbl.continue" then g:action("continue"); return true end
  if id == "tbl.hit" then return act(g, "hit") end
  if id == "tbl.stand" then return act(g, "stand") end
  if id == "tbl.double" then return act(g, "double") end
  if id == "tbl.surrender" then return act(g, "surrender", nil, "投降尚未可用（需点亮的后期投降且点数 < 18）。") end
  if id == "tbl.accuse" then return act(g, "accuse") end
  if id == "tbl.skip" or id == "tbl.skip2" then return act(g, "skip_round", nil, "跳过需要 Rider 职阶或点亮的骑之残卷。") end
  if id == "tbl.bar.double" then
    require("ui.ui").notify("酒吧模式没有筹码注金，无法加倍。", "warn")
    return true
  end
  if id == "tbl.bar.brief" then
    require("ui.screens.bar").toggleBrief()
    return true
  end
  local bc = id:match("^bar%.cup%.(%d+)$")
  if bc then
    local i = tonumber(bc)
    local cup = (st.bar and st.bar.cups or {})[i]
    if not cup then return true end
    if st.state ~= "player" then
      require("ui.ui").notify("只能在你的行动阶段喝酒。", "warn")
      return true
    end
    if barRemaining(cup) <= 0 then
      require("ui.ui").notify("这杯已经空了。", "warn")
      return true
    end
    g:action("bar_drink", i)
    return true
  end
  local ba = id:match("^bar%.ab%.(%d+)$")
  if ba then
    local i = tonumber(ba)
    local cup = (st.bar and st.bar.cups or {})[i]
    if not cup then return true end
    local b = st.bar or {}
    if st.state ~= "player" then
      require("ui.ui").notify("只能用你的行动阶段使用技能。", "warn")
      return true
    end
    if (cup.buffLeft or 0) <= 0 then
      require("ui.ui").notify("还没有解锁这杯酒的技能：先喝一口。", "warn")
      return true
    end
    if b.usedAbilityThisRound then
      require("ui.ui").notify("每局只能使用一次技能。", "warn")
      return true
    end
    g:action("bar_ability", { id = cup.drink or cup.id })
    return true
  end
  if id == "tbl.bustbet" or id == "tbl.bustbet.toggle" or id == "tbl.bustbet.toggle2" or id == "tbl.bustbet.key" then
    g:action("toggle_bust_bet"); return true
  end
  if id == "tbl.shoe" or id == "tbl.shoe2" then g:action("open_shoe"); return true end
  if id == "tbl.deck" then g:action("open_deck"); return true end
  local pre = id:match("^tbl%.preset%.(%d+)$")
  if pre then g:action("bet_preset", tonumber(pre)); return true end
  if id:match("^relic%.") then
    local i = tonumber(id:match("%.(%d+)$"))
    if i then g:action("toggle_relic", i) end
    return true
  end
  if id == "mark.special" then return true end
  return false
end

function T.onKey(g, st, key)
  local state = st.state
  if st.mode == "bar" then
    -- 简报覆盖层独占键盘
    local barMod = require("ui.screens.bar")
    if barMod.isBriefOpen() then
      if key == "escape" then barMod.toggleBrief() end
      return true
    end
    if state == "player" then
      if key == "h" or key == "space" then return act(g, "hit") end
      if key == "s" or key == "return" or key == "kpenter" then return act(g, "stand") end
      if key == "b" then require("ui.ui").notify("酒吧模式没有筹码注金，无法加倍。", "warn"); return true end
      return false
    elseif state == "result" then
      if key == "return" or key == "kpenter" or key == "space" then g:action("continue"); return true end
    end
    return false
  end
  if state == "bet" then
    local n = tonumber(key)
    if n and n >= 1 and n <= 5 then g:action("bet_preset", n); return true end
    if key == "return" or key == "kpenter" or key == "space" then g:action("bet_confirm"); return true end
    if key == "b" then g:action("toggle_bust_bet"); return true end
    if key == "r" then return act(g, "skip_round", nil, "跳过需要 Rider 职阶或点亮的骑之残卷。") end
    if key == "left" then g:action("bet_adjust", -50); return true end
    if key == "right" then g:action("bet_adjust", 50); return true end
    return false
  elseif state == "player" then
    if key == "h" or key == "space" then return act(g, "hit") end
    if key == "s" or key == "return" or key == "kpenter" then return act(g, "stand") end
    if key == "b" then return act(g, "double") end
    if key == "c" then return act(g, "accuse") end
    if key == "u" then return act(g, "surrender", nil, "投降尚未可用（需点亮的后期投降且点数 < 18）。") end
    if key == "r" then return act(g, "skip_round", nil, "跳过需要 Rider 职阶或点亮的骑之残卷。") end
    return false
  elseif state == "result" or state == "stageClear" then
    if key == "return" or key == "kpenter" or key == "space" then g:action("continue"); return true end
  end
  return false
end

return T
