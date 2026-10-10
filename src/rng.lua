-- src/rng.lua 随机源封装：默认 love.math.random，可注入 stub
local Rng = {}

local function loveRandom(a, b)
  if a == nil then
    if love and love.math and love.math.random then return love.math.random() end
    return math.random()
  end
  if love and love.math and love.math.random then return love.math.random(a, b) end
  return math.random(a, b)
end

function Rng.wrap(fn)
  return fn or loveRandom
end

-- 返回 [0,1) 浮点
function Rng.float(rng)
  rng = rng or loveRandom
  local v = rng()
  if type(v) ~= 'number' then v = 0 end
  if v >= 1 then v = 0.9999999 end
  if v < 0 then v = 0 end
  return v
end

-- 返回 [a,b] 整数
function Rng.int(rng, a, b)
  rng = rng or loveRandom
  a = math.floor(a or 1)
  b = math.floor(b or a)
  if b < a then a, b = b, a end
  if a == b then return a end
  local v = rng(a, b)
  if type(v) ~= 'number' then return a end
  v = math.floor(v)
  if v < a then v = a end
  if v > b then v = b end
  return v
end

function Rng.chance(rng, p)
  if not p or p <= 0 then return false end
  if p >= 1 then return true end
  return Rng.float(rng) < p
end

function Rng.pick(rng, list)
  local n = #(list or {})
  if n == 0 then return nil end
  return list[Rng.int(rng, 1, n)]
end

function Rng.shuffle(rng, list)
  local n = #list
  for i = n, 2, -1 do
    local j = Rng.int(rng, 1, i)
    list[i], list[j] = list[j], list[i]
  end
  return list
end

-- entries = { {value=..., weight=n}, ... }  返回 value
function Rng.weighted(rng, entries)
  local total = 0
  for i = 1, #entries do total = total + (entries[i].weight or 0) end
  if total <= 0 then return nil end
  local roll = Rng.float(rng) * total
  local acc = 0
  for i = 1, #entries do
    acc = acc + (entries[i].weight or 0)
    if roll < acc then return entries[i].value end
  end
  return entries[#entries].value
end

return Rng
