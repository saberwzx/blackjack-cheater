-- src/util.lua  Blackjack Cheater 通用工具
local U = {}

function U.shallow(t)
  local o = {}
  if t then for k, v in pairs(t) do o[k] = v end end
  return o
end

function U.deepcopy(t, seen)
  if type(t) ~= 'table' then return t end
  seen = seen or {}
  if seen[t] then return seen[t] end
  local o = {}
  seen[t] = o
  for k, v in pairs(t) do
    o[U.deepcopy(k, seen)] = U.deepcopy(v, seen)
  end
  return o
end

function U.clamp(v, lo, hi)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

function U.round(v)
  if v >= 0 then return math.floor(v + 0.5) end
  return math.ceil(v - 0.5)
end

function U.floorn(v)
  return math.floor(v)
end

function U.money(n)
  n = tonumber(n) or 0
  local neg = n < 0
  n = math.floor(math.abs(n))
  local s = tostring(n)
  local out = ''
  while #s > 3 do
    out = ',' .. string.sub(s, -3) .. out
    s = string.sub(s, 1, #s - 3)
  end
  out = s .. out
  if neg then return '-$' .. out end
  return '$' .. out
end

function U.indexOf(list, value)
  if not list then return nil end
  for i = 1, #list do
    if list[i] == value then return i end
  end
  return nil
end

function U.contains(list, value)
  return U.indexOf(list, value) ~= nil
end

function U.count(list, pred)
  local n = 0
  for i = 1, #(list or {}) do
    if not pred or pred(list[i], i) then n = n + 1 end
  end
  return n
end

function U.map(list, fn)
  local o = {}
  for i = 1, #(list or {}) do o[i] = fn(list[i], i) end
  return o
end

function U.filter(list, pred)
  local o = {}
  for i = 1, #(list or {}) do
    if pred(list[i], i) then o[#o + 1] = list[i] end
  end
  return o
end

function U.append(dst, src)
  for i = 1, #(src or {}) do dst[#dst + 1] = src[i] end
  return dst
end

function U.removeAt(list, index)
  if index and index >= 1 and index <= #list then
    return table.remove(list, index)
  end
  return nil
end

function U.sortedStringKeys(t)
  local keys = {}
  for k in pairs(t or {}) do keys[#keys + 1] = k end
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
  return keys
end

function U.isFiniteNumber(v)
  return type(v) == 'number' and v == v and v ~= math.huge and v ~= -math.huge
end

-- 稳定序列化：数字键升序 + 字符串键排序
function U.serialize(value, indent)
  indent = indent or ''
  local t = type(value)
  if t == 'nil' then return 'nil'
  elseif t == 'boolean' then return value and 'true' or 'false'
  elseif t == 'number' then
    if value ~= value then return '0' end
    if value == math.huge then return 'math.huge' end
    if value == -math.huge then return '-math.huge' end
    if value == math.floor(value) then return string.format('%d', value) end
    return string.format('%.10g', value)
  elseif t == 'string' then
    return string.format('%q', value)
  elseif t == 'table' then
    local next = indent .. '  '
    local numeric = {}
    local stringy = {}
    local others = {}
    for k in pairs(value) do
      if type(k) == 'number' then numeric[#numeric + 1] = k
      elseif type(k) == 'string' then stringy[#stringy + 1] = k
      else others[#others + 1] = k end
    end
    table.sort(numeric)
    table.sort(stringy)
    local parts = {}
    for _, k in ipairs(numeric) do
      parts[#parts + 1] = next .. '[' .. string.format('%d', k) .. ']=' .. U.serialize(value[k], next)
    end
    for _, k in ipairs(stringy) do
      parts[#parts + 1] = next .. '[' .. string.format('%q', k) .. ']=' .. U.serialize(value[k], next)
    end
    for _, k in ipairs(others) do
      parts[#parts + 1] = next .. '[' .. tostring(k) .. ']=' .. U.serialize(value[k], next)
    end
    if #parts == 0 then return '{}' end
    return '{' .. table.concat(parts, ',') .. '}'
  end
  return 'nil'
end

-- 空环境沙箱反序列化；失败返回 nil
function U.deserialize(text)
  if type(text) ~= 'string' then return nil end
  local loader = loadstring or load
  if not loader then return nil end
  local chunk = loader('return ' .. text, 'save')
  if not chunk then return nil end
  if setfenv then
    setfenv(chunk, {})
  end
  local ok, result = pcall(chunk)
  if not ok then return nil end
  if type(result) ~= 'table' then return nil end
  return result
end

function U.formatTime(sec)
  sec = math.max(0, math.floor(sec or 0))
  local m = math.floor(sec / 60)
  local s = sec % 60
  return string.format('%02d:%02d', m, s)
end

return U
