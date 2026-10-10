-- ui/widgets.lua : reusable controls built on the hotspot registry.
local Theme = require("ui.theme")
local Draw = require("ui.draw")
local Hot = require("ui.hot")
local Ease = require("ui.ease")
local lg = love.graphics

local W = {}
local TAU = math.pi * 2

local TONES = {
  gold    = { fill = { 0.30, 0.19, 0.07 }, edge = Theme.colors.gold, text = Theme.colors.goldPale, glow = { 1.0, 0.84, 0.40 } },
  red     = { fill = { 0.34, 0.07, 0.09 }, edge = { 0.82, 0.24, 0.22 }, text = { 1.0, 0.88, 0.80 }, glow = { 1.0, 0.40, 0.30 } },
  green   = { fill = { 0.07, 0.26, 0.16 }, edge = { 0.34, 0.78, 0.46 }, text = { 0.86, 1.0, 0.90 }, glow = { 0.45, 1.0, 0.60 } },
  blue    = { fill = { 0.07, 0.15, 0.32 }, edge = { 0.38, 0.62, 0.95 }, text = { 0.86, 0.94, 1.0 }, glow = { 0.45, 0.70, 1.0 } },
  purple  = { fill = { 0.20, 0.09, 0.32 }, edge = { 0.66, 0.44, 0.95 }, text = { 0.94, 0.88, 1.0 }, glow = { 0.72, 0.50, 1.0 } },
  grey    = { fill = { 0.15, 0.14, 0.15 }, edge = { 0.44, 0.43, 0.45 }, text = { 0.68, 0.66, 0.64 }, glow = { 0.60, 0.58, 0.58 } },
  dark    = { fill = { 0.10, 0.06, 0.07 }, edge = { 0.36, 0.28, 0.14 }, text = Theme.colors.textDim, glow = { 0.70, 0.60, 0.35 } },
}

-- ================= button =================
-- t = { id, x, y, w, h, label, sub, tone, enabled, hotkey, tip, tipTitle, icon=fn(x,y,s)|glyph,
--       size, pulse, badge, round }
function W.button(t)
  local tone = TONES[t.tone or "gold"] or TONES.gold
  local hs = Hot.btn({ id = t.id, x = t.x, y = t.y, w = t.w, h = t.h,
    enabled = t.enabled ~= false, tip = t.tip, tipTitle = t.tipTitle, kind = "button", tag = t.tag, data = t.data })
  local hovered = (Hot.hover == hs)
  local disabled = t.enabled == false
  local press = hovered and love.mouse.isDown(1)
  local r = t.round or Theme.px(6)
  local off = press and Theme.px(1) or 0

  local fill = { tone.fill[1], tone.fill[2], tone.fill[3] }
  local edge = { tone.edge[1], tone.edge[2], tone.edge[3] }
  if disabled then fill = { 0.09, 0.085, 0.09 }; edge = { 0.28, 0.27, 0.28 } end
  if hovered and not disabled then
    fill = { math.min(1, fill[1] * 1.5 + 0.05), math.min(1, fill[2] * 1.5 + 0.04), math.min(1, fill[3] * 1.5 + 0.04) }
    edge = { math.min(1, edge[1] * 1.15), math.min(1, edge[2] * 1.15), math.min(1, edge[3] * 1.15) }
  end

  local x, y = t.x, t.y + off
  -- glow on hover / pulse
  local pulse = 0
  if t.pulse then pulse = 0.5 + 0.5 * math.sin(Theme.time * 5) end
  if (hovered and not disabled) or pulse > 0 then
    local gl = { tone.glow[1], tone.glow[2], tone.glow[3], (hovered and 0.22 or 0) + pulse * 0.20 }
    Draw.glow(x + t.w * 0.5, y + t.h * 0.5, t.w * 0.62, gl, 1, t.h * 0.85)
  end

  Draw.set({ 0, 0, 0, 0.5 }); lg.rectangle("fill", x + 2, y + 3, t.w, t.h, r, r)
  Draw.gradientV(x, y, t.w, t.h, { math.min(1, fill[1] * 1.6), math.min(1, fill[2] * 1.6), math.min(1, fill[3] * 1.6) }, fill)
  if hovered and not disabled then
    Draw.gradientV(x, y, t.w, t.h * 0.55, { 1, 1, 1, 0.10 }, { 1, 1, 1, 0 })
  end
  lg.setLineWidth(math.max(1, Theme.px(1.3)))
  Draw.set(edge); lg.rectangle("line", x, y, t.w, t.h, r, r)
  Draw.set({ 0, 0, 0, 0.35 }); lg.rectangle("line", x + 1, y + 1, t.w - 2, t.h - 2, math.max(0, r - 1), math.max(0, r - 1))

  local tx = x + t.w * 0.5
  local size = Theme.px(t.size or 17)
  local label = t.label or ""
  local hasSub = t.sub and t.sub ~= ""
  local labelY = y + (hasSub and t.h * 0.26 or (t.h - size * 1.0) * 0.5)
  if t.icon then
    local isz = math.min(t.h * 0.42, t.w * 0.22)
    local ix = x + t.w * 0.5 - (Fonts_width(label, size) + isz * 1.3) * 0.5 + isz * 0.5
    t.icon(ix, y + t.h * 0.5, isz)
  end
  local textX = tonumber(t.icon) and (x + t.w * 0.5) or (x + t.w * 0.5)
  Draw.label(label, textX, labelY, size,
    disabled and { 0.58, 0.56, 0.56 } or tone.text,
    "center", t.w - Theme.px(6))
  if hasSub then
    Draw.text(t.sub, x + t.w * 0.5, y + t.h * 0.60, Theme.px(t.subSize or 11), disabled and { 0.50, 0.49, 0.49 } or Theme.colors.textDim, "center", t.w)
  end
  if t.badge then
    local bw = Theme.px(30)
    Draw.set({ 0.72, 0.10, 0.12 }); lg.rectangle("fill", x + t.w - bw * 0.72, y - Theme.px(7), bw, Theme.px(16), Theme.px(8), Theme.px(8))
    Draw.text(t.badge, x + t.w - bw * 0.72 + bw * 0.5, y - Theme.px(5), Theme.px(10), { 1, 0.95, 0.9 }, "center", bw)
  end
  if t.hotkey and not disabled then
    local ks = Theme.px(10)
    local kw = Fonts_width(t.hotkey, ks)
    Draw.set({ 0, 0, 0, 0.45 })
    lg.rectangle("fill", x + t.w - kw - Theme.px(10), y + t.h - Theme.px(15), kw + Theme.px(7), Theme.px(12), Theme.px(3), Theme.px(3))
    Draw.text(t.hotkey, x + t.w - kw - Theme.px(6.5), y + t.h - Theme.px(13.5), ks, { 0.90, 0.82, 0.60 }, "left")
  end
  return hs
end

function Fonts_width(s, size)
  return require("ui.fonts").get(size):getWidth(s)
end
W.textWidth = Fonts_width

-- circular icon button
function W.iconButton(t)
  local hs = Hot.btn({ id = t.id, x = t.x - t.r, y = t.y - t.r, w = t.r * 2, h = t.r * 2,
    enabled = t.enabled ~= false, tip = t.tip, tipTitle = t.tipTitle, kind = "button", tag = t.tag, data = t.data })
  local hovered = (Hot.hover == hs)
  local disabled = t.enabled == false
  local base = t.color or Theme.colors.gold
  if disabled then base = { 0.30, 0.29, 0.30 } end
  Draw.set({ 0, 0, 0, 0.45 }); lg.circle("fill", t.x + 2, t.y + 3, t.r, 28)
  Draw.set({ base[1] * 0.35, base[2] * 0.35, base[3] * 0.35 }); lg.circle("fill", t.x, t.y, t.r, 28)
  if hovered and not disabled then Draw.glow(t.x, t.y, t.r * 1.5, { base[1], base[2], base[3], 0.30 }, 1) end
  Draw.circleLine(t.x, t.y, t.r, base, hovered and 1 or 0.8, math.max(1.2, Theme.px(1.6)))
  if t.glyph then
    Draw.text(t.glyph, t.x, t.y - Theme.px(t.glyphSize or 10), Theme.px(t.glyphSize or 20), base, "center")
  end
  if t.icon then t.icon(t.x, t.y, t.r * 0.6) end
  return hs
end

-- toggle switch
function W.toggle(t)
  local hs = Hot.btn({ id = t.id, x = t.x, y = t.y, w = t.w, h = t.h, enabled = t.enabled ~= false,
    tip = t.tip, kind = "button", tag = t.tag, data = t.data })
  local hovered = (Hot.hover == hs)
  local r = t.h * 0.5
  Draw.set({ 0, 0, 0, 0.4 }); lg.rectangle("fill", t.x + 2, t.y + 3, t.w, t.h, r, r)
  local on = t.value and true or false
  local c = on and (t.color or Theme.colors.green) or { 0.30, 0.29, 0.30 }
  if hovered then c = { math.min(1, c[1] * 1.2), math.min(1, c[2] * 1.2), math.min(1, c[3] * 1.2) } end
  Draw.set({ c[1] * 0.4, c[2] * 0.4, c[3] * 0.4 }); lg.rectangle("fill", t.x, t.y, t.w, t.h, r, r)
  Draw.set(c); lg.rectangle("line", t.x, t.y, t.w, t.h, r, r)
  local kx = on and (t.x + t.w - r) or (t.x + r)
  Draw.set({ 0.96, 0.95, 0.92 }); lg.circle("fill", kx, t.y + r, r * 0.78, 20)
  Draw.set({ 0, 0, 0, 0.25 }); lg.circle("fill", kx, t.y + r * 1.1, r * 0.7, 20)
  Draw.set({ 0.96, 0.95, 0.92 }); lg.circle("fill", kx, t.y + r, r * 0.72, 20)
  if t.label then
    Draw.text(t.label, t.x + t.w + Theme.px(8), t.y + r - Theme.px(8), Theme.px(14), Theme.colors.text, "left")
  end
  return hs
end

-- ================= slider =================
-- t = { id, x, y, w, h, min, max, step, value, enabled, onChange, label, fmt, marks }
function W.slider(t)
  local h = t.h or Theme.px(14)
  local pad = h * 0.9
  local hs = Hot.btn({ id = t.id, x = t.x - pad, y = t.y - pad, w = t.w + pad * 2, h = h + pad * 2,
    enabled = t.enabled ~= false, kind = "slider", tip = t.tip, tag = t.tag, data = t.data })
  local hovered = (Hot.hover == hs)
  local disabled = t.enabled == false
  local min, max = t.min or 0, t.max or 100
  local range = math.max(0.0001, max - min)
  local function valAt(mx)
    local k = math.max(0, math.min(1, (mx - t.x) / math.max(1, t.w)))
    local v = min + k * range
    if t.step and t.step > 0 then v = math.floor(v / t.step + 0.5) * t.step end
    if t.int then v = math.floor(v + 0.5) end
    return math.max(min, math.min(max, v))
  end
  hs.drag = {
    move = function(mx) local v = valAt(mx); if v ~= t.value then t.value = v; if t.onChange then t.onChange(v) end end end,
    ["end"] = function() end,
  }
  local frac = math.max(0, math.min(1, (t.value - min) / range))

  -- track
  local r = h * 0.5
  Draw.set({ 0, 0, 0, 0.55 }); lg.rectangle("fill", t.x, t.y, t.w, h, r, r)
  Draw.gradientV(t.x, t.y, t.w, h, { 0.16, 0.10, 0.06 }, { 0.06, 0.04, 0.03 })
  -- filled portion
  if frac > 0 then
    Draw.set(disabled and { 0.28, 0.27, 0.28 } or (t.color or { 0.72, 0.52, 0.18 }))
    lg.rectangle("fill", t.x, t.y, math.max(h, t.w * frac), h, r, r)
    if not disabled then Draw.gradientV(t.x, t.y, math.max(h, t.w * frac), h, { 1, 0.92, 0.65, 0.30 }, { 1, 1, 1, 0 }) end
  end
  lg.setLineWidth(math.max(1, Theme.px(1.2)))
  Draw.set(hovered and Theme.colors.goldBright or Theme.colors.goldDim, disabled and 0.5 or 0.95)
  lg.rectangle("line", t.x, t.y, t.w, h, r, r)

  -- tick marks
  if t.marks then
    for _, m in ipairs(t.marks) do
      local k = (m - min) / range
      Draw.set({ 0.9, 0.8, 0.5, 0.35 }); lg.setLineWidth(1)
      lg.line(t.x + t.w * k, t.y + h + 2, t.x + t.w * k, t.y + h + 5)
    end
  end

  -- knob
  local kx = t.x + t.w * frac
  local kr = h * 0.95
  Draw.set({ 0, 0, 0, 0.5 }); lg.circle("fill", kx + 1.5, t.y + h * 0.5 + 2, kr, 22)
  local kc = disabled and { 0.42, 0.41, 0.42 } or { 0.92, 0.76, 0.40 }
  if hovered or Hot.drag and Hot.drag.id == t.id then kc = Theme.colors.goldBright end
  Draw.set(kc); lg.circle("fill", kx, t.y + h * 0.5, kr, 22)
  Draw.set({ 1, 1, 1, 0.55 }); lg.circle("fill", kx - kr * 0.25, t.y + h * 0.5 - kr * 0.28, kr * 0.30, 14)
  Draw.set({ 0.35, 0.24, 0.10 }); lg.circle("fill", kx, t.y + h * 0.5, kr * 0.34, 16)

  if t.label then
    Draw.text(t.label .. (t.fmt and t.fmt(t.value) or (" " .. tostring(t.value))),
      t.x + t.w * 0.5, t.y - Theme.px(20), Theme.px(14), Theme.colors.goldPale, "center", t.w)
  end
  return hs
end

-- ================= scrollbar =================
-- returns nothing; registers a thumb drag into Hot and a wheel region
function W.scrollArea(id, x, y, w, h, contentH, get, set)
  local maxScroll = math.max(0, contentH - h)
  Hot.scrollRegion(id, x, y, w, h, maxScroll, get, set)
  if maxScroll <= 0 then return end
  local sbw = Theme.px(7)
  local sx = x + w - sbw
  Draw.set({ 0, 0, 0, 0.35 }); lg.rectangle("fill", sx, y, sbw, h, sbw * 0.5, sbw * 0.5)
  local frac = h / contentH
  local th = math.max(Theme.px(24), h * frac)
  local k = math.max(0, math.min(1, (get() or 0) / maxScroll))
  local ty = y + (h - th) * k
  Draw.set({ 0.55, 0.42, 0.18 }); lg.rectangle("fill", sx, ty, sbw, th, sbw * 0.5, sbw * 0.5)
  Draw.set({ 0.90, 0.76, 0.42, 0.9 }); lg.rectangle("fill", sx + 1, ty + 1, sbw - 2, th - 2, sbw * 0.5, sbw * 0.5)
  Hot.btn({
    id = id .. ".thumb", x = sx - Theme.px(3), y = ty, w = sbw + Theme.px(6), h = th, kind = "scrollthumb",
    drag = { move = function(mx, my)
      local kk = math.max(0, math.min(1, (my - y - th * 0.5) / math.max(1, h - th)))
      set(kk * maxScroll)
    end },
  })
end

-- ================= tabs =================
function W.tabs(id, x, y, w, h, items, activeId)
  local n = #items
  local tw = w / n
  for i, it in ipairs(items) do
    local bx = x + (i - 1) * tw
    local active = it.id == activeId
    local hs = Hot.btn({ id = id .. "." .. tostring(it.id), x = bx, y = y, w = tw, h = h, kind = "tab", data = it })
    local hovered = (Hot.hover == hs)
    if active then
      Draw.gradientV(bx, y, tw, h, { 0.36, 0.24, 0.09 }, { 0.20, 0.13, 0.06 })
      Draw.set(Theme.colors.goldBright); lg.setLineWidth(math.max(1, Theme.px(1.6)))
      lg.rectangle("line", bx, y, tw, h)
    else
      Draw.set({ 0.10, 0.07, 0.08, 0.9 }); lg.rectangle("fill", bx, y, tw, h)
      Draw.set(hovered and Theme.colors.gold or Theme.colors.goldDim, hovered and 0.9 or 0.45)
      lg.setLineWidth(1); lg.rectangle("line", bx, y, tw, h)
    end
    Draw.text(it.label, bx + tw * 0.5, y + (h - Theme.px(15)) * 0.5, Theme.px(15),
      active and Theme.colors.goldPale or Theme.colors.textDim, "center", tw)
  end
end

-- ================= misc =================
function W.priceTag(x, y, price, canAfford, opts)
  opts = opts or {}
  local s = tostring(price)
  local size = Theme.px(opts.size or 15)
  local tw = Fonts_width(s, size)
  local px, py = x, y
  Draw.set({ 0, 0, 0, 0.55 })
  lg.rectangle("fill", px - Theme.px(5), py - Theme.px(3), tw + Theme.px(10), size + Theme.px(7), Theme.px(4), Theme.px(4))
  Draw.text(s, px, py, size, canAfford and Theme.colors.goldBright or { 0.85, 0.35, 0.32 }, "left")
  return tw + Theme.px(10)
end

function W.banner(text, x, y, w, h, tone)
  local c = TONES[tone or "gold"]
  Draw.gradientV(x, y, w, h, { c.fill[1] * 1.4, c.fill[2] * 1.4, c.fill[3] * 1.4, 0.95 }, { 0, 0, 0, 0.15 })
  Draw.set(c.edge); lg.setLineWidth(math.max(1, Theme.px(1.4)))
  lg.rectangle("line", x, y, w, h, Theme.px(4), Theme.px(4))
  Draw.label(text, x + w * 0.5, y + (h - Theme.px(16)) * 0.5, Theme.px(16), c.text, "center", w)
end

-- tooltip drawn last, auto-flips near screen edges
function W.drawTooltip()
  local tt = Hot.tooltip
  if not tt or not tt.text or tt.text == "" then return end
  local size = Theme.px(13)
  local maxW = math.min(Theme.px(300), Theme.W * 0.42)
  local lines = require("ui.fonts").wrap(tt.text, require("ui.fonts").get(size), maxW)
  local lh = require("ui.fonts").get(size):getHeight() * 1.28
  local titleH = tt.title and (Theme.px(16) + Theme.px(6)) or 0
  local w = maxW + Theme.px(18)
  local th = #lines * lh + Theme.px(14) + titleH
  local x = (tt.x or Hot.mx) + (tt.w or 0) + Theme.px(8)
  local y = (tt.y or Hot.my)
  if x + w > Theme.W - Theme.px(6) then x = (tt.x or Hot.mx) - w - Theme.px(8) end
  if x < Theme.px(6) then x = Theme.px(6) end
  if y + th > Theme.H - Theme.px(6) then y = Theme.H - th - Theme.px(6) end
  if y < Theme.px(6) then y = Theme.px(6) end
  Draw.set({ 0, 0, 0, 0.55 }); lg.rectangle("fill", x + 3, y + 4, w, th, Theme.px(5), Theme.px(5))
  Draw.gradientV(x, y, w, th, { 0.13, 0.09, 0.10, 0.98 }, { 0.05, 0.03, 0.04, 0.98 })
  Draw.set(Theme.colors.gold); lg.setLineWidth(math.max(1, Theme.px(1.3)))
  lg.rectangle("line", x, y, w, th, Theme.px(5), Theme.px(5))
  local cy = y + Theme.px(7)
  if tt.title then
    Draw.text(tt.title, x + Theme.px(9), cy, Theme.px(15), Theme.colors.goldBright, "left", maxW)
    cy = cy + Theme.px(19)
    Draw.set({ 0.7, 0.55, 0.25, 0.4 }); lg.setLineWidth(1); lg.line(x + Theme.px(9), cy - Theme.px(3), x + w - Theme.px(9), cy - Theme.px(3))
  end
  for i, l in ipairs(lines) do
    Draw.text(l, x + Theme.px(9), cy + (i - 1) * lh, size, Theme.colors.text, "left")
  end
end

function W.hovered(hs) return Hot.hover == hs end

return W
