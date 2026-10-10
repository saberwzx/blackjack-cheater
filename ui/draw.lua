-- ui/draw.lua : low-level drawing primitives (rounded rects, gradients, glow, frames, text, suits)
local Draw = {}
local Theme = require("ui.theme")
local Fonts = require("ui.fonts")
local lg = love.graphics

local function unpackColor(c, a)
  if type(c) ~= "table" then return c or 1, c or 1, c or 1, a or 1 end
  if a then return c[1], c[2], c[3], (c[4] or 1) * a end
  return c[1], c[2], c[3], c[4] or 1
end

function Draw.set(c, a) lg.setColor(unpackColor(c, a)) end

function Draw.rect(x, y, w, h, r)
  if r and r > 0 then lg.rectangle("fill", x, y, w, h, r, r)
  else lg.rectangle("fill", x, y, w, h) end
end

function Draw.rectLine(x, y, w, h, r, lw)
  lg.setLineWidth(lw or 1)
  if r and r > 0 then lg.rectangle("line", x, y, w, h, r, r)
  else lg.rectangle("line", x, y, w, h) end
end

function Draw.circleFill(cx, cy, r, c, a)
  Draw.set(c, a)
  lg.circle("fill", cx, cy, r, math.max(12, math.floor(r * 0.9)))
end

function Draw.circleLine(cx, cy, r, c, a, lw)
  Draw.set(c, a); lg.setLineWidth(lw or 1)
  lg.circle("line", cx, cy, r, math.max(12, math.floor(r * 0.9)))
end

-- ===== gradient meshes (cached by color) =====
local gradCache = {}
local function ckey(c)
  return string.format("%.3f_%.3f_%.3f_%.3f", c[1] or 1, c[2] or 1, c[3] or 1, c[4] or 1)
end

local function gradientMesh(c1, c2, vertical)
  local k = ckey(c1) .. "|" .. ckey(c2) .. (vertical and "v" or "h")
  local m = gradCache[k]
  if m then return m end
  local a1, a2 = c1[4] or 1, c2[4] or 1
  local verts
  if vertical then
    verts = {
      { 0, 0, 0, 0, c1[1], c1[2], c1[3], a1 },
      { 1, 0, 1, 0, c1[1], c1[2], c1[3], a1 },
      { 1, 1, 1, 1, c2[1], c2[2], c2[3], a2 },
      { 0, 1, 0, 1, c2[1], c2[2], c2[3], a2 },
    }
  else
    verts = {
      { 0, 0, 0, 0, c1[1], c1[2], c1[3], a1 },
      { 1, 0, 1, 0, c2[1], c2[2], c2[3], a2 },
      { 1, 1, 1, 1, c2[1], c2[2], c2[3], a2 },
      { 0, 1, 0, 1, c1[1], c1[2], c1[3], a1 },
    }
  end
  m = lg.newMesh(verts, "fan", "static")
  gradCache[k] = m
  return m
end

function Draw.gradientV(x, y, w, h, c1, c2)
  lg.setColor(1, 1, 1, 1)
  lg.draw(gradientMesh(c1, c2, true), x, y, 0, w, h)
end

function Draw.gradientH(x, y, w, h, c1, c2)
  lg.setColor(1, 1, 1, 1)
  lg.draw(gradientMesh(c1, c2, false), x, y, 0, w, h)
end

-- radial glow: cached triangle-fan mesh, drawn as an ellipse
local glowCache = {}
function Draw.glow(cx, cy, rx, color, intensity, ry)
  local k = ckey(color)
  local m = glowCache[k]
  if not m then
    local seg = 56
    local verts = { { 0, 0, 0, 0, color[1], color[2], color[3], color[4] or 1 } }
    for i = 0, seg do
      local a = i / seg * math.pi * 2
      verts[#verts + 1] = { math.cos(a), math.sin(a), 0, 0, color[1], color[2], color[3], 0 }
    end
    m = lg.newMesh(verts, "fan", "static")
    glowCache[k] = m
  end
  lg.setColor(1, 1, 1, intensity or 1)
  lg.draw(m, cx, cy, 0, rx, ry or rx)
end

function Draw.noopGlow(k) glowCache[k] = nil; gradCache[k] = nil end

-- ===== panels =====
function Draw.panel(x, y, w, h, r, opt)
  opt = opt or {}
  r = r or Theme.px(6)
  -- drop shadow
  Draw.set({ 0, 0, 0, opt.shadowA or 0.5 })
  lg.rectangle("fill", x + Theme.px(3), y + Theme.px(4), w, h, r, r)
  -- body
  Draw.gradientV(x, y, w, h, opt.bgTop or Theme.colors.panelAlt, opt.bgBot or Theme.colors.panelDeep)
  -- inner sheen
  Draw.gradientV(x, y, w, math.min(h, Theme.px(50)), { 1, 1, 1, 0.055 }, { 1, 1, 1, 0 })
  -- edge
  Draw.frame(x, y, w, h, r, opt.edge or Theme.colors.edge, opt.edgeA or 0.85, opt.lw or 1.4)
  return x, y, w, h
end

function Draw.frame(x, y, w, h, r, c, a, lw)
  r = r or 0
  lg.setLineWidth(lw or 1)
  Draw.set(c, a or 1)
  if r > 0 then lg.rectangle("line", x, y, w, h, r, r)
  else lg.rectangle("line", x, y, w, h) end
end

function Draw.ornateFrame(x, y, w, h, r, c, a)
  r = r or Theme.px(8)
  Draw.frame(x, y, w, h, r, c or Theme.colors.goldDim, a or 0.9, 1.5)
  Draw.frame(x + 2, y + 2, w - 4, h - 4, math.max(0, r - 2), Theme.colors.goldBright, 0.22, 1)
  -- corner ticks
  local L = Theme.px(14)
  Draw.set(c or Theme.colors.gold, (a or 0.9) * 0.85)
  lg.setLineWidth(2)
  local function corner(cx, cy, dx, dy)
    lg.line(cx, cy, cx + L * dx, cy)
    lg.line(cx, cy, cx, cy + L * dy)
  end
  corner(x + Theme.px(6), y + Theme.px(6), 1, 1)
  corner(x + w - Theme.px(6), y + Theme.px(6), -1, 1)
  corner(x + Theme.px(6), y + h - Theme.px(6), 1, -1)
  corner(x + w - Theme.px(6), y + h - Theme.px(6), -1, -1)
end

function Draw.hline(x, y, w, c, a, lw)
  Draw.set(c or Theme.colors.goldDim, a or 0.6); lg.setLineWidth(lw or 1)
  lg.line(x, y, x + w, y)
end

function Draw.vline(x, y, h, c, a, lw)
  Draw.set(c or Theme.colors.goldDim, a or 0.6); lg.setLineWidth(lw or 1)
  lg.line(x, y, x, y + h)
end

function Draw.divider(x, y, w, c)
  Draw.gradientH(x, y, w, 1, { (c or Theme.colors.goldDim)[1], (c or Theme.colors.goldDim)[2], (c or Theme.colors.goldDim)[3], 0 }, c or Theme.colors.goldDim)
  Draw.gradientH(x + w * 0.5, y, w * 0.5, 1, c or Theme.colors.goldDim, { (c or Theme.colors.goldDim)[1], (c or Theme.colors.goldDim)[2], (c or Theme.colors.goldDim)[3], 0 })
end

-- ===== text =====
-- Draw.text(str, x, y, size, color, align, width) -> returns height
-- align rules: without a width, x is the anchor (left/centre/right point).
-- With a width, x is the CENTRE when align == "center" and the RIGHT edge when
-- align == "right"; printf then wraps inside that box.
function Draw.text(str, x, y, size, color, align, width)
  local font = Fonts.get(size or Theme.px(14))
  lg.setFont(font)
  Draw.set(color or Theme.colors.text)
  if width then
    local lx = x
    if align == "center" then lx = x - width * 0.5
    elseif align == "right" then lx = x - width end
    lg.printf(str, lx, y, width, align or "left")
  elseif align == "center" or align == "right" then
    local tw = font:getWidth(str)
    lg.print(str, x - (align == "center" and tw * 0.5 or tw), y)
  else
    lg.print(str, x, y)
  end
  return font:getHeight()
end

function Draw.textShadow(str, x, y, size, color, align, width, off)
  off = off or Theme.px(1.5)
  Draw.text(str, x + off, y + off, size, { 0, 0, 0, 0.7 }, align, width)
  return Draw.text(str, x, y, size, color, align, width)
end

function Draw.textOutline(str, x, y, size, color, oc, align, width, th)
  th = th or Theme.px(1.2)
  local font = Fonts.get(size or Theme.px(14))
  lg.setFont(font)
  Draw.set(oc or { 0, 0, 0, 0.7 })
  local tw = font:getWidth(str)
  local lx = x
  if align == "center" then lx = x - (width and width * 0.5 or tw * 0.5)
  elseif align == "right" then lx = x - (width or tw) end
  -- A thick 8-way outline swallows thin CJK strokes, so it is reserved for
  -- display-size text; body sizes get the 4 orthogonal offsets only.
  local offs = { { -1, 0 }, { 1, 0 }, { 0, -1 }, { 0, 1 } }
  if th >= Theme.px(1.6) then
    offs = { { -1, 0 }, { 1, 0 }, { 0, -1 }, { 0, 1 }, { -1, -1 }, { 1, -1 }, { -1, 1 }, { 1, 1 } }
  end
  for _, off in ipairs(offs) do
    if width then lg.printf(str, lx + off[1] * th, y + off[2] * th, width, align or "left")
    else lg.print(str, lx + off[1] * th, y + off[2] * th) end
  end
  return Draw.text(str, x, y, size, color, align, width)
end

-- Crisp body / button label: one soft drop shadow under a light fill.
-- Readability comes from a single dark copy, never from an outline.
function Draw.label(str, x, y, size, color, align, width)
  local s = size or Theme.px(14)
  local sh = math.max(1, Theme.px(1))
  Draw.text(str, x + sh, y + sh * 1.5, s, { 0, 0, 0, 0.6 }, align, width)
  return Draw.text(str, x, y, s, color or Theme.colors.text, align, width)
end

-- gradient gold title text
function Draw.title(str, x, y, size, align, width)
  local color = Theme.colors.goldBright
  return Draw.textOutline(str, x, y, size, color, { 0.12, 0.05, 0.02, 0.95 }, align, width, math.max(1.4, Theme.px(2)))
end

function Draw.wrapped(str, x, y, size, color, width, lineGap)
  local font = Fonts.get(size or Theme.px(14))
  lg.setFont(font)
  Draw.set(color or Theme.colors.text)
  local lines = Fonts.wrap(str, font, width)
  local lh = font:getHeight() * (lineGap or 1.25)
  for i, l in ipairs(lines) do lg.print(l, x, y + (i - 1) * lh) end
  return #lines * lh
end

function Draw.wrappedHeight(str, size, width, lineGap)
  local font = Fonts.get(size or Theme.px(14))
  return #Fonts.wrap(str, font, width) * font:getHeight() * (lineGap or 1.25)
end

function Draw.wrappedCenter(str, cx, y, size, color, width, lineGap)
  local font = Fonts.get(size or Theme.px(14))
  lg.setFont(font)
  Draw.set(color or Theme.colors.text)
  local lines = Fonts.wrap(str, font, width)
  local lh = font:getHeight() * (lineGap or 1.25)
  for i, l in ipairs(lines) do
    lg.printf(l, cx - width * 0.5, y + (i - 1) * lh, width, "center")
  end
  return #lines * lh
end

-- ===== shapes / icons =====
function Draw.poly(points, c, a)
  Draw.set(c, a); lg.polygon("fill", points)
end

function Draw.star(cx, cy, r, c, points, innerFrac, a)
  points = points or 5
  innerFrac = innerFrac or 0.45
  local verts = {}
  for i = 0, points * 2 - 1 do
    local ang = -math.pi / 2 + i * math.pi / points
    local rr = (i % 2 == 0) and r or r * innerFrac
    verts[#verts + 1] = cx + math.cos(ang) * rr
    verts[#verts + 1] = cy + math.sin(ang) * rr
  end
  Draw.set(c, a); lg.polygon("fill", verts)
end

function Draw.diamond(cx, cy, r, c, a, ratio)
  ratio = ratio or 0.72
  Draw.set(c, a)
  lg.polygon("fill", cx, cy - r, cx + r * ratio, cy, cx, cy + r, cx - r * ratio, cy)
end

function Draw.heart(cx, cy, r, c, a)
  Draw.set(c, a)
  lg.circle("fill", cx - r * 0.42, cy - r * 0.24, r * 0.52, 24)
  lg.circle("fill", cx + r * 0.42, cy - r * 0.24, r * 0.52, 24)
  lg.polygon("fill", cx - r * 0.92, cy - r * 0.08, cx + r * 0.92, cy - r * 0.08, cx, cy + r * 0.86)
end

function Draw.spade(cx, cy, r, c, a)
  Draw.set(c, a)
  lg.circle("fill", cx - r * 0.42, cy + r * 0.22, r * 0.5, 24)
  lg.circle("fill", cx + r * 0.42, cy + r * 0.22, r * 0.5, 24)
  lg.polygon("fill", cx, cy - r * 0.92, cx + r * 0.9, cy + r * 0.3, cx - r * 0.9, cy + r * 0.3)
  lg.polygon("fill", cx - r * 0.34, cy + r * 0.32, cx + r * 0.34, cy + r * 0.32, cx + r * 0.1, cy + r * 0.9, cx - r * 0.1, cy + r * 0.9)
end

function Draw.club(cx, cy, r, c, a)
  Draw.set(c, a)
  lg.circle("fill", cx, cy - r * 0.42, r * 0.45, 24)
  lg.circle("fill", cx - r * 0.5, cy + r * 0.28, r * 0.45, 24)
  lg.circle("fill", cx + r * 0.5, cy + r * 0.28, r * 0.45, 24)
  lg.polygon("fill", cx - r * 0.28, cy + r * 0.3, cx + r * 0.28, cy + r * 0.3, cx + r * 0.1, cy + r * 0.9, cx - r * 0.1, cy + r * 0.9)
end

-- Suit drawing keyed by suit string. suit may be "S","H","D","C" or unicode-ish names.
function Draw.suit(suit, cx, cy, r, c, a)
  if suit == "H" or suit == "heart" then Draw.heart(cx, cy, r, c, a)
  elseif suit == "D" or suit == "diamond" then Draw.diamond(cx, cy, r, c, a)
  elseif suit == "C" or suit == "club" then Draw.club(cx, cy, r, c, a)
  else Draw.spade(cx, cy, r, c, a) end
end

-- poker chip: ringed disc with notches
function Draw.chip(cx, cy, r, base, accent)
  Draw.set({ 0, 0, 0, 0.4 }); lg.circle("fill", cx + r * 0.12, cy + r * 0.16, r, 32)
  Draw.set(base); lg.circle("fill", cx, cy, r, 32)
  Draw.set(accent or Theme.colors.ivory)
  for i = 0, 5 do
    local ang = i * math.pi / 3
    local nx, ny = math.cos(ang), math.sin(ang)
    lg.push()
    lg.translate(cx, cy); lg.rotate(ang)
    Draw.set(accent or Theme.colors.ivory)
    lg.rectangle("fill", r * 0.62, -r * 0.16, r * 0.36, r * 0.32, r * 0.1)
    lg.pop()
  end
  Draw.circleLine(cx, cy, r * 0.66, { 0, 0, 0, 0.22 }, nil, r * 0.08)
  Draw.circleLine(cx, cy, r, Theme.colors.white, 0.18, r * 0.06)
end

-- progress bar
function Draw.bar(x, y, w, h, pct, fill, bg, r)
  r = r or h * 0.5
  Draw.set(bg or { 0, 0, 0, 0.55 }); lg.rectangle("fill", x, y, w, h, r, r)
  pct = math.max(0, math.min(1, pct or 0))
  if pct > 0 then
    Draw.set(fill or Theme.colors.gold)
    lg.rectangle("fill", x, y, math.max(h, w * pct), h, r, r)
  end
  Draw.set({ 1, 1, 1, 0.10 }); lg.rectangle("line", x, y, w, h, r, r)
end

-- dashed line
function Draw.dashedLine(x1, y1, x2, y2, dash, gap, c, a)
  dash = dash or 6; gap = gap or 5
  local dx, dy = x2 - x1, y2 - y1
  local len = math.sqrt(dx * dx + dy * dy)
  if len <= 0 then return end
  dx, dy = dx / len, dy / len
  Draw.set(c or Theme.colors.gold, a or 0.6)
  local d = 0
  while d < len do
    local e = math.min(d + dash, len)
    lg.line(x1 + dx * d, y1 + dy * d, x1 + dx * e, y1 + dy * e)
    d = e + gap
  end
end

-- corner brackets (for selection / focus)
function Draw.cornerBrackets(x, y, w, h, size, c, a, lw)
  size = size or Theme.px(12)
  Draw.set(c or Theme.colors.goldBright, a or 0.9)
  lg.setLineWidth(lw or Theme.px(2))
  local function corner(cx, cy, dx, dy)
    lg.line(cx, cy, cx + size * dx, cy)
    lg.line(cx, cy, cx, cy + size * dy)
  end
  corner(x, y, 1, 1); corner(x + w, y, -1, 1)
  corner(x, y + h, 1, -1); corner(x + w, y + h, -1, -1)
end

Draw.unpackColor = unpackColor
return Draw
