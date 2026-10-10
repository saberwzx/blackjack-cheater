-- src/marks.lua 墨水标记 + 5 种特种标记
local M = {}

M.INK_PRICE = { 50, 200, 1000 }
M.FIND_CHANCE = 0.02
M.BASE_LIMIT = 5

M.SPECIAL = {
  mark_vanish = { id = 'mark_vanish', name = '消失标记', color = 'gray', price = 1000, order = 1,
    desc = '这张牌被你要到时如同不存在般消失，你转而摸下一张（最多连锁跳过 3 次）。' },
  mark_bomb = { id = 'mark_bomb', name = '爆炸标记', color = 'red', price = 3000, order = 2,
    desc = '这张牌被任何人摸到时，炸掉其后 2 张牌（移入弃牌堆）。' },
  mark_flame = { id = 'mark_flame', name = '火焰标记', color = 'gold', price = 1500, order = 3,
    desc = '庄家无法要这张牌；庄家的下一张若是火焰牌只能停牌。' },
  mark_void = { id = 'mark_void', name = '虚空标记', color = 'purple', price = 2500, order = 4,
    desc = '标记的瞬间立刻吸收它前面那张牌及其全部词条。' },
  mark_bounty = { id = 'mark_bounty', name = '赏金标记', color = 'green', price = 2000, order = 5,
    desc = '庄家要这张牌时你立刻获得 $500 赏金。' },
}

M.SPECIAL_ORDER = { 'mark_vanish', 'mark_bomb', 'mark_flame', 'mark_void', 'mark_bounty' }

function M.inkPrice(stage, inkThief)
  local p = M.INK_PRICE[stage or 1] or 50
  if inkThief then p = math.floor(p * 0.5) end
  return p
end

function M.baseLimit()
  return M.BASE_LIMIT
end

function M.limitWith(consort)
  if consort then return M.BASE_LIMIT + 2 end
  return M.BASE_LIMIT
end

function M.newInk(card, opts)
  opts = opts or {}
  card.marked = {
    ink = true,
    markId = 'ink',
    by = opts.by or 'player',
    price = opts.price or 0,
    stage = opts.stage,
    revealed = opts.reveal and true or nil,
  }
  if opts.reveal then card.revealed = true end
  return card.marked
end

function M.newSpecial(card, id, opts)
  opts = opts or {}
  local d = M.SPECIAL[id]
  if not d then return nil end
  card.marked = {
    ink = false,
    markId = id,
    by = opts.by or 'player',
    special = true,
    order = d.order,
  }
  return card.marked
end

function M.remove(card)
  if card then card.marked = nil end
end

function M.isMarked(card)
  return card ~= nil and card.marked ~= nil
end

function M.isInk(card)
  return card ~= nil and card.marked ~= nil and card.marked.ink == true
end

function M.countInk(state)
  local n = 0
  local deck = state.deck
  if not deck then return 0 end
  local function scan(list)
    for i = 1, #list do if M.isInk(list[i]) then n = n + 1 end end
  end
  scan(deck.drawPile); scan(deck.discardPile); scan(deck.removed)
  if state.player and state.player.hand then scan(state.player.hand) end
  if state.dealer and state.dealer.hand then scan(state.dealer.hand) end
  return n
end

function M.findInk(state)
  local out = {}
  local deck = state.deck
  if not deck then return out end
  local function scan(list, zone)
    for i = 1, #list do
      if M.isInk(list[i]) then out[#out + 1] = { card = list[i], zone = zone, index = i } end
    end
  end
  scan(deck.drawPile, 'draw'); scan(deck.discardPile, 'discard'); scan(deck.removed, 'removed')
  if state.player and state.player.hand then scan(state.player.hand, 'player') end
  if state.dealer and state.dealer.hand then scan(state.dealer.hand, 'dealer') end
  return out
end

-- 发现判定只针对庄家已摊开的墨水标记牌；返回 {count, penalty, cards}
function M.rollDiscovery(state, rng, opts)
  opts = opts or {}
  if opts.suppressed then return { count = 0, penalty = 0, cards = {} } end
  local dealerHand = state.dealer and state.dealer.hand or {}
  local candidates = {}
  for i = 1, #dealerHand do
    local c = dealerHand[i]
    if M.isInk(c) then candidates[#candidates + 1] = c end
  end
  if #candidates == 0 then return { count = 0, penalty = 0, cards = {} } end
  local roll = rng and rng() or math.random()
  if roll >= M.FIND_CHANCE then return { count = 0, penalty = 0, cards = {} } end
  local card = candidates[1]
  if rng then
    local idx = math.floor(rng(1, #candidates))
    if idx < 1 then idx = 1 elseif idx > #candidates then idx = #candidates end
    card = candidates[idx]
  end
  local penalty = math.floor((state.bet or 0) * 3)
  local half = false
  if opts.sharpFamily then
    penalty = math.floor(penalty * 0.5)
    half = true
  end
  local keep = false
  if opts.sharpFamily and rng then
    keep = rng() < 0.5
  end
  return { count = 1, penalty = penalty, cards = { card }, card = card, keep = keep, half = half }
end

function M.gainSpecial(state, id)
  local d = M.SPECIAL[id]
  if not d then return false end
  state.specialMarks = state.specialMarks or {}
  state.specialMarks.held = {
    id = d.id, name = d.name, color = d.color, price = d.price,
    usesLeft = 3, forged = false, order = d.order,
  }
  return true
end

function M.specialUsesLeft(state)
  local h = state.specialMarks and state.specialMarks.held
  if not h then return 0 end
  return h.usesLeft or 0
end

function M.consumeSpecial(state)
  local h = state.specialMarks and state.specialMarks.held
  if not h then return false end
  if h.forged then return true end
  h.usesLeft = (h.usesLeft or 0) - 1
  if h.usesLeft <= 0 then state.specialMarks.held = nil end
  return true
end

function M.clearAll(state)
  local deck = state.deck
  if not deck then return end
  local function scan(list)
    for i = 1, #list do if M.isMarked(list[i]) then M.remove(list[i]) end end
  end
  scan(deck.drawPile); scan(deck.discardPile); scan(deck.removed)
  if state.player and state.player.hand then scan(state.player.hand) end
  if state.dealer and state.dealer.hand then scan(state.dealer.hand) end
end

return M
