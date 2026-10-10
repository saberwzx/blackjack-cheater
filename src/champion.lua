-- src/champion.lua 冠军牌组（GDD §18）
-- 困难通关解锁；恰 36 张才能保存/上架；牌池 = 附录 C4（本项目按明确分项 345）。
local D = require('src.deck_types')
local C = {}

C.SIZE = 36
C.PRICE = 21
C.EXPAND = { small = 1, medium = 2, large = 3 }

function C.groups() return D.championGroups() end
function C.poolSize() return D.championPoolSize() end
function C.required() return C.SIZE end
function C.price() return C.PRICE end

function C.validate(cards)
  local n = 0
  if type(cards) == 'table' then n = #cards end
  return n == C.SIZE, n
end

function C.canEdit(progress)
  if not progress then return false end
  local meta = progress.meta or progress
  return meta.hardCleared == true
end

function C.randomPick(cards, rng, n)
  local pool = {}
  for i = 1, #(cards or {}) do pool[i] = cards[i] end
  if #pool == 0 then return {} end
  local Rng = require('src.rng')
  for i = #pool, 2, -1 do
    local j = Rng.int(rng, 1, i)
    pool[i], pool[j] = pool[j], pool[i]
  end
  local out = {}
  for i = 1, math.min(n or C.SIZE, #pool) do out[i] = pool[i] end
  return out
end

-- 尺寸展开：小 36 / 中 72 / 大 108
function C.expand(cards, size)
  local copies = C.EXPAND[size or 'small'] or 1
  local out = {}
  for n = 1, copies do
    for i = 1, #(cards or {}) do out[#out + 1] = D.clone(cards[i]) end
  end
  return out
end

function C.countByGroup(cards)
  local counts = {}
  for i = 1, #(cards or {}) do
    local g = cards[i].group or cards[i].kind or 'unknown'
    counts[g] = (counts[g] or 0) + 1
  end
  return counts
end

function C.save(persist, cards)
  if not persist then return false end
  local ok = C.validate(cards)
  if not ok then return false end
  return persist:writeCollection({ version = 1, cards = cards, savedAt = os.time and os.time() or 0, size = 'small' })
end

function C.load(persist)
  if not persist then return {} end
  local col = persist:readCollection()
  return col.cards or {}, col
end

return C
