-- ui/cards.lua : programmatic playing-card renderer (poker / special decks / hidden / marks / tells)
local Theme = require("ui.theme")
local Draw = require("ui.draw")
local lg = love.graphics

local Cards = {}

local SUIT_RED = { 0.78, 0.11, 0.13 }
local SUIT_BLACK = { 0.11, 0.10, 0.11 }

-- border/accent by special kind or deck type
local SPECIAL = {
  blackhole = { edge = { 0.10, 0.08, 0.13 }, accent = { 0.55, 0.34, 0.86 }, glow = true, tag = "洞" },
  cage      = { edge = { 0.50, 0.53, 0.58 }, accent = { 0.72, 0.76, 0.82 }, tag = "笼" },
  chip      = { edge = { 0.62, 0.10, 0.12 }, accent = { 0.10, 0.09, 0.10 }, tag = "筹" },
  s67       = { edge = { 0.55, 0.30, 0.85 }, accent = { 0.74, 0.55, 0.98 }, tag = "67" },
  rps       = { edge = { 0.28, 0.66, 0.90 }, accent = { 0.55, 0.82, 0.98 }, tag = "猜" },
  dice6     = { edge = { 0.86, 0.83, 0.74 }, accent = { 0.35, 0.32, 0.28 }, tag = "D6" },
  dice20    = { edge = { 0.24, 0.66, 0.58 }, accent = { 0.62, 0.92, 0.86 }, tag = "D20" },
  decimal   = { edge = { 0.22, 0.62, 0.36 }, accent = { 0.60, 0.90, 0.66 }, tag = ".5" },
  negative  = { edge = { 0.72, 0.16, 0.18 }, accent = { 0.96, 0.50, 0.50 }, tag = "-" },
  multiplier= { edge = { 0.82, 0.64, 0.24 }, accent = { 0.98, 0.86, 0.50 }, tag = "x" },
  champion  = { edge = { 0.88, 0.70, 0.28 }, accent = { 1.00, 0.92, 0.64 }, tag = "冠" },
}

function Cards.suitColor(suit)
  if suit == "H" or suit == "D" then return SUIT_RED end
  return SUIT_BLACK
end

function Cards.kindOf(card)
  if not card then return "basic" end
  if card.kind == "dice6" or card.kind == "dice20" or card.kind == "dice" then return card.kind end
  if card.kind == "rps" or card.is_rps then return "rps" end
  if card.is_blackhole then return "blackhole" end
  if card.is_cage then return "cage" end
  if card.is_chip then return "chip" end
  if card.is_67 then return "s67" end
  if card.is_champion then return "champion" end
  local dt = card.deckType or card.deck_type or card.origin
  if dt and SPECIAL[dt] then return dt end
  if card.mult_bonus then return "multiplier" end
  if card.value and card.value ~= math.floor(card.value) then return "decimal" end
  if card.value and card.value < 0 then return "negative" end
  return "basic"
end

function Cards.spec(card) return SPECIAL[Cards.kindOf(card)] end

-- value label for the card centre / corner
function Cards.rankLabel(card)
  if not card then return "?" end
  if card.kind == "dice6" or card.kind == "dice20" or card.kind == "dice" then
    if card.value then return tostring(card.value) end
    return "?"
  end
  if card.is_rps then
    local s = card.rps_symbol or card.rank or ""
    if s == "rock" or s == "R" or s == "石" then return "石" end
    if s == "scissors" or s == "S" or s == "剪" then return "剪" end
    if s == "paper" or s == "P" or s == "布" then return "布" end
    return "猜"
  end
  local r = card.rank
  if r == nil or r == "" then
    if card.value ~= nil then return tostring(card.value) end
    return "?"
  end
  return tostring(r)
end

-- Pips layout (normalised coords inside face)
local PIPS = {
  ["2"] = { {0.5,0.22,0},{0.5,0.78,1} },
  ["3"] = { {0.5,0.22,0},{0.5,0.5,0},{0.5,0.78,1} },
  ["4"] = { {0.3,0.22,0},{0.7,0.22,0},{0.3,0.78,1},{0.7,0.78,1} },
  ["5"] = { {0.3,0.22,0},{0.7,0.22,0},{0.5,0.5,0},{0.3,0.78,1},{0.7,0.78,1} },
  ["6"] = { {0.3,0.22,0},{0.7,0.22,0},{0.3,0.5,0},{0.7,0.5,0},{0.3,0.78,1},{0.7,0.78,1} },
  ["7"] = { {0.3,0.22,0},{0.7,0.22,0},{0.5,0.36,0},{0.3,0.5,0},{0.7,0.5,0},{0.3,0.78,1},{0.7,0.78,1} },
  ["8"] = { {0.3,0.22,0},{0.7,0.22,0},{0.5,0.36,0},{0.3,0.5,0},{0.7,0.5,0},{0.5,0.64,0},{0.3,0.78,1},{0.7,0.78,1} },
  ["9"] = { {0.3,0.2,0},{0.7,0.2,0},{0.3,0.4,0},{0.7,0.4,0},{0.5,0.5,0},{0.3,0.6,0},{0.7,0.6,0},{0.3,0.8,1},{0.7,0.8,1} },
  ["10"]= { {0.3,0.2,0},{0.7,0.2,0},{0.5,0.3,0},{0.3,0.4,0},{0.7,0.4,0},{0.3,0.6,1},{0.7,0.6,1},{0.5,0.7,1},{0.3,0.8,1},{0.7,0.8,1} },
}
-- flip marker: pip drawn upside down (1) on bottom half

local function drawFaceCardLetter(cx, cy, size, card, col)
  local r = Cards.rankLabel(card)
  local font = require("ui.fonts").get(size)
  lg.setFont(font)
  Draw.textOutline(r, cx, cy, size, col, { 0.98, 0.95, 0.88, 0.9 }, "center")
end

local function drawDie(cx, cy, r, value, col)
  Draw.set({ 0.97, 0.95, 0.90 }); lg.rectangle("fill", cx - r, cy - r, r * 2, r * 2, r * 0.22, r * 0.22)
  Draw.set({ 0.1, 0.1, 0.12 }); lg.rectangle("line", cx - r, cy - r, r * 2, r * 2, r * 0.22, r * 0.22)
  local layouts = {
    [1] = { {0,0} },
    [2] = { {-0.5,-0.5},{0.5,0.5} },
    [3] = { {-0.5,-0.5},{0,0},{0.5,0.5} },
    [4] = { {-0.5,-0.5},{0.5,-0.5},{-0.5,0.5},{0.5,0.5} },
    [5] = { {-0.5,-0.5},{0.5,-0.5},{0,0},{-0.5,0.5},{0.5,0.5} },
    [6] = { {-0.5,-0.6},{0.5,-0.6},{-0.5,0},{0.5,0},{0,-0.6},{-0.0,0.6} },
  }
  local lay = layouts[value]
  if lay then
    Draw.set({ 0.10, 0.10, 0.12 })
    for _, p in ipairs(lay) do lg.circle("fill", cx + p[1] * r * 0.62, cy + p[2] * r * 0.62, r * 0.16, 14) end
  else
    Draw.text(value == nil and "?" or "?", cx, cy - r * 0.55, r * 1.1, { 0.1, 0.1, 0.12 }, "center")
  end
end

local function drawRPS(cx, cy, r, sym, col)
  local s = sym
  if s == "rock" or s == "R" or s == "石" then
    Draw.set({ 0.55, 0.55, 0.60 })
    lg.polygon("fill", cx - r * 0.7, cy + r * 0.5, cx + r * 0.7, cy + r * 0.5, cx + r * 0.85, cy - r * 0.15, cx + r * 0.35, cy - r * 0.7, cx - r * 0.2, cy - r * 0.75, cx - r * 0.8, cy - r * 0.1)
    Draw.set({ 0.75, 0.75, 0.80 }); lg.circle("fill", cx - r * 0.25, cy - r * 0.1, r * 0.28, 14)
  elseif s == "scissors" or s == "S" or s == "剪" then
    Draw.set({ 0.80, 0.82, 0.86 })
    lg.setLineWidth(r * 0.16)
    lg.line(cx - r * 0.6, cy - r * 0.7, cx + r * 0.35, cy + r * 0.55)
    lg.line(cx + r * 0.6, cy - r * 0.7, cx - r * 0.35, cy + r * 0.55)
    lg.circle("line", cx - r * 0.4, cy + r * 0.62, r * 0.2, 14)
    lg.circle("line", cx + r * 0.4, cy + r * 0.62, r * 0.2, 14)
  else
    Draw.set({ 0.92, 0.90, 0.84 }); lg.rectangle("fill", cx - r * 0.6, cy - r * 0.7, r * 1.2, r * 1.4, r * 0.1)
    Draw.set({ 0.55, 0.55, 0.60 }); lg.setLineWidth(r * 0.08)
    lg.line(cx - r * 0.35, cy - r * 0.3, cx + r * 0.35, cy - r * 0.3)
    lg.line(cx - r * 0.35, cy, cx + r * 0.35, cy)
    lg.line(cx - r * 0.35, cy + r * 0.3, cx + r * 0.35, cy + r * 0.3)
  end
end

-- Card back (never reveals hole-card identity or shoe order)
function Cards.drawBack(x, y, w, h, r, alpha)
  r = r or math.max(3, w * 0.09)
  alpha = alpha or 1
  Draw.set({ 0, 0, 0, 0.45 * alpha }); lg.rectangle("fill", x + 2, y + 3, w, h, r, r)
  Draw.gradientV(x, y, w, h, { 0.42, 0.07, 0.10, alpha }, { 0.16, 0.02, 0.04, alpha })
  lg.setLineWidth(math.max(1, w * 0.018))
  Draw.set({ 0.86, 0.68, 0.30, 0.85 * alpha })
  lg.rectangle("line", x, y, w, h, r, r)
  -- gold lattice
  Draw.set({ 0.86, 0.68, 0.30, 0.30 * alpha })
  lg.setLineWidth(1)
  local step = math.max(6, w * 0.16)
  local cx, cy = x + w * 0.5, y + h * 0.5
  local rad = math.min(w, h) * 0.30
  for i = 0, 7 do
    local a = i * math.pi / 4
    lg.line(cx + math.cos(a) * rad, cy + math.sin(a) * rad, cx - math.cos(a) * rad, cy - math.sin(a) * rad)
  end
  Draw.circleLine(cx, cy, rad, { 0.86, 0.68, 0.30, 0.55 * alpha }, nil, math.max(1, w * 0.02))
  Draw.star(cx, cy, rad * 0.5, { 0.95, 0.82, 0.45, 0.8 * alpha }, 4, 0.38)
end

-- Main card draw.
-- opt = { hidden, w, h, selected, dim, alpha, mark (bool), markColor, tell={kind,real,t}, flash, hover }
function Cards.draw(card, x, y, w, h, opt)
  opt = opt or {}
  w = w or Theme.px(Theme.metrics.cardW)
  h = h or Theme.px(Theme.metrics.cardH)
  local r = math.max(3, w * 0.10)
  local alpha = opt.alpha or 1

  if opt.hidden then
    Cards.drawBack(x, y, w, h, r, alpha)
    if opt.mark then Cards.drawMark(x, y, w, h, opt.markColor) end
    if opt.tell then Cards.drawTell(opt.tell, x, y, w, h) end
    return
  end

  local kind = Cards.kindOf(card)
  local spec = SPECIAL[kind]
  local edge = spec and spec.edge or { 0.16, 0.13, 0.14 }
  local accent = spec and spec.accent or Theme.colors.goldDim

  -- soft drop shadow: two low-alpha passes so it reads as depth rather than a
  -- hard offset rectangle ghosting the card edge.
  Draw.set({ 0, 0, 0, 0.14 * alpha })
  lg.rectangle("fill", x + w * 0.075, y + h * 0.055, w, h, r, r)
  Draw.set({ 0, 0, 0, 0.20 * alpha })
  lg.rectangle("fill", x + w * 0.035, y + h * 0.028, w, h, r, r)

  -- paper
  Draw.gradientV(x, y, w, h, { 0.995, 0.980, 0.935, alpha }, { 0.925, 0.900, 0.840, alpha })
  -- single crisp border + a thin inner rule (no stacked outlines)
  Draw.set({ edge[1], edge[2], edge[3], 0.95 * alpha })
  lg.setLineWidth(math.max(1, w * 0.032))
  lg.rectangle("line", x, y, w, h, r, r)
  Draw.set({ edge[1], edge[2], edge[3], 0.28 * alpha })
  lg.setLineWidth(math.max(1, w * 0.011))
  lg.rectangle("line", x + w * 0.08, y + h * 0.06, w * 0.84, h * 0.88, r * 0.7, r * 0.7)

  local suit = card and card.suit or "S"
  local col = Cards.suitColor(suit)
  local rank = Cards.rankLabel(card)
  local cw = math.max(9, w * 0.24)
  local cornerFont = require("ui.fonts").get(cw)
  local rtw = cornerFont:getWidth(rank)
  local rth = cornerFont:getHeight()
  local suitR = math.max(3, w * 0.082)

  -- Corner index: rank over suit.  The bottom-right copy is mirrored about the
  -- card corner, so every glyph stays inside the frame.
  local function corner(ox, oy, flip)
    lg.setFont(cornerFont)
    Draw.set({ col[1], col[2], col[3], alpha })
    if not flip then
      lg.print(rank, ox, oy)
      Draw.suit(suit, ox + rtw * 0.5, oy + rth + suitR + w * 0.02, suitR, { col[1], col[2], col[3], alpha })
    else
      lg.push()
      lg.translate(ox, oy)
      lg.rotate(math.pi)
      lg.print(rank, 0, 0)
      Draw.suit(suit, rtw * 0.5, rth + suitR + w * 0.02, suitR, { col[1], col[2], col[3], alpha })
      lg.pop()
    end
  end
  corner(x + w * 0.055, y + h * 0.045, false)
  corner(x + w * 0.945, y + h * 0.955, true)

  -- centre art
  if kind == "dice6" or kind == "dice20" then
    drawDie(x + w * 0.5, y + h * 0.5, math.min(w, h) * 0.24, card and card.value, col)
  elseif kind == "rps" then
    drawRPS(x + w * 0.5, y + h * 0.5, math.min(w, h) * 0.26, card and (card.rps_symbol or card.rank), col)
  elseif kind == "decimal" or kind == "negative" or kind == "multiplier" then
    local label = card and card.value
    if card and card.mult_bonus and kind == "multiplier" then label = tostring(card.value or "") .. "\n+0.5" end
    local txt = tostring(label or rank)
    local fs = Theme.px(22) * (w / Theme.px(74))
    Draw.textOutline(txt, x + w * 0.5, y + h * 0.36, fs, { col[1], col[2], col[3], alpha }, { 0.98, 0.95, 0.88, alpha }, "center")
    Draw.suit(suit, x + w * 0.5, y + h * 0.70, math.min(w, h) * 0.15, { col[1], col[2], col[3], alpha })
  elseif rank == "J" or rank == "Q" or rank == "K" then
    Draw.set({ 0.93, 0.88, 0.80, alpha })
    lg.rectangle("fill", x + w * 0.26, y + h * 0.27, w * 0.48, h * 0.45, r * 0.6, r * 0.6)
    Draw.set({ edge[1], edge[2], edge[3], 0.5 * alpha }); lg.setLineWidth(1)
    lg.rectangle("line", x + w * 0.26, y + h * 0.27, w * 0.48, h * 0.45, r * 0.6, r * 0.6)
    drawFaceCardLetter(x + w * 0.5, y + h * 0.36, cw * 1.35, card, { col[1], col[2], col[3], alpha })
    Draw.suit(suit, x + w * 0.5, y + h * 0.62, math.min(w, h) * 0.12, { col[1], col[2], col[3], alpha })
  elseif rank == "A" then
    Draw.suit(suit, x + w * 0.5, y + h * 0.5, math.min(w, h) * 0.28, { col[1], col[2], col[3], alpha })
  else
    local pips = PIPS[rank]
    if pips then
      local pr = math.min(w, h) * 0.072
      for _, p in ipairs(pips) do
        -- pull the pip grid inwards so it never touches the corner indexes
        local px = 0.5 + (p[1] - 0.5) * 0.70
        local py = 0.5 + (p[2] - 0.5) * 0.76
        Draw.suit(suit, x + w * px, y + h * py, pr, { col[1], col[2], col[3], alpha })
      end
    else
      Draw.suit(suit, x + w * 0.5, y + h * 0.5, math.min(w, h) * 0.26, { col[1], col[2], col[3], alpha })
    end
  end

  -- special tag strip
  if spec and spec.tag then
    local th = math.max(10, h * 0.14)
    Draw.set({ edge[1], edge[2], edge[3], 0.92 * alpha })
    lg.rectangle("fill", x + w * 0.5 - w * 0.22, y + h - th - h * 0.045, w * 0.44, th, th * 0.4, th * 0.4)
    Draw.text(spec.tag, x + w * 0.5 - w * 0.22, y + h - th - h * 0.045 + th * 0.1, th * 0.72, { 0.98, 0.95, 0.88, alpha }, "center", w * 0.44)
  end

  -- chip value badge
  if card and card.is_chip and card.value then
    Draw.text("x100", x + w * 0.5, y + h * 0.80, math.max(8, w * 0.16), { 0.72, 0.10, 0.12, alpha }, "center")
  end

  if opt.mark then Cards.drawMark(x, y, w, h, opt.markColor) end
  if opt.selected then Draw.cornerBrackets(x - 2, y - 2, w + 4, h + 4, Theme.px(9), Theme.colors.goldBright, 1, Theme.px(2)) end
  if opt.tell then Cards.drawTell(opt.tell, x, y, w, h) end
  if opt.dim then
    Draw.set({ 0, 0, 0, 0.45 * (opt.dimA or 1) })
    lg.rectangle("fill", x, y, w, h, r, r)
  end
  if opt.flash and opt.flash > 0 then
    Draw.set({ 1, 1, 1, opt.flash })
    lg.rectangle("fill", x, y, w, h, r, r)
  end
end

function Cards.drawMark(x, y, w, h, color)
  color = color or { 0.32, 0.30, 0.66 }
  Draw.set({ color[1], color[2], color[3], 0.85 })
  lg.setLineWidth(math.max(2, w * 0.05))
  lg.rectangle("line", x + 1, y + 1, w - 2, h - 2, math.max(3, w * 0.09), math.max(3, w * 0.09))
  -- ink dot in corner
  Draw.set({ color[1], color[2], color[3], 0.95 })
  lg.circle("fill", x + w - w * 0.16, y + h * 0.16, math.max(2.5, w * 0.07), 12)
end

-- Cheat tell overlay. tell = { kind = "A"|"B"|"C"|"D"|"E"|"dA".."dE", real = bool, t = number }
-- 契约：tell = { kind="A".."E"/"dA".."dE", real=bool, t, slot, oldRank?, link?, card? }
-- real=false 一律来自 d 前缀。E / dE 由核心拆成两个事件：
--   slot="hole"（无 link）  -> 只画蓝框，不画菱形
--   slot="player", link=true -> 只画菱形，不画框
-- 绝不能在同一个位置上同时画框与菱形。
function Cards.drawTell(tell, x, y, w, h)
  if not tell or not tell.kind then return end
  local kind = tell.kind
  local t = tell.t or 0
  local pulse = 0.5 + 0.5 * math.sin(t * 7)
  local WHITE = { 0.97, 0.97, 0.98 }
  local GOLD = { 0.95, 0.80, 0.34 }
  local TEAL = { 0.24, 0.78, 0.66 }
  local PURPLE = { 0.66, 0.42, 0.95 }
  local BLUE = { 0.36, 0.60, 0.98 }
  local function boxEdge(col, a, lw)
    Draw.set({ col[1], col[2], col[3], a })
    lg.setLineWidth(lw or math.max(2, w * 0.055))
    lg.rectangle("line", x + 2, y + 2, w - 4, h - 4, math.max(3, w * 0.09), math.max(3, w * 0.09))
  end
  -- ---- E / dE：两端分工，link 决定画菱形，否则画框 ----
  if kind == "E" or kind == "dE" then
    if tell.link then
      local r1 = math.min(w, h) * (kind == "E" and 0.15 or 0.13)
      local a = kind == "E" and (0.55 + 0.40 * pulse) or 0.62
      Draw.diamond(x + w * 0.5, y + h * 0.5, r1, { BLUE[1], BLUE[2], BLUE[3], a })
      if kind == "E" then
        -- 双线：外大内小两个菱形；dE 只画单线
        Draw.diamond(x + w * 0.5, y + h * 0.5, r1 * 0.56, { 0.62, 0.80, 1.0, a })
      end
    else
      local lw = kind == "E" and math.max(2, w * 0.05) or math.max(1.5, w * 0.035)
      boxEdge(BLUE, kind == "E" and (0.45 + 0.35 * pulse) or 0.35, lw)
    end
    return
  end
  -- ---- A / dA：白框；A 的持续抖动由 C.drawHand 施加位移，dA 明牌位固定不抖 ----
  if kind == "A" or kind == "dA" then
    if kind == "A" then boxEdge(WHITE, 0.55 + 0.35 * pulse, math.max(2, w * 0.05))
    else boxEdge(WHITE, 0.42, math.max(1, w * 0.03)) end
    return
  end
  -- ---- B / dB：金色单次衰减脉冲 vs 细金框 ----
  if kind == "B" or kind == "dB" then
    if kind == "B" then
      local a = 0.30 + 0.65 * (1 - math.min(1, t / 0.9))
      boxEdge(GOLD, a, math.max(2, w * 0.055))
      Draw.set({ GOLD[1], GOLD[2], GOLD[3], a * 0.35 }); lg.setLineWidth(math.max(4, w * 0.14))
      lg.rectangle("line", x + 1, y + 1, w - 2, h - 2, math.max(3, w * 0.09), math.max(3, w * 0.09))
    else
      boxEdge({ 0.88, 0.74, 0.34 }, 0.30, math.max(1, w * 0.025))
    end
    return
  end
  -- ---- C / dC：teal 框 + 被换掉那张牌的残影（含旧点数文字） vs 单次闪光无残影 ----
  if kind == "C" or kind == "dC" then
    if kind == "C" then
      boxEdge(TEAL, 0.45 + 0.35 * pulse, math.max(2, w * 0.05))
      local gx, gy = x - w * 0.30, y + h * 0.06
      Draw.set({ TEAL[1], TEAL[2], TEAL[3], 0.14 })
      lg.rectangle("fill", gx, gy, w, h, math.max(3, w * 0.09), math.max(3, w * 0.09))
      Draw.set({ TEAL[1], TEAL[2], TEAL[3], 0.30 }); lg.setLineWidth(1)
      lg.rectangle("line", gx, gy, w, h, math.max(3, w * 0.09), math.max(3, w * 0.09))
      local old = tell.oldRank
      if old and tostring(old) ~= "" then
        Draw.text(tostring(old), gx + w * 0.5, gy + h * 0.36, Theme.px(13),
          { TEAL[1], TEAL[2], TEAL[3], 0.78 }, "center")
      end
    else
      local a = math.max(0, 0.7 - t * 1.6)
      boxEdge(TEAL, a, math.max(2, w * 0.05))
    end
    return
  end
  -- ---- D / dD：紫色双线脉冲 vs 紫色单线 ----
  if kind == "D" or kind == "dD" then
    if kind == "D" then
      local a = 0.45 + 0.5 * pulse
      Draw.set({ PURPLE[1], PURPLE[2], PURPLE[3], a }); lg.setLineWidth(math.max(1.5, w * 0.035))
      lg.rectangle("line", x + 2, y + 2, w - 4, h - 4, math.max(3, w * 0.09), math.max(3, w * 0.09))
      lg.rectangle("line", x + w * 0.10, y + h * 0.09, w * 0.80, h * 0.82, math.max(2, w * 0.06), math.max(2, w * 0.06))
    else
      boxEdge({ PURPLE[1], PURPLE[2], PURPLE[3] }, 0.38, math.max(1.5, w * 0.035))
    end
    return
  end
end

return Cards
