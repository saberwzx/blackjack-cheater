-- ui/audio.lua : fully programmatic SFX + stage BGM (no asset files).
-- Uses its own local LCG for noise so gameplay randomness (love.math.random) is never consumed.
local Audio = {}

local RATE = 22050
local sources = {}
local bgmSource = nil
local bgmName = nil
local volume = 0.6
Audio.enabled = true
Audio.sfxVolume = 1.0
Audio.bgmVolume = 0.55

-- deterministic local PRNG (never touches love.math.random)
local seed = 20261001
local function rnd()
  seed = (seed * 1103515245 + 12345) % 2147483648
  return seed / 2147483648
end
local function rnd2() return rnd() * 2 - 1 end

local function note(n) return 440 * 2 ^ ((n - 69) / 12) end

local function clamp(v, a, b) if v < a then return a elseif v > b then return b else return v end end

-- build a SoundData from a sample function fn(t, i, dur) -> mono sample in [-1,1]
local function gen(dur, fn)
  local n = math.max(1, math.floor(dur * RATE))
  local sd = love.sound.newSoundData(n, RATE, 16, 1)
  for i = 0, n - 1 do
    local t = i / RATE
    sd:setSample(i, clamp(fn(t, i, dur), -1, 1))
  end
  return sd
end

local function env(t, dur, a, d, s, r)
  a, d, s, r = a or 0.005, d or 0.05, s or 0.6, r or 0.1
  if t < a then return t / a end
  if t < a + d then return 1 - (1 - s) * (t - a) / d end
  local tail = dur - r
  if t > tail then return s * math.max(0, (dur - t) / math.max(0.0001, r)) end
  return s
end

-- ===== SFX definitions =====
local SFX = {}

SFX.click = function()
  return gen(0.06, function(t) return math.sin(2 * math.pi * 1200 * t) * math.exp(-t * 60) * 0.35 end)
end

SFX.hover = function()
  return gen(0.04, function(t) return math.sin(2 * math.pi * 1800 * t) * math.exp(-t * 90) * 0.14 end)
end

SFX.deal = function()
  return gen(0.14, function(t)
    local n = rnd2() * math.exp(-t * 34) * 0.30
    local tone = math.sin(2 * math.pi * 520 * t) * math.exp(-t * 24) * 0.16
    return n + tone
  end)
end

SFX.card_slide = function()
  return gen(0.18, function(t)
    local sweep = 400 + 1600 * (t / 0.18)
    return math.sin(2 * math.pi * sweep * t) * math.exp(-t * 16) * 0.20
  end)
end

SFX.win = function()
  local notes = { 72, 76, 79, 84 }
  return gen(0.75, function(t)
    local s = 0
    for i, nn in ipairs(notes) do
      local st = (i - 1) * 0.10
      if t >= st then
        local lt = t - st
        s = s + math.sin(2 * math.pi * note(nn) * lt) * math.exp(-lt * 5.5) * 0.20
      end
    end
    return s
  end)
end

SFX.lose = function()
  local notes = { 57, 53, 50 }
  return gen(0.85, function(t)
    local s = 0
    for i, nn in ipairs(notes) do
      local st = (i - 1) * 0.14
      if t >= st then
        local lt = t - st
        s = s + math.sin(2 * math.pi * note(nn) * lt) * math.exp(-lt * 3.2) * 0.22
        s = s + math.sin(2 * math.pi * note(nn - 12) * lt) * math.exp(-lt * 3.2) * 0.12
      end
    end
    return s
  end)
end

SFX.push = function()
  return gen(0.32, function(t)
    local f = 330 + 40 * math.sin(2 * math.pi * 6 * t)
    return math.sin(2 * math.pi * f * t) * math.exp(-t * 8) * 0.24
  end)
end

SFX.blackjack = function()
  local notes = { 79, 83, 86, 91, 95 }
  return gen(1.0, function(t)
    local s = 0
    for i, nn in ipairs(notes) do
      local st = (i - 1) * 0.07
      if t >= st then
        local lt = t - st
        s = s + math.sin(2 * math.pi * note(nn) * lt) * math.exp(-lt * 4.0) * 0.17
        s = s + math.sin(2 * math.pi * note(nn + 12) * lt) * math.exp(-lt * 7.0) * 0.07
      end
    end
    return s
  end)
end

SFX.sfx67 = function()
  return gen(1.1, function(t)
    local s = 0
    for i = 1, 7 do
      local st = (i - 1) * 0.08
      if t >= st then
        local lt = t - st
        s = s + math.sin(2 * math.pi * note(60 + i * 4) * lt) * math.exp(-lt * 5) * 0.16
      end
    end
    local shimmer = math.sin(2 * math.pi * 66 * t) * math.exp(-t * 2) * 0.10
    return s + shimmer
  end)
end

SFX.getout = function()
  return gen(1.3, function(t)
    local f = 300 * math.exp(-t * 1.4)
    local s = math.sin(2 * math.pi * f * t) * math.exp(-t * 2.4) * 0.30
    s = s + rnd2() * math.exp(-t * 8) * 0.06
    return s
  end)
end

SFX.accuse_ok = function()
  return gen(0.9, function(t)
    local st = math.sin(2 * math.pi * (300 + 900 * t) * t) * math.exp(-t * 4) * 0.24
    local bell = math.sin(2 * math.pi * 1046 * t) * math.exp(-t * 3) * 0.16
    local bell2 = math.sin(2 * math.pi * 1568 * t) * math.exp(-t * 4) * 0.10
    return st + bell + bell2
  end)
end

SFX.accuse_bad = function()
  return gen(0.7, function(t)
    local f = 220 * math.exp(-t * 0.8)
    local s = math.sin(2 * math.pi * f * t) * math.exp(-t * 3) * 0.28
    s = s + math.sin(2 * math.pi * (f * 1.5) * t) * math.exp(-t * 3.2) * 0.16
    return s
  end)
end

SFX.mark = function()
  return gen(0.22, function(t)
    local s = math.sin(2 * math.pi * 880 * t) * math.exp(-t * 22) * 0.20
    s = s + math.sin(2 * math.pi * 1760 * t) * math.exp(-t * 30) * 0.10
    return s
  end)
end

SFX.forge = function()
  return gen(0.75, function(t)
    local hammer = 0
    if t < 0.12 then hammer = rnd2() * math.exp(-t * 40) * 0.35 end
    if t > 0.24 and t < 0.36 then hammer = hammer + rnd2() * math.exp(-(t - 0.24) * 40) * 0.30 end
    local ring = math.sin(2 * math.pi * 740 * t) * math.exp(-t * 4) * 0.16
    return hammer + ring
  end)
end

SFX.chip = function()
  return gen(0.20, function(t)
    local s = 0
    for k = 1, 4 do
      s = s + math.sin(2 * math.pi * (1400 + k * 420) * t) * math.exp(-t * (26 + k * 6)) * 0.09
    end
    return s
  end)
end

SFX.error = function()
  return gen(0.24, function(t)
    local f = 160
    local g = math.floor(t * 40) % 2 == 0 and 1 or 0
    return math.sin(2 * math.pi * f * t) * g * math.exp(-t * 5) * 0.24
  end)
end

SFX.slash = function()
  return gen(0.45, function(t)
    local f = 2400 - 1900 * (t / 0.45)
    local s = math.sin(2 * math.pi * f * t) * math.exp(-t * 9) * 0.26
    s = s + rnd2() * math.exp(-t * 16) * 0.12
    return s
  end)
end

SFX.rod = function()
  return gen(0.8, function(t)
    local f = 500 + 300 * math.sin(2 * math.pi * 3.5 * t) - 260 * t
    return math.sin(2 * math.pi * f * t) * math.exp(-t * 2.4) * 0.22
  end)
end

SFX.explode = function()
  return gen(0.9, function(t)
    local s = rnd2() * math.exp(-t * 5.5) * 0.42
    s = s + math.sin(2 * math.pi * (80 - 40 * t) * t) * math.exp(-t * 3.5) * 0.34
    return s
  end)
end

SFX.drink = function()
  return gen(0.35, function(t)
    local s = rnd2() * math.exp(-t * 12) * 0.10
    s = s + math.sin(2 * math.pi * (420 + 120 * t) * t) * math.exp(-t * 9) * 0.10
    return s
  end)
end

SFX.gift = function()
  local notes = { 76, 81, 88 }
  return gen(0.7, function(t)
    local s = 0
    for i, nn in ipairs(notes) do
      local st = (i - 1) * 0.12
      if t >= st then
        local lt = t - st
        s = s + math.sin(2 * math.pi * note(nn) * lt) * math.exp(-lt * 5) * 0.18
      end
    end
    return s
  end)
end

SFX.stage = function()
  local notes = { 60, 64, 67, 72, 76 }
  return gen(1.2, function(t)
    local s = 0
    for i, nn in ipairs(notes) do
      local st = (i - 1) * 0.11
      if t >= st then
        local lt = t - st
        s = s + math.sin(2 * math.pi * note(nn) * lt) * math.exp(-lt * 3.4) * 0.15
      end
    end
    return s
  end)
end

SFX.buy = function()
  local notes = { 84, 88 }
  return gen(0.5, function(t)
    local s = 0
    for i, nn in ipairs(notes) do
      local st = (i - 1) * 0.09
      if t >= st then
        local lt = t - st
        s = s + math.sin(2 * math.pi * note(nn) * lt) * math.exp(-lt * 7) * 0.18
      end
    end
    return s
  end)
end

-- ===== BGM (procedural loops) =====
local BGM = {
  phase1 = { bpm = 92,  bars = 4, chords = { {48, 55, 60}, {50, 57, 62}, {45, 52, 57}, {43, 50, 55} }, bright = 0.5 },
  phase2 = { bpm = 104, bars = 4, chords = { {45, 52, 57}, {43, 50, 55}, {41, 48, 53}, {40, 47, 52} }, bright = 0.7 },
  phase3 = { bpm = 116, bars = 4, chords = { {43, 50, 55}, {41, 48, 53}, {38, 45, 50}, {36, 43, 48} }, bright = 0.9 },
  bar     = { bpm = 100, bars = 4, chords = { {51, 58, 62}, {53, 60, 65}, {48, 55, 60}, {50, 57, 62} }, bright = 0.6 },
}

local function buildBGM(name)
  local spec = BGM[name] or BGM.phase1
  local beat = 60 / spec.bpm
  local barDur = beat * 4
  local dur = barDur * spec.bars
  local stepDur = beat * 0.5
  local stepsPerBar = 8

  return gen(dur, function(t)
    local s = 0
    local bar = math.floor(t / barDur)
    local chord = spec.chords[(bar % #spec.chords) + 1]
    local tInBar = t - bar * barDur

    -- pad (three detuned sines, slow swell per bar)
    local padEnv = math.min(1, tInBar / (barDur * 0.35)) * math.min(1, (barDur - tInBar) / (barDur * 0.35))
    padEnv = clamp(padEnv, 0, 1)
    for ci, nn in ipairs(chord) do
      local f = note(nn)
      s = s + math.sin(2 * math.pi * f * t) * 0.035 * padEnv
      s = s + math.sin(2 * math.pi * f * 1.003 * t) * 0.028 * padEnv
    end

    -- bass pulse on each beat
    local beatIdx = math.floor(tInBar / beat)
    local tb = tInBar - beatIdx * beat
    local bassNote = chord[1] - 12
    s = s + math.sin(2 * math.pi * note(bassNote) * tb) * math.exp(-tb * 7) * 0.16
    s = s + math.sin(2 * math.pi * note(bassNote) * 2 * tb) * math.exp(-tb * 10) * 0.05

    -- arpeggio on off-beats
    local stepIdx = math.floor(tInBar / stepDur)
    local ts = tInBar - stepIdx * stepDur
    local degree = (stepIdx % 4)
    local arpNote = chord[(degree % #chord) + 1] + (degree >= 2 and 12 or 0) + 12
    s = s + math.sin(2 * math.pi * note(arpNote) * ts) * math.exp(-ts * 11) * 0.055 * spec.bright
    -- triangle-ish melody accent
    local a = note(arpNote + 4)
    local ph = (a * ts) % 1
    local tri = 4 * math.abs(ph - 0.5) - 1
    s = s + tri * math.exp(-ts * 13) * 0.028 * spec.bright

    -- soft noise hat on the half-beat
    local ht = (tInBar % (beat * 0.5))
    s = s + rnd2() * math.exp(-ht * 60) * 0.020
    -- kick
    local kb = (tInBar % beat)
    s = s + math.sin(2 * math.pi * (70 - 40 * kb) * kb) * math.exp(-kb * 16) * 0.13

    -- gentle global fade in/out of the loop ends to avoid clicks
    local fade = math.min(1, t / 0.05) * math.min(1, (dur - t) / 0.05)
    return s * fade * 0.9
  end)
end

-- ===== public API =====
function Audio.init(opts)
  opts = opts or {}
  volume = opts.volume or volume
  if not Audio.enabled then return end
  for name, fn in pairs(SFX) do
    if not sources[name] then
      local ok, sd = pcall(fn)
      if ok and sd then
        local src = love.audio.newSource(sd, "static")
        src:setVolume(1)
        sources[name] = src
      end
    end
  end
end

function Audio.setVolume(v)
  volume = clamp(v or 0, 0, 1)
  if bgmSource then bgmSource:setVolume(volume * Audio.bgmVolume) end
end
function Audio.getVolume() return volume end

function Audio.play(name)
  if not Audio.enabled then return end
  local src = sources[name]
  if not src then
    local fn = SFX[name]
    if not fn then return end
    local ok, sd = pcall(fn)
    if not ok or not sd then return end
    src = love.audio.newSource(sd, "static")
    sources[name] = src
  end
  local s = src:clone()
  s:setVolume(volume * Audio.sfxVolume)
  love.audio.play(s)
end

function Audio.setBGM(name)
  if bgmName == name then return end
  bgmName = name
  if bgmSource then bgmSource:stop(); bgmSource = nil end
  if not name or not Audio.enabled then return end
  local ok, sd = pcall(buildBGM, name)
  if not ok or not sd then return end
  bgmSource = love.audio.newSource(sd, "static")
  bgmSource:setLooping(true)
  bgmSource:setVolume(volume * Audio.bgmVolume)
  love.audio.play(bgmSource)
end

function Audio.stopBGM()
  if bgmSource then bgmSource:stop() end
  bgmSource = nil
  bgmName = nil
end

function Audio.currentBGM() return bgmName end

return Audio
