-- ui/theme.lua : dark-gold-red casino palette + layout metrics
local Theme = {}

Theme.colors = {
  bg0        = { 0.030, 0.016, 0.020 },
  bg1        = { 0.075, 0.028, 0.038 },
  wine       = { 0.160, 0.030, 0.050 },
  wineDeep   = { 0.090, 0.015, 0.028 },
  panel      = { 0.090, 0.050, 0.058 },
  panelAlt   = { 0.150, 0.082, 0.088 },
  panelDeep  = { 0.045, 0.026, 0.030 },
  edge       = { 0.320, 0.235, 0.100 },
  gold       = { 0.840, 0.670, 0.300 },
  goldBright = { 0.985, 0.880, 0.560 },
  goldPale   = { 1.000, 0.955, 0.780 },
  goldDim    = { 0.470, 0.360, 0.140 },
  red        = { 0.720, 0.120, 0.140 },
  redBright  = { 0.940, 0.290, 0.270 },
  crimson    = { 0.360, 0.045, 0.070 },
  felt       = { 0.055, 0.210, 0.150 },
  feltLit    = { 0.085, 0.300, 0.215 },
  feltDark   = { 0.028, 0.110, 0.082 },
  ivory      = { 0.960, 0.930, 0.850 },
  ink        = { 0.090, 0.070, 0.060 },
  white      = { 1.000, 1.000, 1.000 },
  black      = { 0.000, 0.000, 0.000 },
  green      = { 0.280, 0.720, 0.400 },
  greenDim   = { 0.130, 0.380, 0.220 },
  blue       = { 0.300, 0.560, 0.930 },
  purple     = { 0.580, 0.360, 0.880 },
  cyan       = { 0.280, 0.780, 0.740 },
  orange     = { 0.960, 0.600, 0.200 },
  grey       = { 0.560, 0.545, 0.560 },
  greyDim    = { 0.300, 0.290, 0.300 },
  shadow     = { 0.000, 0.000, 0.000, 0.55 },
  shadowSoft = { 0.000, 0.000, 0.000, 0.30 },
}

-- semantic aliases
Theme.colors.text      = Theme.colors.goldPale
Theme.colors.textDim   = { 0.700, 0.640, 0.520 }
Theme.colors.textGold  = Theme.colors.gold
Theme.colors.positive  = Theme.colors.green
Theme.colors.negative  = Theme.colors.redBright
Theme.colors.hot       = Theme.colors.orange

Theme.rarity = {
  common    = { 0.62, 0.62, 0.64 },
  uncommon  = { 0.32, 0.74, 0.46 },
  rare      = { 0.36, 0.60, 0.95 },
  legendary = { 0.92, 0.66, 0.24 },
  cursed    = { 0.68, 0.36, 0.88 },
}

Theme.metrics = {
  relicW = 71, relicH = 95,
  cardW = 74, cardH = 104,
  miniCardW = 40, miniCardH = 58,
  handMax = 12,
  relicSlots = 5,
}

Theme.W, Theme.H = 1280, 720
Theme.scale = 1
Theme.s = 1
Theme.dt = 0
Theme.time = 0

-- Virtual design space is a fixed 1280x720 box, centred in the window.
-- Screens are authored in virtual units and emit device coordinates through
-- Theme.vx/Theme.vy (position) and Theme.v/Theme.px (size).  The four target
-- resolutions 800x600, 1280x720, 1600x900 and 1920x1080 all map exactly.
Theme.vw, Theme.vh = 1280, 720
Theme.ox, Theme.oy = 0, 0

function Theme.setSize(w, h)
  Theme.W, Theme.H = w, h
  local sw, sh = w / Theme.vw, h / Theme.vh
  Theme.scale = math.min(sw, sh)
  Theme.s = Theme.scale
  Theme.sw, Theme.sh = sw, sh
  Theme.ox = math.floor((w - Theme.vw * Theme.s) * 0.5)
  Theme.oy = math.floor((h - Theme.vh * Theme.s) * 0.5)
end

function Theme.v(n) return (n or 0) * Theme.s end
function Theme.px(n) return (n or 0) * Theme.s end
function Theme.vx(x) return Theme.ox + (x or 0) * Theme.s end
function Theme.vy(y) return Theme.oy + (y or 0) * Theme.s end
function Theme.vw2() return Theme.vw * Theme.s end
function Theme.vh2() return Theme.vh * Theme.s end

-- safe alpha color
function Theme.a(c, a) return { c[1], c[2], c[3], (c[4] or 1) * (a or 1) } end
function Theme.shade(c, f)
  return { math.min(1, c[1] * f), math.min(1, c[2] * f), math.min(1, c[3] * f), c[4] or 1 }
end

Theme.rarityColor = function(r)
  return Theme.rarity[r] or Theme.rarity.common
end

return Theme
