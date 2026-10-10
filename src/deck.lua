-- src/deck.lua 守恒牌堆（真审计：UID 唯一 + 合成牌计账 + 外部持有）
local Deck = {}
Deck.__index = Deck

local uidCounter = 0

function Deck.nextUid()
  uidCounter = uidCounter + 1
  return uidCounter
end

function Deck.peekUidCounter() return uidCounter end
function Deck.resetUidCounter() uidCounter = 0 end

function Deck.new(opts)
  opts = opts or {}
  local self = setmetatable({}, Deck)
  self.drawPile = {}
  self.discardPile = {}
  self.removed = {}
  self.syntheticCreated = 0
  self.syntheticCount = 0
  self.shuffleCount = 0
  self.removedDecks = 0
  self.initialTotal = 0
  self.label = opts.label or ''
  self.collections = {}
  self.rng = opts.rng
  self.pendingShoe = nil
  return self
end

function Deck:setRng(rng) self.rng = rng end

function Deck:assignUid(card)
  if not card then return card end
  if not card.uid then card.uid = Deck.nextUid() end
  if card.is_synthetic and not card._synthCounted then
    card._synthCounted = true
    self.syntheticCreated = self.syntheticCreated + 1
  end
  return card
end

function Deck:addCards(cards, label)
  local n = 0
  for i = 1, #(cards or {}) do
    local c = cards[i]
    self:assignUid(c)
    self.drawPile[#self.drawPile + 1] = c
    if not c.is_synthetic then self.initialTotal = self.initialTotal + 1 end
    n = n + 1
  end
  if label and n > 0 then
    self.collections[#self.collections + 1] = { label = label, count = n }
  end
  self:shuffle()
  return n
end

function Deck:shuffle()
  local rng = self.rng
  local n = #self.drawPile
  for i = n, 2, -1 do
    local j
    if rng then j = rng(1, i) else j = math.random(1, i) end
    j = math.floor(j)
    if j < 1 then j = 1 elseif j > i then j = i end
    self.drawPile[i], self.drawPile[j] = self.drawPile[j], self.drawPile[i]
  end
  return self
end

function Deck:draw()
  if #self.drawPile == 0 then
    if #self.discardPile == 0 then return nil end
    self:shuffleDiscardIn()
  end
  return table.remove(self.drawPile, 1)
end

function Deck:drawWhere(pred)
  for i = 1, #self.drawPile do
    if pred(self.drawPile[i]) then
      return table.remove(self.drawPile, i)
    end
  end
  return nil
end

function Deck:toDiscard(card)
  if not card then return end
  self:assignUid(card)
  if card.is_synthetic and not card._collected then
    card._collected = true
    self.syntheticCount = self.syntheticCount + 1
  end
  self.discardPile[#self.discardPile + 1] = card
end

function Deck:toRemoved(card)
  if not card then return end
  self:assignUid(card)
  if card.is_synthetic and not card._collected then
    card._collected = true
    self.syntheticCount = self.syntheticCount + 1
  end
  self.removed[#self.removed + 1] = card
end

function Deck:shuffleDiscardIn()
  for i = 1, #self.discardPile do
    self.drawPile[#self.drawPile + 1] = self.discardPile[i]
  end
  self.discardPile = {}
  self.shuffleCount = self.shuffleCount + 1
  self:shuffle()
end

function Deck:allCards()
  local all = {}
  for i = 1, #self.drawPile do all[#all + 1] = self.drawPile[i] end
  for i = 1, #self.discardPile do all[#all + 1] = self.discardPile[i] end
  for i = 1, #self.removed do all[#all + 1] = self.removed[i] end
  return all
end

function Deck:findByUid(uid)
  if not uid then return nil end
  local function search(list)
    for i = 1, #list do
      if list[i].uid == uid then return list[i], i end
    end
    return nil
  end
  local c, i = search(self.drawPile); if c then return c, 'draw', i end
  c, i = search(self.discardPile); if c then return c, 'discard', i end
  c, i = search(self.removed); if c then return c, 'removed', i end
  return nil
end

function Deck:peek(n)
  local out = {}
  for i = 1, math.min(n or 1, #self.drawPile) do out[i] = self.drawPile[i] end
  return out
end

function Deck:removeFromDraw(card)
  if not card then return false end
  for i = 1, #self.drawPile do
    if self.drawPile[i] == card or (card.uid and self.drawPile[i].uid == card.uid) then
      table.remove(self.drawPile, i)
      return true
    end
  end
  return false
end

function Deck:addToDraw(card, pos)
  if not card then return false end
  self:assignUid(card)
  if pos == 'bottom' then
    self.drawPile[#self.drawPile + 1] = card
  elseif type(pos) == 'number' and pos >= 1 and pos <= #self.drawPile + 1 then
    table.insert(self.drawPile, pos, card)
  else
    table.insert(self.drawPile, 1, card)
  end
  return true
end

function Deck:cut(k)
  local n = #self.drawPile
  if n <= 1 then return end
  k = k or math.floor(n / 3)
  k = ((k - 1) % n) + 1
  local tmp = {}
  for i = k, n do tmp[#tmp + 1] = self.drawPile[i] end
  for i = 1, k - 1 do tmp[#tmp + 1] = self.drawPile[i] end
  self.drawPile = tmp
end

-- 真审计：UID 唯一、无缺 UID、总数 = initialTotal + syntheticCreated
function Deck:audit(external)
  local seen, dup, missing = {}, {}, {}
  local total = 0
  local function scan(list, zone)
    for i = 1, #list do
      local c = list[i]
      total = total + 1
      if not c.uid then
        missing[#missing + 1] = { zone = zone, index = i }
      elseif seen[c.uid] then
        dup[#dup + 1] = { uid = c.uid, zone = zone, index = i }
      else
        seen[c.uid] = zone
      end
    end
  end
  scan(self.drawPile, 'draw')
  scan(self.discardPile, 'discard')
  scan(self.removed, 'removed')
  local ext = 0
  for i = 1, #(external or {}) do
    local c = external[i]
    if c then
      ext = ext + 1
      total = total + 1
      if not c.uid then
        missing[#missing + 1] = { zone = 'external', index = i }
      elseif seen[c.uid] then
        dup[#dup + 1] = { uid = c.uid, zone = 'external', index = i }
      else
        seen[c.uid] = 'external'
      end
    end
  end
  local expected = self.initialTotal + self.syntheticCreated
  return {
    total = total,
    external = ext,
    expected = expected,
    initialTotal = self.initialTotal,
    syntheticCreated = self.syntheticCreated,
    syntheticRecycled = self.syntheticCount,
    duplicates = dup,
    missingUid = missing,
    ok = (#dup == 0 and #missing == 0 and total == expected),
  }
end

function Deck:auditTotal()
  return #self.drawPile + #self.discardPile + #self.removed
end

function Deck:auditOk(external)
  return self:audit(external).ok
end

return Deck
