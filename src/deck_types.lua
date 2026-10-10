-- src/deck_types.lua 12 种特殊牌组 + 固有牌堆 + 冠军牌池
local DeckTypes = {}

local SUITS = { 'S', 'H', 'D', 'C' }
local RANKS = { 'A', '2', '3', '4', '5', '6', '7', '8', '9', '10', 'J', 'Q', 'K' }
local DEC_VALUES = { 0.5, 1.5, 2.5, 3.5, 4.5, 5.5, 6.5, 7.5, 8.5, 9.5, 10.5 }
local NEG_VALUES = { -1, -2, -3, -4, -5, -6, -7, -8, -9, -10 }
local MUL_RANKS = { '1', '2', '3', '4', '5', '6', '7', '8', '9', '10' }
local RPS_SYMBOLS = { 'rock', 'paper', 'scissors' }

local SIZE_COUNT = { small = 6, medium = 12, large = 18 }

DeckTypes.SUITS = SUITS
DeckTypes.RANKS = RANKS

function DeckTypes.label(c)
  if c.kind == 'rps' then return c.rps_symbol or 'rps' end
  if c.kind == 'dice6' then return 'D6' end
  if c.kind == 'dice20' then return 'D20' end
  if c.kind == 'decimal' or c.kind == 'negative' then return tostring(c.rank) .. tostring(c.suit or '') end
  return tostring(c.rank or '?') .. tostring(c.suit or '')
end

function DeckTypes.mk(o)
  local c = {}
  for k, v in pairs(o) do c[k] = v end
  c.label = c.label or DeckTypes.label(c)
  return c
end

function DeckTypes.clone(c)
  local o = {}
  for k, v in pairs(c) do o[k] = v end
  o.uid = nil
  o.marked = nil
  o.revealed = nil
  o._collected = nil
  return o
end

function DeckTypes.standard52()
  local out = {}
  for si = 1, #SUITS do
    for ri = 1, #RANKS do
      out[#out + 1] = DeckTypes.mk({ rank = RANKS[ri], suit = SUITS[si], kind = 'basic', is_basic = true })
    end
  end
  return out
end

local function decimalRoster()
  local out = {}
  for si = 1, #SUITS do
    for vi = 1, #DEC_VALUES do
      local v = DEC_VALUES[vi]
      out[#out + 1] = DeckTypes.mk({ rank = tostring(v), suit = SUITS[si], value = v, kind = 'decimal' })
    end
  end
  return out
end

local function negativeRoster()
  local out = {}
  for si = 1, #SUITS do
    for vi = 1, #NEG_VALUES do
      local v = NEG_VALUES[vi]
      out[#out + 1] = DeckTypes.mk({ rank = tostring(v), suit = SUITS[si], value = v, kind = 'negative' })
    end
  end
  return out
end

local function multiplierRoster()
  local out = {}
  for si = 1, #SUITS do
    for ri = 1, #MUL_RANKS do
      out[#out + 1] = DeckTypes.mk({ rank = MUL_RANKS[ri], suit = SUITS[si], kind = 'multiplier', mult_bonus = 0.5 })
    end
  end
  return out
end

local function s67Roster()
  local out = {}
  for si = 1, #SUITS do
    for _, r in ipairs({ '6', '7' }) do
      out[#out + 1] = DeckTypes.mk({ rank = r, suit = SUITS[si], kind = 's67', is_67 = true, s67_rank = r })
    end
  end
  return out
end

local function rpsRoster()
  local out = {}
  for i = 1, #RPS_SYMBOLS do
    out[#out + 1] = DeckTypes.mk({ rank = RPS_SYMBOLS[i], suit = '', value = 0, kind = 'rps', is_rps = true, rps_symbol = RPS_SYMBOLS[i] })
  end
  return out
end

local function flagRoster(kind, flags)
  local base = DeckTypes.standard52()
  for i = 1, #base do
    base[i].kind = kind
    for k, v in pairs(flags) do base[i][k] = v end
  end
  return base
end

local ROSTERS = {}
function DeckTypes.roster(key)
  if ROSTERS[key] then return ROSTERS[key] end
  local out
  if key == 'basic' or key == 'champion' then out = DeckTypes.standard52()
  elseif key == 'decimal' then out = decimalRoster()
  elseif key == 'negative' then out = negativeRoster()
  elseif key == 'multiplier' then out = multiplierRoster()
  elseif key == 's67' then out = s67Roster()
  elseif key == 'rps' then out = rpsRoster()
  elseif key == 'blackhole' then out = flagRoster('blackhole', { is_blackhole = true })
  elseif key == 'cage' then out = flagRoster('cage', { is_cage = true })
  elseif key == 'chip' then out = flagRoster('chip', { is_chip = true })
  elseif key == 'dice6' then out = { DeckTypes.mk({ rank = '', suit = '', kind = 'dice6' }) }
  elseif key == 'dice20' then out = { DeckTypes.mk({ rank = '', suit = '', kind = 'dice20' }) }
  elseif key == 'remove' then out = {}
  else out = {} end
  ROSTERS[key] = out
  return out
end

function DeckTypes.info(key)
  local T = {
    basic = { name = '固有牌堆', color = 'white' },
    decimal = { name = '小数牌组', color = 'green' },
    negative = { name = '负整数牌组', color = 'red' },
    multiplier = { name = '倍率牌组', color = 'gold' },
    s67 = { name = '67 卡组', color = 'purple' },
    rps = { name = '石头剪刀布牌组', color = 'skyblue' },
    remove = { name = '删除牌组', color = 'gray' },
    blackhole = { name = '黑洞牌组', color = 'black', rarity = 'legendary' },
    cage = { name = '牢笼牌组', color = 'iron', rarity = 'legendary' },
    chip = { name = '筹码牌组', color = 'redblack', rarity = 'rare' },
    dice6 = { name = '六面骰子牌组', color = 'ivory', rarity = 'rare' },
    dice20 = { name = '二十面骰子牌组', color = 'jade', rarity = 'rare' },
    champion = { name = '冠军牌组', color = 'gold' },
  }
  return T[key] or { name = tostring(key), color = 'gray' }
end

function DeckTypes.sizeCount(size)
  return SIZE_COUNT[size] or 6
end

function DeckTypes.generate(key, size, opts)
  opts = opts or {}
  if key == 'remove' then return {} end
  if key == 'champion' then
    local cards = opts.championCards
    if not cards or #cards == 0 then return {} end
    local copies = ({ small = 1, medium = 2, large = 3 })[size] or 1
    local out = {}
    for n = 1, copies do
      for i = 1, #cards do out[#out + 1] = DeckTypes.clone(cards[i]) end
    end
    return out
  end
  local roster = DeckTypes.roster(key)
  if #roster == 0 then return {} end
  local n = SIZE_COUNT[size] or 6
  local out = {}
  for i = 1, n do
    local src = roster[((i - 1) % #roster) + 1]
    out[i] = DeckTypes.clone(src)
  end
  return out
end

function DeckTypes.price(key, size, stage)
  if key == 'champion' then return 21 end
  local base
  if key == 'dice6' then base = 600
  elseif key == 'dice20' then base = 200
  else base = ({ small = 900, medium = 1800, large = 3600 })[size or 'small'] or 900 end
  local mult = ({ 1.0, 1.5, 2.0 })[stage or 1] or 1.0
  return math.floor(base * mult)
end

function DeckTypes.removedDecks(key, size)
  if key ~= 'remove' then return 0 end
  return ({ small = 1, medium = 2, large = 3 })[size or 'small'] or 1
end

DeckTypes.ORDER = { 'decimal', 'negative', 'multiplier', 's67', 'rps', 'remove', 'blackhole', 'cage', 'chip', 'dice6', 'dice20', 'champion' }

-- 冠军牌池：按附录 C4 明确分项，共 345 个牌面（GDD 宣称 290，见 docs/core-gaps.md）
function DeckTypes.championGroups()
  return {
    { key = 'basic', name = '固有牌堆', cards = DeckTypes.standard52() },
    { key = 'decimal', name = '小数牌组', cards = decimalRoster() },
    { key = 'negative', name = '负整数牌组', cards = negativeRoster() },
    { key = 'multiplier', name = '倍率牌组', cards = multiplierRoster() },
    { key = 's67', name = '67 卡组', cards = s67Roster() },
    { key = 'rps', name = 'RPS 牌组', cards = rpsRoster() },
    { key = 'blackhole', name = '黑洞牌组', cards = flagRoster('blackhole', { is_blackhole = true }) },
    { key = 'cage', name = '牢笼牌组', cards = flagRoster('cage', { is_cage = true }) },
    { key = 'chip', name = '筹码牌组', cards = flagRoster('chip', { is_chip = true }) },
    { key = 'dice6', name = '六面骰子牌组', cards = { DeckTypes.mk({ rank = '', suit = '', kind = 'dice6' }) } },
    { key = 'dice20', name = '二十面骰子牌组', cards = { DeckTypes.mk({ rank = '', suit = '', kind = 'dice20' }) } },
  }
end

function DeckTypes.championPool()
  local out = {}
  local groups = DeckTypes.championGroups()
  for gi = 1, #groups do
    for ci = 1, #groups[gi].cards do
      out[#out + 1] = { group = groups[gi].key, groupName = groups[gi].name, card = DeckTypes.clone(groups[gi].cards[ci]) }
    end
  end
  return out
end

function DeckTypes.championPoolSize()
  local n = 0
  local groups = DeckTypes.championGroups()
  for gi = 1, #groups do n = n + #groups[gi].cards end
  return n
end

-- UI 用：按组折叠
function DeckTypes.championGroupCounts()
  local groups = DeckTypes.championGroups()
  local out = {}
  for gi = 1, #groups do out[#out + 1] = { key = groups[gi].key, name = groups[gi].name, count = #groups[gi].cards } end
  return out
end

function DeckTypes.cardSpec(n)
  -- 生成一张普通牌（用于给牌 / 出千），n 为点数
  return DeckTypes.mk({ rank = tostring(n), suit = SUITS[1], kind = 'synthetic', is_synthetic = true })
end

return DeckTypes
