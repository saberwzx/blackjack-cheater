-- src/persist.lua 存档（progress.lua + collection.lua；GDD §19.1）
-- 纯 Lua 序列化；空环境沙箱反序列化；字段全量消毒；读写失败静默降级；绝不每帧写盘。
local U = require('src.util')
local P = {}

P.DIR = 'saves21'
P.IDENTITY = 'blackjack-cheater'
P.PROGRESS = 'progress.lua'
P.COLLECTION = 'collection.lua'
P.VERSION = 1

P.META_FIELDS = {
  'hardCleared', 'hardClearCount', 'maxStage', 'maxChips',
  'totalRuns', 'bestRoundsBasic', 'bestRoundsHard',
}
P.SETTING_DEFAULTS = {
  volume = 0.8, resolution = '1280x720', fullscreen = false, autoEndOnBroke = true,
}

-- 牌面字段白名单（冠军牌组持久化）
P.CARD_FIELDS = {
  'rank', 'suit', 'kind', 'label', 'value',
  'is_67', 's67_rank', 'is_rps', 'rps_symbol',
  'is_blackhole', 'is_cage', 'is_chip', 'mult_bonus',
  'is_basic', 'is_synthetic',
}

function P.defaultProgress()
  local meta = {}
  for _, k in ipairs(P.META_FIELDS) do meta[k] = nil end
  meta.hardCleared = false
  meta.hardClearCount = 0
  meta.maxStage = 0
  meta.maxChips = 0
  meta.totalRuns = 0
  meta.bestRoundsBasic = 0
  meta.bestRoundsHard = 0
  local settings = {}
  for k, v in pairs(P.SETTING_DEFAULTS) do settings[k] = v end
  return { version = P.VERSION, meta = meta, settings = settings }
end

function P.new(opts)
  opts = opts or {}
  local fsad = opts.fs
  if fsad == nil and love and love.filesystem then fsad = love.filesystem end
  local self = setmetatable({
    fs = fsad,
    dir = opts.dir or P.DIR,
    identity = opts.identity or P.IDENTITY,
    enabled = fsad ~= nil,
    writes = 0,
  }, { __index = P })
  if self.fs and self.fs.setIdentity then pcall(self.fs.setIdentity, self.identity) end
  return self
end

function P:path(name)
  if not self.dir or self.dir == '' then return name end
  return self.dir .. '/' .. name
end

function P:writeRaw(name, text)
  if not self.fs then return false end
  local ok, res = pcall(function() return self.fs.write(self:path(name), text) end)
  if not ok then return false end
  -- love.filesystem.write 返回 (success, message)；false 必须判失败。
  -- 兼容只返回一次成功的实现：nil 视为未声明结果（成功）。
  if res == false then return false end
  self.writes = self.writes + 1
  return true
end

function P:readRaw(name)
  if not self.fs then return nil end
  local ok, data = pcall(function() return self.fs.read(self:path(name)) end)
  if not ok then return nil end
  return data
end

function P:exists(name)
  if not self.fs then return false end
  if self.fs.getInfo then
    local ok, info = pcall(function() return self.fs.getInfo(self:path(name)) end)
    return ok and info ~= nil
  end
  return self:readRaw(name) ~= nil
end

local function num(v, default, lo, hi)
  v = tonumber(v)
  if v == nil or v ~= v or v == math.huge or v == -math.huge then return default end
  if lo and v < lo then v = lo end
  if hi and v > hi then v = hi end
  return v
end

function P.sanitizeProgress(t)
  local out = P.defaultProgress()
  if type(t) ~= 'table' then return out end
  local meta = t.meta
  if type(meta) == 'table' then
    out.meta.hardCleared = meta.hardCleared == true
    out.meta.hardClearCount = math.floor(num(meta.hardClearCount, 0, 0, 1e9)) or 0
    out.meta.maxStage = math.floor(num(meta.maxStage, 0, 0, 3)) or 0
    out.meta.maxChips = math.floor(num(meta.maxChips, 0, 0, 1e15)) or 0
    out.meta.totalRuns = math.floor(num(meta.totalRuns, 0, 0, 1e9)) or 0
    out.meta.bestRoundsBasic = math.floor(num(meta.bestRoundsBasic, 0, 0, 1e9)) or 0
    out.meta.bestRoundsHard = math.floor(num(meta.bestRoundsHard, 0, 0, 1e9)) or 0
  end
  local s = t.settings
  if type(s) == 'table' then
    out.settings.volume = num(s.volume, 0.8, 0, 1)
    if type(s.resolution) == 'string' and #s.resolution <= 20 then out.settings.resolution = s.resolution end
    out.settings.fullscreen = s.fullscreen == true
    -- 统一映射：autoEndOnBroke 为准，bankruptAutoEnd 为旧别名
    local auto = s.autoEndOnBroke
    if auto == nil then auto = s.bankruptAutoEnd end
    out.settings.autoEndOnBroke = auto ~= false
  end
  return out
end

function P.sanitizeCollection(t)
  local out = { version = P.VERSION, cards = {}, savedAt = 0, size = 'small' }
  if type(t) ~= 'table' then return out end
  out.savedAt = math.floor(num(t.savedAt, 0, 0, 1e15)) or 0
  if t.size == 'small' or t.size == 'medium' or t.size == 'large' then out.size = t.size end
  local cards = t.cards
  if type(cards) == 'table' then
    for i = 1, #cards do
      local c = cards[i]
      if type(c) == 'table' then
        local nc = {}
        for _, f in ipairs(P.CARD_FIELDS) do
          local v = c[f]
          local tv = type(v)
          if tv == 'string' then nc[f] = v
          elseif tv == 'number' then
            if v == v and v ~= math.huge and v ~= -math.huge then nc[f] = v end
          elseif tv == 'boolean' then nc[f] = v end
        end
        if nc.rank ~= nil or nc.kind ~= nil then out.cards[#out.cards + 1] = nc end
      end
    end
  end
  return out
end

function P:writeProgress(prog)
  return self:writeRaw(P.PROGRESS, U.serialize(P.sanitizeProgress(prog)))
end

function P:readProgress()
  local raw = self:readRaw(P.PROGRESS)
  if not raw then return P.defaultProgress(), false end
  local data = U.deserialize(raw)
  if not data then return P.defaultProgress(), false end
  return P.sanitizeProgress(data), true
end

function P:writeCollection(col)
  return self:writeRaw(P.COLLECTION, U.serialize(P.sanitizeCollection(col)))
end

function P:readCollection()
  local raw = self:readRaw(P.COLLECTION)
  if not raw then return P.sanitizeCollection(nil), false end
  local data = U.deserialize(raw)
  if not data then return P.sanitizeCollection(nil), false end
  return P.sanitizeCollection(data), true
end

function P:resetProgress()
  return self:writeProgress(P.defaultProgress())
end

function P:resetCollection()
  return self:writeCollection(P.sanitizeCollection(nil))
end

return P
