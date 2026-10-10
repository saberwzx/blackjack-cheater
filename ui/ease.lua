-- ui/ease.lua : easing functions + tween/timer manager (pure Lua)
local Ease = {}

local function clamp01(t) if t < 0 then return 0 elseif t > 1 then return 1 else return t end end

Ease.linear     = function(t) return t end
Ease.inQuad     = function(t) return t * t end
Ease.outQuad    = function(t) return 1 - (1 - t) * (1 - t) end
Ease.inOutQuad  = function(t) if t < 0.5 then return 2 * t * t else return 1 - ((-2 * t + 2) ^ 2) / 2 end end
Ease.inCubic    = function(t) return t * t * t end
Ease.outCubic   = function(t) return 1 - (1 - t) ^ 3 end
Ease.inOutCubic = function(t) if t < 0.5 then return 4 * t * t * t else return 1 - ((-2 * t + 2) ^ 3) / 2 end end
Ease.inQuart    = function(t) return t * t * t * t end
Ease.outQuart   = function(t) return 1 - (1 - t) ^ 4 end
Ease.outQuint   = function(t) return 1 - (1 - t) ^ 5 end
Ease.inSine     = function(t) return 1 - math.cos((t * math.pi) / 2) end
Ease.outSine    = function(t) return math.sin((t * math.pi) / 2) end
Ease.inOutSine  = function(t) return -(math.cos(math.pi * t) - 1) / 2 end
Ease.inExpo     = function(t) if t <= 0 then return 0 end return 2 ^ (10 * t - 10) end
Ease.outExpo    = function(t) if t >= 1 then return 1 end return 1 - 2 ^ (-10 * t) end
Ease.outBack    = function(t) local c1 = 1.70158; local c3 = c1 + 1; return 1 + c3 * (t - 1) ^ 3 + c1 * (t - 1) ^ 2 end
Ease.inBack     = function(t) local c1 = 1.70158; local c3 = c1 + 1; return c3 * t * t * t - c1 * t * t end
Ease.outElastic = function(t)
  if t == 0 or t == 1 then return t end
  local c4 = (2 * math.pi) / 3
  return 2 ^ (-10 * t) * math.sin((t * 10 - 0.75) * c4) + 1
end
Ease.outBounce = function(t)
  local n1, d1 = 7.5625, 2.75
  if t < 1 / d1 then return n1 * t * t
  elseif t < 2 / d1 then t = t - 1.5 / d1; return n1 * t * t + 0.75
  elseif t < 2.5 / d1 then t = t - 2.25 / d1; return n1 * t * t + 0.9375
  else t = t - 2.625 / d1; return n1 * t * t + 0.984375 end
end
Ease.clamp01 = clamp01
function Ease.lerp(a, b, t) return a + (b - a) * t end
function Ease.mix(c1, c2, t)
  return { c1[1] + (c2[1] - c1[1]) * t, c1[2] + (c2[2] - c1[2]) * t,
           c1[3] + (c2[3] - c1[3]) * t, (c1[4] or 1) + ((c2[4] or 1) - (c1[4] or 1)) * t }
end
function Ease.pulse(time, speed) return 0.5 + 0.5 * math.sin(time * (speed or 4)) end

-- ===== Tween manager =====
local Tweens = { _list = {}, _timers = {}, _time = 0 }
Tweens.__index = Tweens

function Tweens.time() return Tweens._time end
function Tweens.clear() Tweens._list = {}; Tweens._timers = {} end

-- numeric tween
function Tweens.to(dur, from, to, ease, onUpdate, onDone)
  Tweens._list[#Tweens._list + 1] = {
    t = 0, dur = math.max(0.0001, dur or 0.3), from = from, to = to,
    ease = ease or Ease.outCubic, onUpdate = onUpdate, onDone = onDone,
  }
end

function Tweens.delay(dur, fn) Tweens._timers[#Tweens._timers + 1] = { t = 0, dur = dur or 0, fn = fn } end

function Tweens.update(dt)
  Tweens._time = Tweens._time + dt
  local list = Tweens._list
  local i = 1
  while i <= #list do
    local tw = list[i]
    tw.t = tw.t + dt
    local k = clamp01(tw.t / tw.dur)
    local v = tw.from + (tw.to - tw.from) * tw.ease(k)
    if tw.onUpdate then tw.onUpdate(v, k) end
    if k >= 1 then
      local done = tw.onDone
      table.remove(list, i)
      if done then done() end
    else i = i + 1 end
  end
  local timers = Tweens._timers
  local j = 1
  while j <= #timers do
    local tm = timers[j]
    tm.t = tm.t + dt
    if tm.t >= tm.dur then
      local fn = tm.fn
      table.remove(timers, j)
      if fn then fn() end
    else j = j + 1 end
  end
end

Ease.Tweens = Tweens
return Ease
