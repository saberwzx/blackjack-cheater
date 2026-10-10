-- src/bar_actions.lua
-- 酒吧模式真实机制实现（34 技能 / 100 局 / 6 杯 5 口 / 5 局 buff / 宿醉 / 赠酒 / 结局）
-- 只覆盖 GS 的 bar* 方法；install(GS) 后替换 game_state 中的旧实现。
-- 不修改 game_state.lua / bar_mode.lua / ui/。
--
-- 用法：
--   local GS = require('src.game_state')
--   require('src.bar_actions').install(GS)
--   -- 核心还需在 GS.action 中路由 bar_pick / bar_confirm（当前为占位）
--
-- 依赖：src.cocktails / src.bar_mode / src.bar_lines / src.deck_types /
--       src.blackjack / src.champion / src.deck；随机统一走 GS:self:r*()。

local Cocktails = require('src.cocktails')
local BarMode   = require('src.bar_mode')
local BarLines  = require('src.bar_lines')
local DT        = require('src.deck_types')
local BJ        = require('src.blackjack')
local Champion  = require('src.champion')
local Deck      = require('src.deck')

local M = {}
M.VERSION = 'bar-actions 1.0'

local HAND_MAX_DEFAULT = 12

-- ===================== 基础读取 / 构造 =====================

local function ST(self) return self.state end
local function BAR(self) return self.state.bar end
local function DECK(self) return self.state.barDeck or self.state.deck end
local function HAND(self, who)
  if who == 'player' then return self.state.player.hand end
  return self.state.dealer.hand
end
local function HAND_MAX(self) return self.HAND_MAX or HAND_MAX_DEFAULT end

local function newPlayer()
  return { hand = {}, total = 0, rawTotal = 0, busted = false, stood = false,
    blackjack = false, is67 = false, isRps = false, surrendered = false,
    doubled = false, cageBlocked = false, peekIndex = nil, cardPack = nil }
end
local function newDealer()
  return { hand = {}, total = 0, rawTotal = 0, busted = false, holeRevealed = false,
    difficulty = 1, standOn = 17, is67 = false, isRps = false }
end

-- ===================== 数值 / 牌堆工具 =====================

local function cval(c) return BJ.cardValue(c) end

local function minIndex(list, fn)
  local bi, bv = nil, nil
  for i = 1, #list do
    local v = fn(list[i])
    if bi == nil or v < bv then bi, bv = i, v end
  end
  return bi
end
local function maxIndex(list, fn)
  local bi, bv = nil, nil
  for i = 1, #list do
    local v = fn(list[i])
    if bi == nil or v > bv then bi, bv = i, v end
  end
  return bi
end

-- 庄家明牌（hand[1] 为暗牌，index 2.. 为明牌）
local function upCards(d)
  local out = {}
  for i = 2, #d.hand do out[#out + 1] = { card = d.hand[i], index = i } end
  return out
end

local function sameFace(a, b)
  if not a or not b then return false end
  if a == b then return true end
  return a.rank == b.rank and a.suit == b.suit and a.value == b.value
end

local function sync(self)
  local b = BAR(self)
  if not b then return end
  b.mode = 'bar'
  b.totalRounds = BarMode.ROUNDS
  b.prob = b.giftChance or BarMode.GIFT_BASE
  b.giftOptions = b.pendingGift
  local buffs = {}
  for i = 1, #b.cups do
    local c = b.cups[i]
    c.id = c.id or c.drink
    if (c.buffLeft or 0) > 0 then buffs[c.drink] = c.buffLeft end
  end
  b.buffs = buffs
  b.cupCount = #b.cups
end

local function refreshAll(self)
  self:refreshPlayer()
  self:refreshDealer()
  self:refreshShoe()
  sync(self)
end

-- 新建一张合成牌（计入 Deck.syntheticCreated，保证守恒审计成立）
local function newSynthetic(self, src)
  local c = DT.clone(src)
  c.is_synthetic = true
  c._synthCounted = nil
  c._collected = nil
  c.uid = nil
  c.marked = nil
  c.revealed = nil
  DECK(self):assignUid(c)
  return c
end

local function sinkBottom(self, card)
  local deck = DECK(self)
  deck.drawPile[#deck.drawPile + 1] = card
end

-- ===================== 庄家抽牌 / 补牌 =====================

local function drawDealerUp(self, n)
  local d = ST(self).dealer
  local drawn = {}
  for i = 1, (n or 1) do
    if #d.hand >= HAND_MAX(self) then break end
    local c = self:drawCard('dealer')
    if not c then break end
    self:pushHand('dealer', c)
    drawn[#drawn + 1] = c
  end
  return drawn
end

-- 补明牌直到「明牌数」(= #hand-1) 达到 target（只补不收）
local function fillUpTo(self, target)
  local d = ST(self).dealer
  local guard = 0
  while (#d.hand - 1) < target and #d.hand < HAND_MAX(self) and guard < HAND_MAX(self) + 4 do
    guard = guard + 1
    local before = #d.hand
    drawDealerUp(self, 1)
    if #d.hand == before then break end
  end
  return true
end

local function drawHighest(self)
  local deck = DECK(self)
  if #deck.drawPile == 0 then
    if #deck.discardPile > 0 then deck:shuffleDiscardIn() else return nil end
  end
  local bi = nil
  for i = 1, #deck.drawPile do
    if bi == nil or cval(deck.drawPile[i]) > cval(deck.drawPile[bi]) then bi = i end
  end
  if not bi then return nil end
  return table.remove(deck.drawPile, bi)
end

local function deckTop(self)
  local deck = DECK(self)
  if #deck.drawPile == 0 and #deck.discardPile > 0 then deck:shuffleDiscardIn() end
  return deck.drawPile[1]
end

-- ===================== 赠酒 / 文案 =====================

local function unseenDrinks(b)
  local out = {}
  for i = 1, #Cocktails.LIST do
    local d = Cocktails.LIST[i]
    if not b.offered[d.id] and not BarMode.findCup(b, d.id) then out[#out + 1] = d end
  end
  return out
end

local function pickGiftOptions(self, count)
  local b = BAR(self)
  local pool = unseenDrinks(b)
  local out = {}
  local guard = 0
  while #out < count and #pool > 0 and guard < 200 do
    guard = guard + 1
    local d = self:rpick(pool)
    for i = 1, #pool do
      if pool[i] == d then table.remove(pool, i); break end
    end
    out[#out + 1] = { id = d.id, name = d.name, en = d.en, gift = d.gift, group = d.group, def = d }
  end
  return out
end

local function drawLine(self, b, cup)
  b.lineBags = b.lineBags or {}
  local key = cup and cup.drink or '__generic'
  local list = cup and BarLines.byDrink[cup.drink] or BarLines.generic
  if not list or #list == 0 then list = BarLines.generic end
  if not b.lineBags[key] or #b.lineBags[key] == 0 then
    b.lineBags[key] = BarLines.shuffleBag(list, self.rng)
  end
  return table.remove(b.lineBags[key])
end

local function randomActiveCup(self)
  local b = BAR(self)
  local active = BarMode.activeCups(b)
  if #active == 0 then return nil end
  return active[self:rint(1, #active)]
end

-- ===================== 34 技能：即时执行 =====================

local ACTIVATE = {}

ACTIVATE.redraw_hand = function(self)
  local st = ST(self)
  local p = st.player
  local deck = DECK(self)
  local n = #p.hand
  if n == 0 then return false, 'no_hand' end
  for i = #p.hand, 1, -1 do
    local c = table.remove(p.hand, i)
    if c then deck:toDiscard(c) end
  end
  for i = 1, n do
    local c = self:drawCard('player')
    if not c then break end
    self:pushHand('player', c)
  end
  return true
end

ACTIVATE.burn_half = function(self)
  local deck = DECK(self)
  local n = #deck.drawPile
  if n == 0 then return false, 'empty_deck' end
  deck:shuffle()
  local burn = math.floor(n / 2)
  for i = 1, burn do
    local c = table.remove(deck.drawPile, 1)
    if c then deck:toRemoved(c) end
  end
  self:msg('着火：烧掉牌堆 ' .. burn .. ' 张。', 'info')
  return true
end

ACTIVATE.duplicate_lowest = function(self)
  local p = ST(self).player
  if #p.hand == 0 then return false, 'no_hand' end
  if #p.hand >= HAND_MAX(self) then return false, 'hand_full' end
  local li = minIndex(p.hand, cval)
  if not li then return false, 'no_hand' end
  local nc = newSynthetic(self, p.hand[li])
  self:pushHand('player', nc)
  self:msg('双份：复制点数最低的一张。', 'info')
  return true
end

ACTIVATE.dealer_stop = function(self)
  -- 主 GS:dealerStep 必须读取 d.forcedStand（见 docs/bar-implementation.md 集成点 2）
  ST(self).dealer.forcedStand = true
  self:msg('封口：酒保本局停牌。', 'info')
  return true
end

ACTIVATE.discard_highest = function(self)
  local p = ST(self).player
  if #p.hand == 0 then return false, 'no_hand' end
  local li = maxIndex(p.hand, cval)
  local c = table.remove(p.hand, li)
  DECK(self):toDiscard(c)
  return true
end

ACTIVATE.discard_random = function(self)
  local p = ST(self).player
  if #p.hand == 0 then return false, 'no_hand' end
  local li = self:rint(1, #p.hand)
  local c = table.remove(p.hand, li)
  DECK(self):toDiscard(c)
  return true
end

ACTIVATE.take_dealer_highest_sink = function(self)
  local d = ST(self).dealer
  local ups = upCards(d)
  if #ups == 0 then return false, 'no_up' end
  local bi = maxIndex(ups, function(u) return cval(u.card) end)
  local u = ups[bi]
  table.remove(d.hand, u.index)
  sinkBottom(self, u.card)
  self:msg('移花：抽走酒保最大明牌沉底。', 'info')
  return true
end

ACTIVATE.give_lowest_to_dealer = function(self)
  local p = ST(self).player
  local d = ST(self).dealer
  if #p.hand == 0 then return false, 'no_hand' end
  if #d.hand >= HAND_MAX(self) then return false, 'hand_full' end
  local li = minIndex(p.hand, cval)
  local c = table.remove(p.hand, li)
  self:pushHand('dealer', c)
  return true
end

ACTIVATE.dealer_last_sink_draw = function(self)
  local d = ST(self).dealer
  local ups = upCards(d)
  if #ups == 0 then return false, 'no_up' end
  local u = ups[#ups]
  table.remove(d.hand, u.index)
  sinkBottom(self, u.card)
  drawDealerUp(self, 1)
  return true
end

ACTIVATE.dealer_extra_up = function(self)
  drawDealerUp(self, 1)
  return true
end

ACTIVATE.dealer_lowest_sink_draw = function(self)
  local d = ST(self).dealer
  local ups = upCards(d)
  if #ups == 0 then return false, 'no_up' end
  local bi = minIndex(ups, function(u) return cval(u.card) end)
  local u = ups[bi]
  table.remove(d.hand, u.index)
  sinkBottom(self, u.card)
  drawDealerUp(self, 1)
  return true
end

ACTIVATE.dealer_fill_to_2 = function(self)
  return fillUpTo(self, 2)
end

ACTIVATE.dealer_fill_to_3 = function(self)
  return fillUpTo(self, 3)
end

ACTIVATE.dealer_fill_to_player_count = function(self)
  return fillUpTo(self, #ST(self).player.hand)
end

ACTIVATE.dealer_draw_1 = function(self)
  drawDealerUp(self, 1)
  return true
end

ACTIVATE.dealer_draw_2 = function(self)
  drawDealerUp(self, 2)
  return true
end

ACTIVATE.dealer_draw_3 = function(self)
  drawDealerUp(self, 3)
  return true
end

ACTIVATE.dealer_draw_2_stop = function(self)
  drawDealerUp(self, 2)
  ST(self).dealer.forcedStand = true
  return true
end

ACTIVATE.dealer_copy_last = function(self)
  local d = ST(self).dealer
  local ups = upCards(d)
  if #ups == 0 then return false, 'no_up' end
  if #d.hand >= HAND_MAX(self) then return false, 'hand_full' end
  local nc = newSynthetic(self, ups[#ups].card)
  self:pushHand('dealer', nc)
  return true
end

ACTIVATE.dealer_duplicate_ups = function(self)
  local d = ST(self).dealer
  local ups = upCards(d)
  if #ups == 0 then return false, 'no_up' end
  local snapshot = {}
  for i = 1, #ups do snapshot[i] = ups[i].card end
  for i = 1, #snapshot do
    if #d.hand >= HAND_MAX(self) then break end
    local nc = newSynthetic(self, snapshot[i])
    self:pushHand('dealer', nc)
  end
  return true
end

ACTIVATE.dealer_draw_1_give_random = function(self)
  local st = ST(self)
  local p, d = st.player, st.dealer
  if #p.hand == 0 then return false, 'no_hand' end
  if #d.hand + 2 > HAND_MAX(self) then return false, 'hand_full' end
  drawDealerUp(self, 1)
  local li = self:rint(1, #p.hand)
  local c = table.remove(p.hand, li)
  self:pushHand('dealer', c)
  return true
end

ACTIVATE.swap_dealer_lowest_with_draw = function(self)
  local d = ST(self).dealer
  local ups = upCards(d)
  if #ups == 0 then return false, 'no_up' end
  local deck = DECK(self)
  if #deck.drawPile == 0 then
    if #deck.discardPile > 0 then deck:shuffleDiscardIn() else return false, 'empty_deck' end
  end
  local bi = minIndex(ups, function(u) return cval(u.card) end)
  local u = ups[bi]
  local top = table.remove(deck.drawPile, 1)
  d.hand[u.index] = top
  table.insert(deck.drawPile, 1, u.card)
  return true
end

ACTIVATE.dealer_draw_highest = function(self)
  local c = drawHighest(self)
  if not c then return false, 'empty_deck' end
  self:pushHand('dealer', c)
  return true
end

ACTIVATE.dealer_draw_until_21 = function(self)
  local st = ST(self)
  local d = st.dealer
  local guard = 0
  while BJ.handTotal(d.hand) < 21 and #d.hand < HAND_MAX(self) and guard < HAND_MAX(self) + 4 do
    guard = guard + 1
    local before = #d.hand
    drawDealerUp(self, 1)
    if #d.hand == before then break end
  end
  return true
end

ACTIVATE.deck_sort_asc = function(self)
  local deck = DECK(self)
  table.sort(deck.drawPile, function(a, b) return cval(a) < cval(b) end)
  return true
end

ACTIVATE.sink_top_5 = function(self)
  local deck = DECK(self)
  local n = math.min(5, #deck.drawPile)
  for i = 1, n do
    local c = table.remove(deck.drawPile, 1)
    if c then sinkBottom(self, c) end
  end
  return true
end

ACTIVATE.deck_rebuild_shuffle = function(self)
  local deck = DECK(self)
  for i = 1, #deck.drawPile do
    deck.discardPile[#deck.discardPile + 1] = deck.drawPile[i]
  end
  deck.drawPile = {}
  deck:addCards(BarMode.buildDeck(), 'bar')
  return true
end

ACTIVATE.deck_remove_random_10 = function(self)
  local deck = DECK(self)
  if #deck.drawPile == 0 then return false, 'empty_deck' end
  local n = math.min(10, #deck.drawPile)
  for i = 1, n do
    local idx = self:rint(1, #deck.drawPile)
    local c = table.remove(deck.drawPile, idx)
    if c then deck:toRemoved(c) end
  end
  return true
end

ACTIVATE.deck_insert_5_tens = function(self)
  local deck = DECK(self)
  for i = 1, 5 do
    local c = DT.mk({ rank = '10', suit = 'S', kind = 'basic', is_synthetic = true })
    deck:assignUid(c)
    local pos = self:rint(1, #deck.drawPile + 1)
    table.insert(deck.drawPile, pos, c)
  end
  return true
end

ACTIVATE.deck_compress_top_half = function(self)
  local deck = DECK(self)
  local n = #deck.drawPile
  if n <= 1 then return true end
  table.sort(deck.drawPile, function(a, b) return cval(a) > cval(b) end)
  local keep = math.ceil(n / 2)
  if keep < 1 then keep = 1 end
  for i = n, keep + 1, -1 do
    local c = table.remove(deck.drawPile, i)
    if c then deck:toRemoved(c) end
  end
  return true
end

-- ===================== 34 技能：需要选择的四种 =====================

local SELECTION = {
  swap_hand_card = true,
  swap_with_dealer = true,
  peek_sink_pick = true,
  pick_from_champion = true,
}

local function handCandidates(self)
  local out = {}
  local p = ST(self).player
  for i = 1, #p.hand do
    out[#out + 1] = { index = i, label = p.hand[i].label or '?', kind = p.hand[i].kind }
  end
  return out
end

local function buildStep2(self, p)
  if p.special == 'swap_hand_card' then
    local card = ST(self).player.hand[p.handIndex]
    if not card then return {} end
    local roster
    local ok, res = pcall(DT.roster, card.kind or 'basic')
    if ok and res then roster = res end
    if not roster or #roster == 0 then roster = DT.standard52() end
    local out = {}
    for i = 1, #roster do
      local r = roster[i]
      if not sameFace(r, card) then
        out[#out + 1] = { index = #out + 1, card = r, label = r.label or r.rank or '?', kind = r.kind }
      end
    end
    return out
  elseif p.special == 'swap_with_dealer' then
    local d = ST(self).dealer
    local out = {}
    for i = 2, #d.hand do
      out[#out + 1] = { index = #out + 1, dealerIndex = i, card = d.hand[i], label = d.hand[i].label or '?' }
    end
    return out
  end
  return {}
end

local function resolveHandIndex(self, arg)
  local p = ST(self).player
  if arg.uid then
    for i = 1, #p.hand do
      if p.hand[i].uid == arg.uid then return i end
    end
  end
  if arg.index and arg.index >= 1 and arg.index <= #p.hand then return arg.index end
  return nil
end

local function resolveCandidate(p, arg)
  if arg.cand and arg.cand >= 1 and arg.cand <= #p.candidates then return arg.cand end
  if arg.index and arg.index >= 1 and arg.index <= #p.candidates then return arg.index end
  if arg.uid then
    for i = 1, #p.candidates do
      local cc = p.candidates[i].card
      if cc and cc.uid == arg.uid then return i end
    end
  end
  return nil
end

-- 选择技能的准备
local function prepareSelection(self, cup, special)
  local st = ST(self)
  local b = st.bar
  local p = {
    special = special,
    cupId = cup.drink,
    interaction = (cup.ability and cup.ability.interaction) or 'two_step',
    step = 1,
    picks = {},
  }
  if special == 'peek_sink_pick' then
    local deck = DECK(self)
    p.candidates = {}
    for i = 1, math.min(3, #deck.drawPile) do
      local c = deck.drawPile[i]
      c.revealed = true
      p.candidates[#p.candidates + 1] = { index = #p.candidates + 1, card = c, label = c.label or '?' }
    end
    self:revealShoeRange(1, #p.candidates, 'bar')
  elseif special == 'pick_from_champion' then
    local pool = st.championCards
    if not pool or #pool == 0 then
      pool = {}
      local groups = DT.championGroups()
      for gi = 1, #groups do
        for ci = 1, #groups[gi].cards do
          local c = DT.clone(groups[gi].cards[ci])
          c.group = groups[gi].key
          pool[#pool + 1] = c
        end
      end
      pool = Champion.randomPick(pool, self.rng, Champion.SIZE or 36)
      st.championCards = pool
    end
    p.candidates = {}
    for i = 1, #pool do
      p.candidates[#p.candidates + 1] = { index = i, card = pool[i], label = pool[i].label or '?', group = pool[i].group }
    end
  else
    p.candidates = handCandidates(self)
  end
  b.pending = p
  self:setState('bar_pick')
  return true
end

local CONFIRM = {}

CONFIRM.swap_hand_card = function(self, p)
  local ph = ST(self).player.hand
  if not p.choice then return false, 'no_choice' end
  local cand = p.candidates[p.choice]
  if not cand or not cand.card then return false, 'invalid_arg' end
  local card = ph[p.handIndex]
  if not card then return false, 'no_card' end
  table.remove(ph, p.handIndex)
  DECK(self):toDiscard(card)
  local nc = newSynthetic(self, cand.card)
  table.insert(ph, p.handIndex, nc)
  self:emit({ kind = 'deal', target = 'player', card = nc, index = p.handIndex })
  return true
end

CONFIRM.swap_with_dealer = function(self, p)
  local st = ST(self)
  if not p.choice then return false, 'no_choice' end
  local cand = p.candidates[p.choice]
  if not cand then return false, 'invalid_arg' end
  local pc = st.player.hand[p.handIndex]
  local dc = st.dealer.hand[cand.dealerIndex]
  if not pc or not dc then return false, 'no_card' end
  st.player.hand[p.handIndex] = dc
  st.dealer.hand[cand.dealerIndex] = pc
  self:emit({ kind = 'deal', target = 'player', card = dc, index = p.handIndex })
  self:emit({ kind = 'deal', target = 'dealer', card = pc, index = cand.dealerIndex })
  return true
end

CONFIRM.peek_sink_pick = function(self, p)
  local deck = DECK(self)
  local moved = 0
  for ci = 1, #p.candidates do
    if p.picks[ci] then
      local cand = p.candidates[ci]
      if cand.card and deck:removeFromDraw(cand.card) then
        sinkBottom(self, cand.card)
        moved = moved + 1
      end
    end
  end
  self:msg('透牌：沉底 ' .. moved .. ' 张。', 'info')
  return true
end

CONFIRM.pick_from_champion = function(self, p)
  local st = ST(self)
  if #st.player.hand >= HAND_MAX(self) then return false, 'hand_full' end
  if not p.choice then return false, 'no_choice' end
  local cand = p.candidates[p.choice]
  if not cand or not cand.card then return false, 'invalid_arg' end
  local nc = newSynthetic(self, cand.card)
  self:pushHand('player', nc)
  return true
end

-- ===================== GS 方法实现 =====================

local method = {}

function method.barStart(self)
  local st = ST(self)
  st.mode = 'bar'
  st.stage = 1
  st.chips = 0
  st.bet = 0
  st.round = 0
  local deck = Deck.new({ rng = self.rng })
  deck:addCards(BarMode.buildDeck(), 'bar')
  deck:shuffle()
  st.deck = deck
  st.barDeck = deck
  local b = BarMode.newState()
  b.totalRounds = BarMode.ROUNDS
  b.giftChance = BarMode.GIFT_BASE
  b.prob = b.giftChance
  b.giftOptions = nil
  b.pendingDrink = nil
  b.buffs = {}
  b.lineBags = {}
  b.lastLine = ''
  b.cupCount = 0
  b.usedAbilityThisRound = false
  b.abilitiesUsed = {}
  st.bar = b
  sync(self)
  self:setState('bar_brief')
  self:msg('酒吧周目：100 局，攒满 6 杯。', 'info')
  return true
end

function method.bar_begin(self)
  if ST(self).state ~= 'bar_brief' then return self:fail('action_unavailable') end
  local b = BAR(self)
  b.round = 0
  self:barBeginRound()
  return true
end

function method.barBeginRound(self)
  local st = ST(self)
  local b = st.bar
  if not b then return self:fail('action_unavailable') end
  if b.finished then return self:barEnding() end
  if b.round >= BarMode.ROUNDS then b.finished = true; return self:barEnding() end
  b.round = b.round + 1
  st.round = b.round
  b.usedAbilityThisRound = false
  b.abilitiesUsed = {}
  -- 每局开一张通用文案：200 条独立洗牌袋，一个周期内不重复
  b.lastLine = drawLine(self, b, nil)
  b.pending = nil
  b.pendingDrink = nil
  b.lastGift = nil
  -- 宿醉由上一局 after-round 设置，本局保留展示（计算层不受影响）
  if not BarMode.cupsFull(b) then
    local pity = BarMode.isPityRound(b.round)
    local chance = self:rchance(b.giftChance or BarMode.GIFT_BASE)
    if pity or chance then
      local cand = pickGiftOptions(self, 3)
      if #cand > 0 then
        b.pendingGift = cand
        b.pendingPity = pity
        b.giftOptions = cand
        self:setState('bar_gift')
        return true
      end
    end
  end
  return self:barDeal()
end

function method.bar_gift_pick(self, index)
  local st = ST(self)
  local b = st.bar
  if not b or st.state ~= 'bar_gift' or not b.pendingGift then return self:fail('action_unavailable') end
  local c = b.pendingGift[index or 0]
  if not c then return self:fail('invalid_arg') end
  local cup, err = BarMode.addCup(b, c.def)
  if not cup then return self:fail(err or 'invalid_arg') end
  cup.id = cup.drink
  -- 送出一杯后重置回 1%
  b.giftChance = BarMode.GIFT_BASE
  b.lastGift = cup.drink
  b.pendingGift = nil
  b.pendingPity = false
  b.giftOptions = nil
  b.lastLine = drawLine(self, b, randomActiveCup(self) or cup)
  sync(self)
  self:msg('获得新酒：' .. tostring(c.name or cup.name or ''), 'success')
  return self:barDeal()
end

function method.barDeal(self)
  local st = ST(self)
  local b = st.bar
  local deck = DECK(self)
  -- 回收上一局双方手牌（含技能留下的牌），保证牌实体守恒
  if st.player and st.player.hand then
    for i = 1, #st.player.hand do deck:toDiscard(st.player.hand[i]) end
  end
  if st.dealer and st.dealer.hand then
    for i = 1, #st.dealer.hand do deck:toDiscard(st.dealer.hand[i]) end
  end
  st.player = newPlayer()
  st.dealer = newDealer()
  st.dealer.difficulty = 2
  st.bet = 0
  st.bustBet = { on = false, amount = 0, odds = nil, hit = false, locked = true }
  st.result = nil
  -- 不足 4 张时按样牌整靴重灌
  if #deck.drawPile < 4 then
    deck:addCards(BarMode.buildDeck(), 'bar')
    deck:shuffle()
  end
  for i = 1, 2 do
    local c = self:drawCard('player')
    if c then self:pushHand('player', c) end
  end
  for i = 1, 2 do
    local c = self:drawCard('dealer')
    if c then self:pushHand('dealer', c) end
  end
  st.dealer.holeRevealed = false
  refreshAll(self)
  self:setState('player')
  self:msg('酒吧第 ' .. b.round .. ' 局', 'info')
  return true
end

function method.barFindCupIndex(self, cupOrId)
  local b = BAR(self)
  if not b then return nil end
  if cupOrId == nil then return nil end
  if type(cupOrId) == 'table' then cupOrId = cupOrId.id or cupOrId.drink end
  if type(cupOrId) == 'number' then
    if b.cups[cupOrId] then return cupOrId end
    return nil
  end
  for i = 1, #b.cups do
    if b.cups[i].drink == cupOrId or b.cups[i].id == cupOrId then return i end
  end
  return nil
end

function method.bar_drink(self, cup)
  local st = ST(self)
  local b = st.bar
  if not b then return self:fail('action_unavailable') end
  if st.state ~= 'player' and st.state ~= 'result' then return self:fail('action_unavailable') end
  local i = self:barFindCupIndex(cup)
  if not i then return self:fail('invalid_arg') end
  local c, err = BarMode.drink(b, i)
  if not c then return self:fail(err or 'action_unavailable') end
  c.id = c.id or c.drink
  self:emit({ kind = 'sfx', name = 'chip' })
  sync(self)
  -- 全空立刻 fail
  if BarMode.totalRemaining(b) <= 0 then
    b.finished = true
    return self:barEnding()
  end
  return true
end

function method.barAfterRound(self)
  local st = ST(self)
  local b = st.bar
  if not b then return 'bar_ending' end
  b.hangover = nil
  b.hangoverColor = nil
  b.hangoverNames = nil
  local outcome = st.result and st.result.outcome
  if outcome == 'player' then
    b.wins = (b.wins or 0) + 1
    b.giftChance = math.min(1, (b.giftChance or BarMode.GIFT_BASE) + BarMode.GIFT_STEP)
    b.lastLine = drawLine(self, b, randomActiveCup(self))
  elseif outcome == 'dealer' then
    b.losses = (b.losses or 0) + 1
    b.giftChance = BarMode.GIFT_BASE
  end
  -- tickDown：所有 buff -1（无条件，不看胜负）
  local expired = BarMode.tickBuffs(b)
  if #expired > 0 then
    b.hangover = true
    local col = BarMode.hangoverColor(expired)
    if col then
      b.hangoverColor = { r = col[1] or col.r, g = col[2] or col.g, b = col[3] or col.b, col[1], col[2], col[3] }
    end
    b.hangoverNames = {}
    for i = 1, #expired do b.hangoverNames[#b.hangoverNames + 1] = expired[i].name end
  end
  -- 调酒栏空 -> 立即失败
  if BarMode.totalRemaining(b) <= 0 then
    b.finished = true
    return 'bar_ending'
  end
  -- 输 -> 强制喝 1 口（栏内只剩 1 杯时直接喝那一杯）
  if outcome == 'dealer' then
    local active = BarMode.activeCups(b)
    if #active == 0 then
      b.finished = true
      return 'bar_ending'
    end
    local pick
    if #active == 1 then pick = active[1] else pick = active[self:rint(1, #active)] end
    b.pendingDrink = { cupId = pick.drink, name = pick.name }
    BarMode.drink(b, self:barFindCupIndex(pick.drink))
    b.pendingDrink = nil
    self:msg('输了，罚喝一口：' .. tostring(pick.name or ''), 'warning')
    if BarMode.totalRemaining(b) <= 0 then
      b.finished = true
      return 'bar_ending'
    end
  end
  sync(self)
  if b.round >= BarMode.ROUNDS then
    b.finished = true
    return 'bar_ending'
  end
  return 'bar_next'
end

function method.barEnding(self)
  local st = ST(self)
  local b = st.bar
  if not b then return self:fail('action_unavailable') end
  b.finished = true
  local ending, total = BarMode.classify(b)
  b.ending = ending
  b.endingTotal = total
  local cupsLeft = 0
  for i = 1, #b.cups do
    if BarMode.remaining(b.cups[i]) > 0 then cupsLeft = cupsLeft + 1 end
  end
  b.endingCups = cupsLeft
  local textKeys = { date = 'date', fish = 'keeper', buddies = 'friend', fail = 'fail' }
  b.endingLine = BarLines.endings[textKeys[ending] or 'friend'] or ''
  local titles = { date = '与酒保的约会', fish = '养鱼', buddies = '好酒友', fail = '被请出去了' }
  self:setState('bar_ending')
  self:msg('酒吧结局：' .. tostring(titles[ending] or ending) .. '（剩余 ' .. tostring(total) .. ' 口）',
    ending == 'fail' and 'error' or 'success')
  sync(self)
  return true
end

function method.bar_ability(self, arg)
  local st = ST(self)
  local b = st.bar
  if not b then return self:fail('action_unavailable') end
  if st.state ~= 'player' then return self:fail('action_unavailable') end
  if b.usedAbilityThisRound then return self:fail('ability_used') end
  if type(arg) ~= 'table' then arg = { id = arg } end
  local idx = self:barFindCupIndex(arg.id or arg.drink or arg.index)
  if not idx then return self:fail('invalid_arg') end
  local cup = b.cups[idx]
  if not cup then return self:fail('invalid_arg') end
  if (cup.buffLeft or 0) <= 0 then return self:fail('ability_locked') end
  local special = cup.ability and cup.ability.special
  if not special then return self:fail('unknown_skill') end
  if SELECTION[special] then
    return prepareSelection(self, cup, special)
  end
  local fn = ACTIVATE[special]
  if not fn then return self:fail('unknown_skill') end
  local ok, err = fn(self, cup, arg)
  if not ok then return self:fail(err or 'ability_failed') end
  b.usedAbilityThisRound = true
  b.abilitiesUsed[cup.drink] = true
  refreshAll(self)
  return true
end

function method.barApplyAbility(self, special, arg)
  if SELECTION[special] then return self:fail('action_unavailable') end
  local fn = ACTIVATE[special]
  if not fn then return self:fail('unknown_skill') end
  local ok, err = fn(self, nil, arg or {})
  if not ok then return self:fail(err or 'ability_failed') end
  return true
end

function method.barPrepareSelection(self, cup, special)
  return prepareSelection(self, cup, special)
end

function method.bar_pick(self, arg)
  local st = ST(self)
  local b = st.bar
  if not b or st.state ~= 'bar_pick' or not b.pending then return self:fail('action_unavailable') end
  local p = b.pending
  if type(arg) ~= 'table' then arg = { index = arg } end
  if arg.cancel then
    b.pending = nil
    self:setState('player')
    return true
  end
  if p.special == 'peek_sink_pick' then
    local ci = resolveCandidate(p, arg)
    if not ci then return self:fail('invalid_arg') end
    p.picks[ci] = not p.picks[ci]
    return true
  elseif p.special == 'pick_from_champion' then
    local ci = resolveCandidate(p, arg)
    if not ci then return self:fail('invalid_arg') end
    p.choice = ci
    return true
  else
    if p.step == 1 then
      local hi = resolveHandIndex(self, arg)
      if not hi then return self:fail('invalid_arg') end
      p.handIndex = hi
      p.step = 2
      p.choice = nil
      p.candidates = buildStep2(self, p)
      return true
    else
      local ci = resolveCandidate(p, arg)
      if not ci then return self:fail('invalid_arg') end
      p.choice = ci
      return true
    end
  end
end

function method.bar_confirm(self)
  local st = ST(self)
  local b = st.bar
  if not b or st.state ~= 'bar_pick' or not b.pending then return self:fail('action_unavailable') end
  local p = b.pending
  local fn = CONFIRM[p.special]
  if not fn then return self:fail('unknown_skill') end
  local ok, err = fn(self, p)
  if not ok then return self:fail(err or 'ability_failed') end
  b.usedAbilityThisRound = true
  b.abilitiesUsed[p.cupId] = true
  b.pending = nil
  self:setState('player')
  refreshAll(self)
  return true
end

-- ===================== install =====================

function M.install(GS)
  if type(GS) ~= 'table' then
    error('bar_actions.install(GS): GS table required', 2)
  end
  -- 幂等：若本版本方法已安装则不再重复覆盖
  if GS.__barActionsV1 and GS.barBeginRound == method.barBeginRound then return true end
  for k, v in pairs(method) do
    GS[k] = v
  end
  GS.__barActionsV1 = true
  return true
end

M.methods = method
M.ACTIVATE = ACTIVATE
M.CONFIRM = CONFIRM
M.SELECTION = SELECTION

return M
