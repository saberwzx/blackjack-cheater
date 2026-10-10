-- tests/marks_acceptance.lua : 标记（虚空/消失/火焰/爆炸/赏金）、短牌靴稳健、调酒 forcedStand 验收
-- 契约：返回 { run = function() -> report { pass, fail, errors } }
-- 可被 tests/run.lua require 合并；也可独立 dofile（tools/run_lua.py tests/marks_acceptance.lua）
local Game = require('src.game')
local DT = require('src.deck_types')
local Marks = require('src.marks')
local Cocktails = require('src.cocktails')
local Bar = require('src.bar_mode')

local function mkRng(seed)
  local s = seed or 24681357
  return function(a, b)
    s = (s * 1103515245 + 12345) % 2147483648
    if a == nil then return s / 2147483648 end
    return a + (s % (b - a + 1))
  end
end
local function memfs()
  local files = {}
  return {
    read = function(p) return files[p] end,
    write = function(p, d) files[p] = d; return true end,
    getInfo = function(p) if files[p] then return { type = 'file' } end return nil end,
    mkdir = function() return true end,
    remove = function(p) files[p] = nil; return true end,
  }
end
local function new(mode, seed)
  return Game.new({ rng = mkRng(seed), filesystem = memfs() })
end
local function c(rank, value, extra)
  local o = { rank = rank, suit = 'S', kind = 'basic', is_basic = true, value = value }
  if extra then for k, v in pairs(extra) do o[k] = v end end
  return DT.mk(o)
end
local function started(mode, seed)
  local g = new(mode, seed)
  assert(g:start(mode, 20261001))
  g:flush()
  if g.state.state == 'relic_select' then assert(g:action('pick_relic', 1)); g:flush() end
  return g
end

local function build()
  local R = { pass = 0, fail = 0, errors = {} }
  local function check(name, fn)
    local ok, err = pcall(fn)
    if ok then R.pass = R.pass + 1
    else R.fail = R.fail + 1; R.errors[#R.errors + 1] = name .. ': ' .. tostring(err) end
  end
  local function eq(a, b, m)
    if a ~= b then error((m and (m .. ' ') or '') .. 'expected=' .. tostring(b) .. ' got=' .. tostring(a), 2) end
  end
  local function truthy(v, m) if not v then error(m or 'expected truthy', 2) end end

  -- ===================== 虚空标记 =====================
  check('mark_void: absorbs the preceding card and all its traits, consumes one use', function()
    local g = started('normal'); local s = g._g.state
    s.specialMarks = {}; s.flags.specialMarkUsedThisRound = false
    local deck = s.deck
    local prev = c('10', 10, { is_multiplier = true, mult_bonus = 0.5, is_chip = true, chip_value = 10 })
    local target = c('5', 5)
    deck:assignUid(prev); deck:assignUid(target)
    s.player.hand = { prev, target }
    Marks.gainSpecial(s, 'mark_void')
    eq(g._g:markCard(target), true)
    eq(#s.player.hand, 1)
    eq(s.player.hand[1], target)
    eq(target.is_multiplier, true)
    eq(target.mult_bonus, 0.5)
    eq(target.is_chip, true)
    eq(target.absorbed_from, prev.uid)
    eq(target.marked.markId, 'mark_void')
    eq(target.marked.ink, false)
    eq(deck.discardPile[#deck.discardPile], prev)
    eq(Marks.specialUsesLeft(s), 2)
    eq(s.flags.specialMarkUsedThisRound, true)
  end)

  check('mark_void: no preceding card -> no mark, no use consumed', function()
    local g = started('normal'); local s = g._g.state
    s.specialMarks = {}; s.flags.specialMarkUsedThisRound = false
    local target = c('5', 5); s.deck:assignUid(target)
    s.player.hand = { target }
    Marks.gainSpecial(s, 'mark_void')
    eq(g._g:markCard(target), false)
    eq(target.marked, nil)
    eq(Marks.specialUsesLeft(s), 3)
    eq(s.flags.specialMarkUsedThisRound, false)
  end)

  -- ===================== 消失标记 =====================
  check('mark_vanish: player skips 3 then receives the 4th real card; dealer unaffected', function()
    local g = started('normal'); local s = g._g.state
    local deck = s.deck
    local v1, v2, v3, v4, real = c('2', 2), c('3', 3), c('4', 4), c('5', 5), c('6', 6)
    for _, x in ipairs({ v1, v2, v3, v4, real }) do deck:assignUid(x) end
    for _, x in ipairs({ v1, v2, v3, v4 }) do Marks.newSpecial(x, 'mark_vanish') end
    deck.drawPile = { v1, v2, v3, v4, real }; deck.discardPile = {}
    local got = g._g:drawCard('player')
    eq(got, v4)
    eq(#deck.drawPile, 1)
    eq(deck.drawPile[1], real)
    eq(#deck.discardPile, 3)
    eq(deck.discardPile[1], v1)
    eq(deck.discardPile[3], v3)
    local d1 = c('9', 9); deck:assignUid(d1); Marks.newSpecial(d1, 'mark_vanish')
    deck.drawPile = { d1 }; deck.discardPile = {}
    eq(g._g:drawCard('dealer'), d1)
    eq(#deck.drawPile, 0)
  end)

  check('mark_vanish: a single marked card just skips once', function()
    local g = started('normal'); local s = g._g.state
    local deck = s.deck
    local v1, real = c('2', 2), c('7', 7)
    deck:assignUid(v1); deck:assignUid(real)
    Marks.newSpecial(v1, 'mark_vanish')
    deck.drawPile = { v1, real }; deck.discardPile = {}
    eq(g._g:drawCard('player'), real)
    eq(#deck.discardPile, 1)
  end)

  -- ===================== 火焰标记 =====================
  check('mark_flame: dealer cannot take the top flame card (it returns to the shoe top)', function()
    local g = started('normal'); local s = g._g.state
    local deck = s.deck
    local fl, other = c('10', 10), c('2', 2)
    deck:assignUid(fl); deck:assignUid(other)
    Marks.newSpecial(fl, 'mark_flame')
    deck.drawPile = { fl, other }; deck.discardPile = {}
    s.state = 'dealer'
    eq(g._g:drawCard('dealer'), nil)
    eq(#deck.drawPile, 2)
    eq(deck.drawPile[1], fl)
    eq(g._g:drawCard('player'), fl)
  end)

  check('mark_flame: dealerStep stands on a flame top card without drawing', function()
    local g = started('normal'); local s = g._g.state
    s.relics = {}
    g._g:buildShoe()
    local deck = s.deck
    local fl = c('10', 10); deck:assignUid(fl); Marks.newSpecial(fl, 'mark_flame')
    table.insert(deck.drawPile, 1, fl)
    s.player.hand = { c('10', 10), c('7', 7) }; s.player.total = 17
    s.dealer.hand = { c('10', 10), c('6', 6) }; s.dealer.total = 16; s.dealer.busted = false
    s.dealer.holeRevealed = true; s.dealer.steps = 0
    s.bet = 50; s.state = 'dealer'
    local before = #deck.drawPile
    local settled = 0
    local orig = g._g.settle
    g._g.settle = function(self) settled = settled + 1 end
    g._g:dealerStep()
    g._g:flush()
    g._g.settle = orig
    eq(settled, 1)
    eq(#s.dealer.hand, 2)
    eq(#deck.drawPile, before)
  end)

  -- ===================== 爆炸 / 赏金 =====================
  check('mark_bomb: destroys the following 2 cards, conserving every uid', function()
    local g = started('normal'); local s = g._g.state
    s.relics = {}
    g._g:buildShoe()
    local deck = s.deck
    local function uidCount()
      local n = 0; local seen = {}
      local lists = { deck.drawPile, deck.discardPile, deck.removed, s.player.hand, s.dealer.hand }
      for _, list in ipairs(lists) do
        for i = 1, #list do
          n = n + 1
          truthy(list[i].uid, 'uid missing')
          truthy(not seen[list[i].uid], 'duplicate uid')
          seen[list[i].uid] = true
        end
      end
      return n
    end
    local before = uidCount()
    local bomb = deck.drawPile[1]
    Marks.newSpecial(bomb, 'mark_bomb')
    s.state = 'dealer'
    eq(g._g:dealerDrawOne(), bomb)
    eq(s.dealer.hand[#s.dealer.hand], bomb)
    truthy(#deck.discardPile >= 2, 'expected 2 destroyed cards')
    eq(uidCount(), before)
    truthy(deck:auditOk(s.dealer.hand), 'deck audit failed after bomb')
  end)

  check('mark_bounty: only the dealer draw pays $500', function()
    local g = started('normal'); local s = g._g.state
    s.relics = {}
    g._g:buildShoe()
    local deck = s.deck
    local card = deck.drawPile[1]; Marks.newSpecial(card, 'mark_bounty')
    local chips = s.chips
    s.state = 'dealer'
    eq(g._g:drawCard('dealer'), card)
    eq(s.chips, chips + 500)
    local card2 = deck.drawPile[1]; Marks.newSpecial(card2, 'mark_bounty')
    chips = s.chips
    s.state = 'player'
    eq(g._g:drawCard('player'), card2)
    eq(s.chips, chips)
  end)

  -- ===================== 短牌靴稳健 =====================
  check('deal: an empty shoe never manufactures uid-less fake cards', function()
    local g = started('normal'); local s = g._g.state
    s.relics = {}
    local deck = s.deck
    deck.drawPile = {}; deck.discardPile = {}; deck.removed = {}
    s.player.hand = {}; s.dealer.hand = {}
    g._g:dealInitial()
    eq(#s.player.hand, 0)
    eq(#s.dealer.hand, 0)
    eq(deck.syntheticCreated, 0)
  end)

  check('deal: a 1-card shoe deals it without synthesizing the rest', function()
    local g = started('normal'); local s = g._g.state
    s.relics = {}
    local deck = s.deck
    local only = c('9', 9); deck:assignUid(only)
    deck.drawPile = { only }; deck.discardPile = {}; deck.removed = {}
    s.player.hand = {}; s.dealer.hand = {}
    g._g:dealInitial()
    eq(#s.player.hand, 1)
    eq(s.player.hand[1], only)
    eq(#s.dealer.hand, 0)
    eq(deck.syntheticCreated, 0)
    truthy(only.uid ~= nil)
  end)

  -- ===================== 调酒 forcedStand =====================
  check('dealerStep: forcedStand settles with no extra draw', function()
    local g = started('normal'); local s = g._g.state
    s.relics = {}
    g._g:buildShoe()
    s.dealer.hand = { c('10', 10), c('2', 2) }; s.dealer.total = 12
    s.dealer.forcedStand = true; s.dealer.holeRevealed = true
    s.player.hand = { c('10', 10), c('8', 8) }; s.player.total = 18
    s.bet = 50; s.state = 'dealer'
    local before = #s.deck.drawPile
    local settled = 0
    local orig = g._g.settle
    g._g.settle = function(self) settled = settled + 1 end
    g._g:dealerStep()
    g._g.settle = orig
    eq(settled, 1)
    eq(s.dealer.forcedStand, nil)
    eq(#s.dealer.hand, 2)
    eq(#s.deck.drawPile, before)
  end)

  check('bar e2e: dealer_stop via bar_ability stops the dealer with zero further draws', function()
    local g = new('bar', 777)
    assert(g:start('bar', 777)); g:flush()
    if g.state.state == 'bar_brief' then assert(g:action('bar_begin')); g:flush() end
    local guard = 0
    while g.state.state == 'bar_gift' and guard < 20 do
      guard = guard + 1
      assert(g:action('bar_gift_pick', 1)); g:flush()
    end
    eq(g.state.state, 'player')
    local s = g._g.state
    local saturn = Cocktails.byId('ck_saturn') or Cocktails.byId('saturn')
    truthy(saturn ~= nil, 'ck_saturn def missing')
    local cup = Bar.newCup(saturn); cup.buffLeft = 5
    s.bar.cups = { cup }; s.bar.cupCount = 1
    s.bar.usedAbilityThisRound = false; s.bar.abilitiesUsed = {}
    eq(g:action('bar_ability', { id = 'ck_saturn' }), true)
    local d = s.dealer
    eq(d.forcedStand, true)
    d.hand = { c('10', 10), c('2', 2) }; d.holeRevealed = true
    g._g:refreshDealer()
    local draws = 0
    local origDraw = g._g.drawCard
    g._g.drawCard = function(self, who) draws = draws + 1; return origDraw(self, who) end
    local settled = 0
    local origSettle = g._g.settle
    g._g.settle = function(self) settled = settled + 1 end
    assert(g:action('stand'))
    g:update(0.35)
    g._g.drawCard = origDraw
    g._g.settle = origSettle
    eq(settled >= 1, true)
    eq(draws, 0)
    eq(d.forcedStand, nil)
  end)

  return R
end

local modname = ...
if modname == nil then
  local rep = build()
  for i = 1, #rep.errors do print('  FAIL ' .. rep.errors[i]) end
  print(string.format('marks: PASS=%d FAIL=%d', rep.pass, rep.fail))
  if rep.fail > 0 then error('marks tests failed: ' .. rep.fail) end
end
return { run = build }