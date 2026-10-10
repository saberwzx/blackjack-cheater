-- ui/particles.lua : CPU particle system, screen shake, floating score popups
local Theme = require("ui.theme")
local Draw = require("ui.draw")
local lg = love.graphics

local Particles = {}
Particles.__index = Particles

function Particles.new(max)
  local self = setmetatable({}, Particles)
  self.max = max or 600
  self.list = {}
  return self
end

function Particles:emit(x, y, opt)
  opt = opt or {}
  local n = opt.count or 1
  for _ = 1, n do
    if #self.list < self.max then
      local spread = opt.spread or 1
      local ang = opt.angle or (-math.pi * 0.5)
      local a = ang + (love.math.random() - 0.5) * (opt.arc or math.pi * 2) * spread
      local spd = (opt.speed or 80) * (0.5 + love.math.random() * 0.9)
      local life = (opt.life or 0.8) * (0.65 + love.math.random() * 0.7)
      self.list[#self.list + 1] = {
        x = x + (love.math.random() - 0.5) * (opt.jitter or 0),
        y = y + (love.math.random() - 0.5) * (opt.jitter or 0),
        vx = math.cos(a) * spd, vy = math.sin(a) * spd,
        life = life, maxLife = life,
        size = (opt.size or 3) * (0.6 + love.math.random() * 0.9),
        color = opt.color or Theme.colors.goldBright,
        drag = opt.drag or 1.6, grav = opt.grav or 0,
        grow = opt.grow or 0, kind = opt.kind or "dot",
        rot = love.math.random() * math.pi * 2,
        spin = (love.math.random() - 0.5) * (opt.spin or 4),
        alpha0 = opt.alpha or 1,
      }
    end
  end
end

function Particles:update(dt)
  local l = self.list
  local i = 1
  while i <= #l do
    local p = l[i]
    p.life = p.life - dt
    if p.life <= 0 then
      table.remove(l, i)
    else
      local damp = math.max(0, 1 - p.drag * dt)
      p.vx = p.vx * damp
      p.vy = p.vy * damp + p.grav * dt
      p.x = p.x + p.vx * dt
      p.y = p.y + p.vy * dt
      p.rot = p.rot + p.spin * dt
      p.size = p.size + p.grow * dt
      i = i + 1
    end
  end
end

function Particles:clear() self.list = {} end
function Particles:count() return #self.list end

function Particles:draw()
  for _, p in ipairs(self.list) do
    local k = p.life / p.maxLife
    local a = k * p.alpha0
    local c = p.color
    if p.kind == "spark" then
      Draw.set(c, a); lg.setLineWidth(math.max(1, p.size * k))
      local len = p.size * 3 * k + 2
      local vx, vy = p.vx, p.vy
      local m = math.max(1, math.sqrt(vx * vx + vy * vy))
      lg.line(p.x, p.y, p.x - vx / m * len, p.y - vy / m * len)
    elseif p.kind == "coin" then
      Draw.set({ 0, 0, 0, a * 0.4 }); lg.circle("fill", p.x, p.y + p.size * 0.3, p.size * k, 12)
      Draw.chip(p.x, p.y, p.size * k, c, Theme.colors.ivory)
    elseif p.kind == "chip" then
      Draw.set(c, a)
      lg.push(); lg.translate(p.x, p.y); lg.rotate(p.rot)
      lg.rectangle("fill", -p.size * k, -p.size * k * 0.4, p.size * 2 * k, p.size * 0.8 * k, 2)
      lg.pop()
    elseif p.kind == "shard" then
      Draw.set(c, a)
      lg.push(); lg.translate(p.x, p.y); lg.rotate(p.rot)
      lg.polygon("fill", 0, -p.size * k, p.size * k, p.size * k * 0.7, -p.size * k, p.size * k * 0.7)
      lg.pop()
    elseif p.kind == "smoke" then
      Draw.set(c, a * 0.4); lg.circle("fill", p.x, p.y, p.size * (1.6 - k), 14)
    elseif p.kind == "star" then
      if Draw.polyStar then Draw.polyStar(p.x, p.y, p.size * k, c, a)
      else Draw.star(p.x, p.y, p.size * k, c, 4, 0.4, a) end
    else
      Draw.set(c, a); lg.circle("fill", p.x, p.y, math.max(0.5, p.size * k), 12)
    end
  end
end

-- ===== screen shake =====
local Shake = { t = 0, dur = 0, mag = 0, ox = 0, oy = 0, maxMag = 8 }
function Shake.add(mag, dur)
  dur = dur or 0.35
  mag = math.min(mag or 3, Shake.maxMag)
  if mag > Shake.mag * (Shake.t / math.max(0.001, Shake.dur)) then
    Shake.mag = mag; Shake.dur = dur; Shake.t = dur
  end
end
function Shake.update(dt)
  if Shake.t > 0 then
    Shake.t = Shake.t - dt
    local k = math.max(0, Shake.t / Shake.dur)
    local amp = Shake.mag * k * k
    Shake.ox = (love.math.random() - 0.5) * 2 * amp
    Shake.oy = (love.math.random() - 0.5) * 2 * amp
  else
    Shake.ox, Shake.oy = 0, 0
  end
end
function Shake.apply() lg.translate(Shake.ox * Theme.s, Shake.oy * Theme.s) end
function Shake.clear() Shake.t = 0; Shake.mag = 0; Shake.ox = 0; Shake.oy = 0 end
Particles.Shake = Shake

-- ===== floating score popups =====
local Popups = { list = {} }
function Popups.add(text, x, y, color, big)
  Popups.list[#Popups.list + 1] = {
    text = text, x = x, y = y, t = 0, dur = 1.4,
    color = color or Theme.colors.goldBright, big = big or false,
    scale = big and 2 or 1,
  }
end
function Popups.update(dt)
  local i = 1
  while i <= #Popups.list do
    local p = Popups.list[i]
    p.t = p.t + dt
    p.y = p.y - 26 * dt
    if p.t >= p.dur then table.remove(Popups.list, i) else i = i + 1 end
  end
end
function Popups.draw()
  for _, p in ipairs(Popups.list) do
    local k = p.t / p.dur
    local a = k < 0.15 and (k / 0.15) or (1 - (k - 0.15) / 0.85)
    local pop = 1 + 0.25 * math.max(0, 1 - k * 5)
    local size = Theme.px(18 * p.scale * pop)
    Draw.textOutline(p.text, p.x, p.y, size, { p.color[1], p.color[2], p.color[3], a }, { 0, 0, 0, a * 0.9 }, "center", nil, Theme.px(2))
  end
end
function Popups.clear() Popups.list = {} end
Particles.Popups = Popups

return Particles
