-- ui/motifs.lua : programmatic casino motifs - roulette wheel, glassware, chips, shoe, relic icons, decor
local Theme = require("ui.theme")
local Draw = require("ui.draw")
local lg = love.graphics

local Motifs = {}
local TAU = math.pi * 2

-- ===== roulette wheel (20 slots: 0 black, then alternating so 10 red / 10 black) =====
local SLOT_COUNT = 20
function Motifs.slotColor(i)
  if i == 0 then return Theme.colors.ink end
  if i % 2 == 1 then return { 0.62, 0.09, 0.10 } else return { 0.10, 0.09, 0.10 } end
end
function Motifs.slotNumber(i) return tostring(i) end

function Motifs.roulette(cx, cy, r, t, opt)
  opt = opt or {}
  local spin = opt.spin or 0.18

  -- outer halo
  Draw.glow(cx, cy, r * 1.55, { 0.85, 0.62, 0.24, 0.22 }, 0.9)

  -- wooden rim
  Draw.set({ 0.20, 0.10, 0.06 }); lg.circle("fill", cx, cy, r * 1.13, 72)
  Draw.set({ 0.32, 0.17, 0.09 }); lg.circle("fill", cx, cy, r * 1.09, 72)
  Draw.set({ 0.14, 0.07, 0.04 }); lg.circle("fill", cx, cy, r * 1.02, 72)

  -- gold rim ring
  Draw.circleLine(cx, cy, r * 1.055, Theme.colors.goldDim, 1, math.max(2, r * 0.02))
  Draw.circleLine(cx, cy, r * 1.0, Theme.colors.gold, 0.95, math.max(2, r * 0.018))
  Draw.circleLine(cx, cy, r * 0.955, Theme.colors.goldBright, 0.35, math.max(1, r * 0.008))

  -- rim studs
  for i = 0, 19 do
    local a = i * TAU / 20 + t * 0.05
    local sx, sy = cx + math.cos(a) * r * 1.03, cy + math.sin(a) * r * 1.03
    Draw.set({ 0.98, 0.86, 0.52, 0.9 }); lg.circle("fill", sx, sy, math.max(1.2, r * 0.014), 10)
  end

  -- rotating pocket disc
  local rot = t * spin
  local step = TAU / SLOT_COUNT
  for i = 0, SLOT_COUNT - 1 do
    local a1 = rot + i * step - math.pi / 2 - step * 0.5
    local a2 = a1 + step
    local col = Motifs.slotColor(i)
    Draw.set(col)
    lg.arc("fill", "pie", cx, cy, r * 0.945, a1, a2, 14)
    -- separator
    Draw.set({ 0.80, 0.66, 0.32, 0.35 }); lg.setLineWidth(math.max(1, r * 0.006))
    lg.line(cx + math.cos(a1) * r * 0.30, cy + math.sin(a1) * r * 0.30, cx + math.cos(a1) * r * 0.945, cy + math.sin(a1) * r * 0.945)
  end

  -- numbers
  local numFont = require("ui.fonts").get(math.max(8, math.floor(r * 0.11)))
  lg.setFont(numFont)
  for i = 0, SLOT_COUNT - 1 do
    local a = rot + i * step - math.pi / 2
    local nx, ny = cx + math.cos(a) * r * 0.79, cy + math.sin(a) * r * 0.79
    lg.push(); lg.translate(nx, ny); lg.rotate(a + math.pi / 2)
    Draw.set({ 0.97, 0.93, 0.82, 0.95 })
    local s = Motifs.slotNumber(i)
    lg.print(s, -numFont:getWidth(s) * 0.5, -numFont:getHeight() * 0.5)
    lg.pop()
  end

  -- inner cone
  Draw.set({ 0.24, 0.13, 0.07 }); lg.circle("fill", cx, cy, r * 0.30, 40)
  Draw.set({ 0.42, 0.24, 0.11 }); lg.circle("fill", cx, cy, r * 0.30, 40)
  Draw.gradientV(cx - r * 0.30, cy - r * 0.30, r * 0.60, r * 0.60, { 1, 0.9, 0.6, 0.18 }, { 0, 0, 0, 0.15 })
  Draw.set({ 0.30, 0.17, 0.08 }); lg.circle("fill", cx, cy, r * 0.22, 36)
  Draw.set({ 0.98, 0.84, 0.46 }); lg.circle("fill", cx, cy, r * 0.06, 20)
  Draw.set({ 0.55, 0.36, 0.14 }); lg.circle("fill", cx, cy, r * 0.045, 18)

  -- ball (counter-rotating)
  local ba = -t * (spin * 2.4) + 1.1
  local br = r * 0.855
  local bx, by = cx + math.cos(ba) * br, cy + math.sin(ba) * br
  Draw.set({ 0, 0, 0, 0.4 }); lg.circle("fill", bx + 1.5, by + 2, r * 0.035, 14)
  Draw.set({ 0.97, 0.96, 0.94 }); lg.circle("fill", bx, by, r * 0.035, 14)
  Draw.set({ 1, 1, 1, 0.9 }); lg.circle("fill", bx - r * 0.011, by - r * 0.014, r * 0.013, 10)
end

-- ===== glassware / cocktails =====
-- kind: "martini" | "oldfashioned" | "highball" | "wine" | "mug"
function Motifs.glass(cx, cy, h, kind, fillFrac, liquidColor, t, opt)
  opt = opt or {}
  kind = kind or "martini"
  fillFrac = math.max(0, math.min(1, fillFrac or 0.7))
  liquidColor = liquidColor or { 0.85, 0.45, 0.20 }
  local glass = { 0.90, 0.94, 0.97 }
  local glassDim = { 0.62, 0.68, 0.74 }

  local function body()
    if kind == "martini" then
      local w2 = h * 0.55
      Draw.set({ 0.94, 0.97, 1.0, 0.14 })
      lg.polygon("fill", cx - w2, cy - h * 0.5, cx + w2, cy - h * 0.5, cx, cy + h * 0.04)
      if fillFrac > 0 then
        local ff = fillFrac
        local topY = cy - h * 0.5 + (1 - ff) * h * 0.5
        local fw = w2 * (1 - (1 - ff) * 0.5)
        Draw.set(liquidColor)
        lg.polygon("fill", cx - fw, topY, cx + fw, topY, cx, cy + h * 0.04 - h * 0.03)
        Draw.set({ 1, 1, 1, 0.22 })
        lg.polygon("fill", cx - fw, topY, cx - fw * 0.35, topY, cx - fw * 0.2, cy + h * 0.02, cx, cy + h * 0.02)
        Draw.set({ 1, 0.95, 0.8, 0.75 }); lg.setLineWidth(math.max(1, h * 0.012))
        lg.line(cx - fw, topY, cx + fw, topY)
      end
      Draw.set(glass); lg.setLineWidth(math.max(1, h * 0.018))
      lg.line(cx - w2, cy - h * 0.5, cx, cy + h * 0.04)
      lg.line(cx + w2, cy - h * 0.5, cx, cy + h * 0.04)
      lg.line(cx - w2, cy - h * 0.5, cx + w2, cy - h * 0.5)
      lg.setLineWidth(math.max(1, h * 0.028))
      lg.line(cx, cy + h * 0.04, cx, cy + h * 0.46)
      Draw.set(glassDim); lg.setLineWidth(math.max(1, h * 0.02))
      lg.line(cx - h * 0.20, cy + h * 0.46, cx + h * 0.20, cy + h * 0.46)
    elseif kind == "wine" then
      local r = h * 0.20
      Draw.set({ 0.94, 0.97, 1.0, 0.14 }); lg.circle("fill", cx, cy - h * 0.22, r, 26)
      if fillFrac > 0 then
        Draw.set(liquidColor); lg.circle("fill", cx, cy - h * 0.22, r * 0.92, 26)
        Draw.set({ 0, 0, 0, 0.25 }); lg.circle("fill", cx, cy - h * 0.22 + r * 0.25, r * 0.8, 24)
      end
      Draw.circleLine(cx, cy - h * 0.22, r, glass, 0.85, math.max(1, h * 0.016))
      Draw.set(glass); lg.setLineWidth(math.max(1, h * 0.022))
      lg.line(cx, cy - h * 0.02, cx, cy + h * 0.34)
      Draw.set(glassDim); lg.setLineWidth(math.max(1, h * 0.018))
      lg.line(cx - h * 0.16, cy + h * 0.34, cx + h * 0.16, cy + h * 0.34)
    else -- tumbler / highball / mug
      local w2 = h * 0.20
      local hh = h * 0.8
      local top = cy - hh * 0.5
      Draw.set({ 0.94, 0.97, 1.0, 0.13 })
      lg.rectangle("fill", cx - w2, top, w2 * 2, hh, h * 0.03, h * 0.03)
      if fillFrac > 0 then
        local fh = hh * fillFrac
        Draw.set(liquidColor)
        lg.rectangle("fill", cx - w2 * 0.92, top + hh - fh, w2 * 1.84, fh, h * 0.03, h * 0.03)
        Draw.set({ 1, 1, 1, 0.20 })
        lg.rectangle("fill", cx - w2 * 0.92, top + hh - fh, w2 * 0.45, fh, h * 0.02, h * 0.02)
        Draw.set({ 1, 0.96, 0.84, 0.7 }); lg.setLineWidth(math.max(1, h * 0.012))
        lg.line(cx - w2 * 0.92, top + hh - fh, cx + w2 * 0.92, top + hh - fh)
      end
      Draw.set(glass); lg.setLineWidth(math.max(1, h * 0.016))
      lg.rectangle("line", cx - w2, top, w2 * 2, hh, h * 0.03, h * 0.03)
    end
  end
  body()
  -- ice cubes
  if opt.ice then
    for i = 1, (opt.iceCount or 3) do
      local ix = cx - h * 0.10 + (i - 1) * h * 0.09
      Draw.set({ 0.85, 0.93, 1.0, 0.35 })
      lg.rectangle("fill", ix, cy - h * 0.10 + (i % 2) * h * 0.05, h * 0.07, h * 0.07, 2, 2)
    end
  end
  if opt.garnish then
    local gx, gy = cx + h * 0.20, cy - h * 0.44
    Draw.set({ 0.55, 0.85, 0.35 }); lg.circle("fill", gx, gy, h * 0.07, 16)
    Draw.set({ 0.72, 0.95, 0.48 }); lg.circle("fill", gx - h * 0.02, gy - h * 0.02, h * 0.035, 12)
  end
  if opt.umbrella then
    local ux, uy = cx - h * 0.30, cy - h * 0.40
    Draw.set({ 0.85, 0.45, 0.20 }); lg.setLineWidth(math.max(1, h * 0.012))
    lg.line(ux, uy, ux - h * 0.06, uy - h * 0.22)
    lg.polygon("fill", ux - h * 0.16, uy - h * 0.20, ux + h * 0.05, uy - h * 0.20, ux - h * 0.06, uy - h * 0.30)
  end
end

-- ===== chips =====
function Motifs.chipStack(cx, baseY, r, count, colors, t)
  colors = colors or { { 0.62, 0.10, 0.12 }, { 0.14, 0.30, 0.60 }, { 0.16, 0.44, 0.28 }, { 0.12, 0.11, 0.12 } }
  count = math.max(0, math.min(count or 0, 12))
  for i = 1, count do
    local idx = ((i - 1) % #colors) + 1
    local y = baseY - (i - 1) * r * 0.30
    local wob = math.sin((t or 0) * 5 + i) * 0.3
    Draw.set({ 0, 0, 0, 0.35 })
    lg.ellipse("fill", cx + r * 0.10, y + r * 0.16, r, r * 0.46)
    Draw.set(colors[idx]); lg.ellipse("fill", cx, y, r, r * 0.46, 32)
    Draw.set({ 1, 1, 1, 0.14 }); lg.ellipse("fill", cx, y - r * 0.06, r * 0.82, r * 0.30, 28)
    Draw.set(Theme.colors.ivory)
    for k = 0, 5 do
      local a = k * math.pi / 3 + wob * 0.02
      lg.ellipse("fill", cx + math.cos(a) * r * 0.78, y + math.sin(a) * r * 0.36, r * 0.11, r * 0.07, 8)
    end
    Draw.set({ 0.10, 0.09, 0.10, 0.55 }); lg.setLineWidth(1)
    lg.ellipse("line", cx, y, r, r * 0.46, 32)
  end
end

-- ===== card shoe =====
function Motifs.shoe(x, y, w, h, frac, t)
  Draw.set({ 0, 0, 0, 0.4 }); lg.rectangle("fill", x + 3, y + 4, w, h, 5, 5)
  Draw.gradientH(x, y, w, h, { 0.30, 0.16, 0.10 }, { 0.14, 0.07, 0.05 })
  Draw.frame(x, y, w, h, 5, Theme.colors.goldDim, 0.8, 2)
  -- stacked deck inside
  local bx = x + w * 0.12
  local bh = h * 0.66
  local by = y + h * 0.18
  Draw.set({ 0.86, 0.82, 0.72 }); lg.rectangle("fill", bx, by, w * 0.72, bh, 3, 3)
  Draw.set({ 0.70, 0.66, 0.56 }); lg.rectangle("line", bx, by, w * 0.72, bh, 3, 3)
  for i = 1, 3 do
    Draw.set({ 0.78, 0.10, 0.12, 0.6 }); lg.rectangle("fill", bx + i * 1.5, by + i * 1.5, w * 0.72 - i * 3, bh - i * 3, 3, 3)
  end
  -- pressure plate
  Draw.set({ 0.55, 0.30, 0.12 }); lg.rectangle("fill", x + w * 0.06, y + h * 0.86, w * 0.88, h * 0.09, 2, 2)
  -- level meter
  Draw.bar(x + w * 0.12, y + h * 0.04, w * 0.76, math.max(3, h * 0.05), frac or 1, Theme.colors.gold, { 0, 0, 0, 0.5 })
  if (t or 0) > 0 then
    Draw.set({ 1, 0.9, 0.6, 0.10 + 0.06 * math.sin(t * 3) })
    lg.rectangle("fill", x, y, w, h, 5, 5)
  end
end

-- ===== relic icons (programmatic, by icon index) =====
local function iconShape(idx, cx, cy, r, col, accent)
  local k = ((idx or 1) - 1) % 12
  if k == 0 then -- diamond ring
    Draw.diamond(cx, cy, r, col); Draw.diamond(cx, cy, r * 0.5, accent)
  elseif k == 1 then -- spade
    Draw.spade(cx, cy, r * 0.92, col)
  elseif k == 2 then -- star
    Draw.star(cx, cy, r, col, 5, 0.45); Draw.star(cx, cy, r * 0.45, accent, 5, 0.45)
  elseif k == 3 then -- chip
    Draw.chip(cx, cy, r * 0.9, col, accent)
  elseif k == 4 then -- key
    Draw.set(col); lg.setLineWidth(math.max(1.5, r * 0.18))
    lg.circle("line", cx - r * 0.35, cy, r * 0.34, 18)
    lg.line(cx - r * 0.02, cy, cx + r * 0.8, cy)
    lg.line(cx + r * 0.5, cy, cx + r * 0.5, cy + r * 0.32)
    lg.line(cx + r * 0.78, cy, cx + r * 0.78, cy + r * 0.28)
  elseif k == 5 then -- eye
    Draw.set(col); lg.setLineWidth(math.max(1, r * 0.09))
    lg.ellipse("fill", cx, cy, r, r * 0.55, 28)
    Draw.set(accent); lg.circle("fill", cx, cy, r * 0.34, 18)
    Draw.set({ 0.05, 0.04, 0.05 }); lg.circle("fill", cx, cy, r * 0.15, 14)
    Draw.set({ 1, 1, 1, 0.85 }); lg.circle("fill", cx - r * 0.09, cy - r * 0.10, r * 0.06, 10)
  elseif k == 6 then -- crown
    Draw.set(col)
    lg.polygon("fill", cx - r, cy + r * 0.5, cx + r, cy + r * 0.5, cx + r, cy - r * 0.15,
      cx + r * 0.45, cy + r * 0.05, cx, cy - r * 0.7, cx - r * 0.45, cy + r * 0.05, cx - r, cy - r * 0.15)
    Draw.set(accent); lg.circle("fill", cx, cy - r * 0.75, r * 0.16, 12)
  elseif k == 7 then -- flask
    Draw.set(col)
    lg.polygon("fill", cx - r * 0.22, cy - r * 0.85, cx + r * 0.22, cy - r * 0.85, cx + r * 0.22, cy - r * 0.3,
      cx + r * 0.75, cy + r * 0.8, cx - r * 0.75, cy + r * 0.8, cx - r * 0.22, cy - r * 0.3)
    Draw.set(accent); lg.circle("fill", cx, cy + r * 0.42, r * 0.3, 16)
  elseif k == 8 then -- hourglass
    Draw.set(col)
    lg.polygon("fill", cx - r * 0.6, cy - r * 0.85, cx + r * 0.6, cy - r * 0.85, cx, cy)
    lg.polygon("fill", cx - r * 0.6, cy + r * 0.85, cx + r * 0.6, cy + r * 0.85, cx, cy)
    Draw.set(accent); lg.rectangle("fill", cx - r * 0.72, cy - r * 0.98, r * 1.44, r * 0.16, 2)
    lg.rectangle("fill", cx - r * 0.72, cy + r * 0.82, r * 1.44, r * 0.16, 2)
  elseif k == 9 then -- shield
    Draw.set(col)
    lg.polygon("fill", cx, cy - r, cx + r * 0.85, cy - r * 0.55, cx + r * 0.7, cy + r * 0.45, cx, cy + r, cx - r * 0.7, cy + r * 0.45, cx - r * 0.85, cy - r * 0.55)
    Draw.set(accent); Draw.diamond(cx, cy - r * 0.05, r * 0.34)
  elseif k == 10 then -- book
    Draw.set(col); lg.rectangle("fill", cx - r * 0.8, cy - r * 0.8, r * 1.6, r * 1.6, 3, 3)
    Draw.set(accent); lg.rectangle("fill", cx - r * 0.62, cy - r * 0.6, r * 1.24, r * 1.2, 2, 2)
    Draw.set(col); lg.setLineWidth(math.max(1, r * 0.10))
    lg.line(cx, cy - r * 0.6, cx, cy + r * 0.6)
  else -- rod / wand
    Draw.set(col); lg.setLineWidth(math.max(2, r * 0.22))
    lg.line(cx - r * 0.75, cy + r * 0.75, cx + r * 0.6, cy - r * 0.6)
    Draw.set(accent); lg.circle("fill", cx + r * 0.72, cy - r * 0.72, r * 0.28, 16)
    Draw.star(cx + r * 0.72, cy - r * 0.72, r * 0.5, { accent[1], accent[2], accent[3], 0.5 }, 4, 0.4)
  end
end

function Motifs.relicIcon(x, y, w, h, relic, opts)
  opts = opts or {}
  local rar = Theme.rarityColor(relic and relic.rarity)
  local r = math.min(w, h) * 0.5
  local rr = math.max(4, w * 0.10)
  -- plate
  Draw.set({ 0, 0, 0, 0.45 }); lg.rectangle("fill", x + 2, y + 3, w, h, rr, rr)
  Draw.gradientV(x, y, w, h, { rar[1] * 0.30 + 0.06, rar[2] * 0.30 + 0.03, rar[3] * 0.30 + 0.04 },
    { 0.055, 0.030, 0.038 })
  Draw.set({ rar[1], rar[2], rar[3], 0.55 }); lg.setLineWidth(math.max(1.2, w * 0.035))
  lg.rectangle("line", x, y, w, h, rr, rr)
  Draw.set({ 1, 1, 1, 0.10 }); lg.setLineWidth(1)
  lg.rectangle("line", x + 3, y + 3, w - 6, h - 6, rr * 0.7, rr * 0.7)

  local cx, cy = x + w * 0.5, y + h * 0.42
  local iconR = math.min(w * 0.30, h * 0.24)
  local accent = { Theme.colors.goldBright[1], Theme.colors.goldBright[2], Theme.colors.goldBright[3] }
  Draw.glow(cx, cy, iconR * 2.0, { rar[1], rar[2], rar[3], 0.25 }, 0.8)
  if opts.grey then
    Draw.set({ 0, 0, 0, 0.45 }); lg.rectangle("fill", x, y, w, h, rr, rr)
  end
  iconShape(relic and relic.icon or 1, cx, cy, iconR,
    opts.grey and { 0.42, 0.40, 0.42 } or { rar[1] * 0.55 + 0.35, rar[2] * 0.55 + 0.32, rar[3] * 0.55 + 0.30 },
    opts.grey and { 0.30, 0.29, 0.30 } or { 0.98, 0.90, 0.66 })
  return x, y, w, h
end

-- ===== decorative helpers =====
function Motifs.cornerFlourish(cx, cy, size, flipX, flipY, c, a)
  Draw.set(c or Theme.colors.goldDim, a or 0.55)
  lg.setLineWidth(math.max(1, size * 0.05))
  local sx = flipX and -1 or 1
  local sy = flipY and -1 or 1
  lg.line(cx, cy, cx + size * sx, cy)
  lg.line(cx, cy, cx, cy + size * sy)
  -- inner curl
  local cxx, cyy = cx + size * 0.45 * sx, cy + size * 0.45 * sy
  lg.arc("line", "open", cxx, cyy, size * 0.45, math.pi, math.pi * 1.5, 14)
  Draw.set(c or Theme.colors.goldDim, (a or 0.55) * 0.8)
  lg.circle("fill", cx + size * 0.86 * sx, cy + size * 0.12 * sy, size * 0.06, 10)
  lg.circle("fill", cx + size * 0.12 * sx, cy + size * 0.86 * sy, size * 0.06, 10)
end

function Motifs.dice(cx, cy, size, value, col)
  Draw.set({ 0, 0, 0, 0.35 }); lg.rectangle("fill", cx - size * 0.5 + 2, cy - size * 0.5 + 3, size, size, size * 0.18)
  Draw.set(col or { 0.96, 0.94, 0.88 }); lg.rectangle("fill", cx - size * 0.5, cy - size * 0.5, size, size, size * 0.18, size * 0.18)
  Draw.set({ 0.75, 0.72, 0.66 }); lg.setLineWidth(math.max(1, size * 0.03))
  lg.rectangle("line", cx - size * 0.5, cy - size * 0.5, size, size, size * 0.18, size * 0.18)
  Draw.set({ 0.12, 0.11, 0.12 })
  local layouts = {
    [1] = { { 0, 0 } }, [2] = { { -1, -1 }, { 1, 1 } }, [3] = { { -1, -1 }, { 0, 0 }, { 1, 1 } },
    [4] = { { -1, -1 }, { 1, -1 }, { -1, 1 }, { 1, 1 } },
    [5] = { { -1, -1 }, { 1, -1 }, { 0, 0 }, { -1, 1 }, { 1, 1 } },
    [6] = { { -1, -1 }, { 1, -1 }, { -1, 0 }, { 1, 0 }, { -1, 1 }, { 1, 1 } },
  }
  local lay = layouts[value]
  if lay then
    for _, p in ipairs(lay) do
      Draw.set({ 0.12, 0.11, 0.12 })
      lg.circle("fill", cx + p[1] * size * 0.26, cy + p[2] * size * 0.26, size * 0.085, 12)
    end
  else
    Draw.text("?", cx, cy - size * 0.28, size * 0.6, { 0.12, 0.11, 0.12 }, "center")
  end
end

-- felt tabletop for the card table screen
function Motifs.felt(x, y, w, h, t)
  local rx, ry = w * 0.5, h * 0.5
  -- wood rail
  Draw.set({ 0.26, 0.13, 0.07 }); lg.ellipse("fill", x, y, rx + Theme.px(22), ry + Theme.px(18), 72)
  Draw.set({ 0.38, 0.20, 0.10 }); lg.ellipse("fill", x, y, rx + Theme.px(14), ry + Theme.px(12), 72)
  -- felt surface
  local fc = Theme.colors.felt
  Draw.set({ fc[1], fc[2], fc[3] }); lg.ellipse("fill", x, y, rx, ry, 72)
  -- radial light variation
  Draw.glow(x, y - ry * 0.1, rx * 1.05, { 0.20, 0.55, 0.38, 0.13 }, 0.9, ry * 1.05)
  -- inner gold line
  Draw.set({ 0.75, 0.60, 0.28, 0.30 }); lg.setLineWidth(math.max(1, Theme.px(1.6)))
  lg.ellipse("line", x, y, rx - Theme.px(20), ry - Theme.px(16), 72)
  -- felt texture dots
  Draw.set({ 0, 0, 0, 0.07 })
  for i = 1, 60 do
    local a = i * 2.399
    local rr = math.sqrt(i / 60)
    lg.circle("fill", x + math.cos(a) * rx * rr * 0.95, y + math.sin(a) * ry * rr * 0.95, Theme.px(1.4), 6)
  end
end

function Motifs.sparkle(cx, cy, r, t, c)
  local a = 0.4 + 0.6 * math.abs(math.sin(t * 2.2))
  Draw.set(c or { 1, 0.95, 0.75, a })
  lg.setLineWidth(math.max(1, r * 0.10))
  lg.line(cx - r, cy, cx + r, cy)
  lg.line(cx, cy - r, cx, cy + r)
  Draw.set(c or { 1, 0.95, 0.75, a * 0.5 })
  lg.line(cx - r * 0.6, cy - r * 0.6, cx + r * 0.6, cy + r * 0.6)
  lg.line(cx + r * 0.6, cy - r * 0.6, cx - r * 0.6, cy + r * 0.6)
end

return Motifs
