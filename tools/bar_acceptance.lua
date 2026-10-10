-- tools/bar_acceptance.lua
-- 酒吧机制验收：install(bar_actions) 后逐技能验证 34 技能关键可见效果，
-- 以及两步选择 / 费用 / 一局限一次 / 赠酒概率 / 保底 / 宿醉 / 空栏 / 结局 / 100 局全流程。
-- 运行：python tools/run_lua.py tools/bar_acceptance.lua
local Game = require('src.game')
local GS   = require('src.game_state')
local BarActions = require('src.bar_actions')
local BarMode = require('src.bar_mode')
local Cocktails = require('src.cocktails')
local DT = require('src.deck_types')
local BJ = require('src.blackjack')
local Deck = require('src.deck')
local BarLines = require('src.bar_lines')

BarActions.install(GS)
assert(BarActions.VERSION, 'bar_actions not loaded')

local pass, failures = 0, {}
local function check(name, fn)
  local ok, res, msg = pcall(fn)
  if not ok then
    failures[#failures + 1] = name .. ' [error] ' .. tostring(res)
  elseif res == false then
    failures[#failures + 1] = name .. ' [fail] ' .. tostring(msg or '')
  else
    pass = pass + 1
  end
end

-- ===== 确定性 rng + memoryfs =====
local seed = 123456789
local function rng(a, b)
  seed = (seed * 1103515245 + 12345) % 2147483648
  if a == nil then return seed / 2147483648 end
  return a + (seed % (b - a + 1))
end

local files = {}
local function memfs()
  return {
    read = function(p) return files[p] end,
    write = function(p, d) files[p] = d; return true end,
    getInfo = function(p) if files[p] then return { type = 'file' } end return nil end,
    mkdir = function() return true end,
    remove = function(p) files[p] = nil; return true end,
  }
end

local function newGame()
  seed = 123456789
  local g = Game.new({ rng = rng, filesystem = memfs() })
  local ok, err = g:start('bar', 20261001)
  assert(ok, 'start(bar) failed: ' .. tostring(err))
  g:flush()
  return g
end

local function enterPlayer(g)
  local ok, err = g:action('bar_begin')
  assert(ok, 'bar_begin failed: ' .. tostring(err))
  g:flush()
  if g.state.state == 'bar_gift' then
    local ok2, err2 = g:action('bar_gift_pick', 1)
    assert(ok2, 'bar_gift_pick failed: ' .. tostring(err2))
    g:flush()
  end
  assert(g.state.state == 'player', 'expected player, got ' .. tostring(g.state.state))
  return g
end

local function findDef(special)
  for i = 1, #Cocktails.LIST do
    local d = Cocktails.LIST[i]
    if d.ability and d.ability.special == special then return d end
  end
  return nil
end

local function armCup(g, special)
  local def = findDef(special)
  assert(def, 'no drink for special ' .. tostring(special))
  local b = g.state.bar
  local cup = BarMode.newCup(def)
  cup.id = def.id
  cup.drink = def.id
  cup.buffLeft = 5
  b.cups = { cup }
  b.cupCount = 1
  b.offered[def.id] = true
  b.usedAbilityThisRound = false
  b.abilitiesUsed = {}
  g.state.state = 'player'
  return cup, def
end

local function specCard(s)
  if type(s) == 'table' then return DT.mk(s) end
  return DT.mk({ rank = tostring(s), suit = 'S', kind = 'basic' })
end

-- 构造受控牌堆 + 手牌（手牌按合成牌计入，保证 Deck:audit 守恒成立）
local function field(g, deckCards, playerCards, dealerCards)
  local d = Deck.new({ rng = function(a, b) return b end })
  local dc = {}
  for i = 1, #(deckCards or {}) do dc[i] = specCard(deckCards[i]) end
  d:addCards(dc, 'test')
  local function synth(list)
    local out = {}
    for i = 1, #(list or {}) do
      local c = specCard(list[i])
      c.is_synthetic = true
      d:assignUid(c)
      out[i] = c
    end
    return out
  end
  g.state.deck = d
  g.state.barDeck = d
  g.state.player = { hand = synth(playerCards), total = 0, rawTotal = 0, busted = false,
    stood = false, blackjack = false, is67 = false, isRps = false, surrendered = false,
    doubled = false, cageBlocked = false }
  g.state.dealer = { hand = synth(dealerCards), total = 0, rawTotal = 0, busted = false,
    holeRevealed = false, difficulty = 2, standOn = 17, is67 = false, isRps = false }
  g._g:refreshPlayer()
  g._g:refreshDealer()
  return d
end

local function auditOK(g)
  local d = g.state.deck
  local ext = {}
  local function push(list) for i = 1, #list do ext[#ext + 1] = list[i] end end
  push(g.state.player.hand)
  push(g.state.dealer.hand)
  return d:audit(ext)
end

local function requireAudit(g)
  local a = auditOK(g)
  if not a.ok then
    return false, 'audit total=' .. tostring(a.total) .. ' expected=' .. tostring(a.expected) ..
      ' dup=' .. tostring(#a.duplicates) .. ' miss=' .. tostring(#a.missingUid)
  end
  return true
end

local function labels(hand)
  local t = {}
  for i = 1, #hand do t[i] = hand[i].rank or hand[i].label or '?' end
  return table.concat(t, ',')
end
local function countRank(hand, r)
  local n = 0
  for i = 1, #hand do if hand[i].rank == r then n = n + 1 end end
  return n
end
local function hasRank(hand, r)
  for i = 1, #hand do if hand[i].rank == r then return true end end
  return false
end
local function deckRanks(d)
  local t = {}
  for i = 1, #d.drawPile do t[i] = d.drawPile[i].rank or '?' end
  return table.concat(t, ',')
end

-- 调试：BAR_DEBUG=1 时打印状态迁移后退出
if os.getenv('BAR_DEBUG') == '1' then
  local g = newGame()
  g:action('bar_begin'); g:flush()
  local steps = 0
  while steps < 140 do
    steps = steps + 1
    local s = g.state.state
    local b = g.state.bar
    print(string.format('%3d state=%-12s round=%s cups=%s remain=%s hand=%s n=%s stood=%s busted=%s q=%s', steps, tostring(s), tostring(b and b.round), tostring(b and b.cupCount), tostring(b and BarMode.totalRemaining(b)), tostring(BJ.handTotal(g.state.player.hand)), tostring(#g.state.player.hand), tostring(g.state.player.stood), tostring(g.state.player.busted), tostring(#g._g.queue)))
    if s == 'bar_gift' then g:action('bar_gift_pick', 1)
    elseif s == 'bar_brief' then g:action('bar_begin')
    elseif s == 'player' then
      local ok2, err2
      if BJ.handTotal(g.state.player.hand) < 15 and #g.state.player.hand < 12 and not g.state.player.cageBlocked then ok2, err2 = g:action('hit') else ok2, err2 = g:action('stand') end
      if not ok2 then print('     act[fail] ' .. tostring(err2) .. ' cage=' .. tostring(g.state.player.cageBlocked) .. ' dp=' .. #g.state.deck.drawPile .. ' disc=' .. #g.state.deck.discardPile .. ' rem=' .. #g.state.deck.removed) end
    elseif s == 'result' then g:action('continue')
    elseif s == 'dealer' then g:flush()
    else break end
    g:flush()
  end
  os.exit(0)
end

-- ===================== 34 技能 =====================

check('skill redraw_hand', function()
  local g = newGame(); enterPlayer(g)
  local cup = armCup(g, 'redraw_hand')
  field(g, {'7','8','9','10'}, {'5','6'}, {'3','4'})
  local ok, err = g:action('bar_ability', { id = cup.drink })
  if not ok then return false, tostring(err) end
  if #g.state.player.hand ~= 2 then return false, 'hand=' .. labels(g.state.player.hand) end
  if not hasRank(g.state.player.hand, '7') or not hasRank(g.state.player.hand, '8') then
    return false, 'did not draw new cards: ' .. labels(g.state.player.hand)
  end
  if #g.state.deck.discardPile ~= 2 then return false, 'discard=' .. tostring(#g.state.deck.discardPile) end
  return requireAudit(g)
end)

check('skill swap_hand_card (two-step)', function()
  local g = newGame(); enterPlayer(g)
  local cup = armCup(g, 'swap_hand_card')
  field(g, {'7'}, {'5'}, {'3','4'})
  local ok, err = g._g:bar_ability({ id = cup.drink })
  if not ok then return false, 'begin ' .. tostring(err) end
  if g.state.state ~= 'bar_pick' or g.state.bar.pending.step ~= 1 then return false, 'no step1' end
  local okp = g._g:bar_pick({ index = 1 })
  if not okp then return false, 'pick1 failed' end
  local p = g.state.bar.pending
  if p.step ~= 2 or #p.candidates == 0 then return false, 'no step2 candidates' end
  local ci
  for i = 1, #p.candidates do
    local c = p.candidates[i].card
    if c and c.rank == '9' then ci = i; break end
  end
  if not ci then return false, 'roster missing 9' end
  if not g._g:bar_pick({ index = ci }) then return false, 'pick2 failed' end
  if not g._g:bar_confirm() then return false, 'confirm failed' end
  if g.state.player.hand[1].rank ~= '9' then return false, 'hand=' .. labels(g.state.player.hand) end
  if g.state.bar.usedAbilityThisRound ~= true then return false, 'not marked used' end
  return requireAudit(g)
end)

check('skill peek_sink_pick (checklist)', function()
  local g = newGame(); enterPlayer(g)
  local cup = armCup(g, 'peek_sink_pick')
  field(g, {'7','8','9','10'}, {'5'}, {'3','4'})
  local ok, err = g._g:bar_ability({ id = cup.drink })
  if not ok then return false, 'begin ' .. tostring(err) end
  local p = g.state.bar.pending
  if g.state.state ~= 'bar_pick' or #p.candidates ~= 3 then return false, 'candidates=' .. tostring(#p.candidates) end
  if not (p.candidates[1].card.revealed and p.candidates[3].card.revealed) then return false, 'not revealed' end
  if not g._g:bar_pick({ index = 2 }) then return false, 'toggle failed' end
  if not g._g:bar_confirm() then return false, 'confirm failed' end
  local d = g.state.deck
  if #d.drawPile ~= 4 then return false, 'draw=' .. deckRanks(d) end
  if d.drawPile[#d.drawPile].rank ~= '8' then return false, '8 not sunk: ' .. deckRanks(d) end
  return requireAudit(g)
end)

check('skill burn_half', function()
  local g = newGame(); enterPlayer(g)
  local cup = armCup(g, 'burn_half')
  field(g, {'1','2','3','4','5','6','7','8','9','10'}, {'K'}, {'3','4'})
  local ok, err = g:action('bar_ability', { id = cup.drink })
  if not ok then return false, tostring(err) end
  if #g.state.deck.drawPile ~= 5 then return false, 'draw=' .. tostring(#g.state.deck.drawPile) end
  if #g.state.deck.removed ~= 5 then return false, 'removed=' .. tostring(#g.state.deck.removed) end
  return requireAudit(g)
end)

check('skill duplicate_lowest', function()
  local g = newGame(); enterPlayer(g)
  local cup = armCup(g, 'duplicate_lowest')
  field(g, {'7'}, {'5','9'}, {'3','4'})
  local ok, err = g:action('bar_ability', { id = cup.drink })
  if not ok then return false, tostring(err) end
  if #g.state.player.hand ~= 3 then return false, 'hand=' .. labels(g.state.player.hand) end
  if countRank(g.state.player.hand, '5') ~= 2 then return false, 'no clone: ' .. labels(g.state.player.hand) end
  return requireAudit(g)
end)

check('skill dealer_stop', function()
  local g = newGame(); enterPlayer(g)
  local cup = armCup(g, 'dealer_stop')
  field(g, {'7'}, {'5'}, {'3','4'})
  local ok, err = g:action('bar_ability', { id = cup.drink })
  if not ok then return false, tostring(err) end
  if g.state.dealer.forcedStand ~= true then return false, 'forcedStand not set' end
  return requireAudit(g)
end)

check('skill discard_highest', function()
  local g = newGame(); enterPlayer(g)
  local cup = armCup(g, 'discard_highest')
  field(g, {'7'}, {'5','9'}, {'3','4'})
  local ok, err = g:action('bar_ability', { id = cup.drink })
  if not ok then return false, tostring(err) end
  if #g.state.player.hand ~= 1 or g.state.player.hand[1].rank ~= '5' then
    return false, 'hand=' .. labels(g.state.player.hand)
  end
  if #g.state.deck.discardPile ~= 1 then return false, 'discard=' .. tostring(#g.state.deck.discardPile) end
  return requireAudit(g)
end)

check('skill swap_with_dealer (two-step, no discard)', function()
  local g = newGame(); enterPlayer(g)
  local cup = armCup(g, 'swap_with_dealer')
  field(g, {'7'}, {'5'}, {'3','9'})
  local puid = g.state.player.hand[1].uid
  local duid = g.state.dealer.hand[2].uid
  local ok, err = g._g:bar_ability({ id = cup.drink })
  if not ok then return false, 'begin ' .. tostring(err) end
  if not g._g:bar_pick({ index = 1 }) then return false, 'pick1 failed' end
  local p = g.state.bar.pending
  if p.step ~= 2 or #p.candidates ~= 1 then return false, 'candidates=' .. tostring(#p.candidates) end
  if not g._g:bar_pick({ index = 1 }) then return false, 'pick2 failed' end
  if not g._g:bar_confirm() then return false, 'confirm failed' end
  if g.state.player.hand[1].rank ~= '9' or g.state.dealer.hand[2].rank ~= '5' then
    return false, 'swap wrong: P=' .. labels(g.state.player.hand) .. ' D=' .. labels(g.state.dealer.hand)
  end
  if g.state.player.hand[1].uid ~= duid or g.state.dealer.hand[2].uid ~= puid then
    return false, 'UID not preserved'
  end
  if #g.state.deck.discardPile ~= 0 then return false, 'must not discard' end
  return requireAudit(g)
end)

check('skill discard_random', function()
  local g = newGame(); enterPlayer(g)
  local cup = armCup(g, 'discard_random')
  field(g, {'7'}, {'5','9'}, {'3','4'})
  local ok, err = g:action('bar_ability', { id = cup.drink })
  if not ok then return false, tostring(err) end
  if #g.state.player.hand ~= 1 then return false, 'hand=' .. labels(g.state.player.hand) end
  if #g.state.deck.discardPile ~= 1 then return false, 'discard=' .. tostring(#g.state.deck.discardPile) end
  return requireAudit(g)
end)

check('skill pick_from_champion (pick)', function()
  local g = newGame(); enterPlayer(g)
  local cup = armCup(g, 'pick_from_champion')
  field(g, {'7'}, {'5'}, {'3','4'})
  g.state.championCards = { DT.mk({rank='K',suit='H',kind='champion'}), DT.mk({rank='Q',suit='H',kind='champion'}), DT.mk({rank='J',suit='H',kind='champion'}) }
  local ok, err = g._g:bar_ability({ id = cup.drink })
  if not ok then return false, 'begin ' .. tostring(err) end
  local p = g.state.bar.pending
  if #p.candidates ~= 3 then return false, 'candidates=' .. tostring(#p.candidates) end
  if not g._g:bar_pick({ index = 2 }) then return false, 'pick failed' end
  if not g._g:bar_confirm() then return false, 'confirm failed' end
  if #g.state.player.hand ~= 2 then return false, 'hand=' .. labels(g.state.player.hand) end
  if not hasRank(g.state.player.hand, 'Q') then return false, 'did not take chosen card: ' .. labels(g.state.player.hand) end
  return requireAudit(g)
end)

check('skill take_dealer_highest_sink', function()
  local g = newGame(); enterPlayer(g)
  local cup = armCup(g, 'take_dealer_highest_sink')
  field(g, {'7'}, {'5'}, {'3','9','5'})
  local ok, err = g:action('bar_ability', { id = cup.drink })
  if not ok then return false, tostring(err) end
  if #g.state.dealer.hand ~= 2 then return false, 'dealer=' .. labels(g.state.dealer.hand) end
  local d = g.state.deck
  if d.drawPile[#d.drawPile].rank ~= '9' then return false, 'not sunk: ' .. deckRanks(d) end
  return requireAudit(g)
end)

check('skill give_lowest_to_dealer', function()
  local g = newGame(); enterPlayer(g)
  local cup = armCup(g, 'give_lowest_to_dealer')
  field(g, {'7'}, {'5','9'}, {'3','7'})
  local ok, err = g:action('bar_ability', { id = cup.drink })
  if not ok then return false, tostring(err) end
  if #g.state.player.hand ~= 1 or g.state.player.hand[1].rank ~= '9' then
    return false, 'player=' .. labels(g.state.player.hand)
  end
  if #g.state.dealer.hand ~= 3 or g.state.dealer.hand[3].rank ~= '5' then
    return false, 'dealer=' .. labels(g.state.dealer.hand)
  end
  return requireAudit(g)
end)

check('skill dealer_last_sink_draw', function()
  local g = newGame(); enterPlayer(g)
  local cup = armCup(g, 'dealer_last_sink_draw')
  field(g, {'7'}, {'5'}, {'3','9','5'})
  local ok, err = g:action('bar_ability', { id = cup.drink })
  if not ok then return false, tostring(err) end
  if #g.state.dealer.hand ~= 3 then return false, 'dealer=' .. labels(g.state.dealer.hand) end
  if g.state.dealer.hand[3].rank ~= '7' then return false, 'no redraw: ' .. labels(g.state.dealer.hand) end
  local d = g.state.deck
  if d.drawPile[#d.drawPile].rank ~= '5' then return false, '5 not sunk: ' .. deckRanks(d) end
  return requireAudit(g)
end)

check('skill dealer_extra_up', function()
  local g = newGame(); enterPlayer(g)
  local cup = armCup(g, 'dealer_extra_up')
  field(g, {'7'}, {'5'}, {'3','9'})
  local ok, err = g:action('bar_ability', { id = cup.drink })
  if not ok then return false, tostring(err) end
  if #g.state.dealer.hand ~= 3 then return false, 'dealer=' .. tostring(#g.state.dealer.hand) end
  return requireAudit(g)
end)

check('skill dealer_lowest_sink_draw', function()
  local g = newGame(); enterPlayer(g)
  local cup = armCup(g, 'dealer_lowest_sink_draw')
  field(g, {'7'}, {'5'}, {'3','9','5'})
  local ok, err = g:action('bar_ability', { id = cup.drink })
  if not ok then return false, tostring(err) end
  local d = g.state.deck
  if d.drawPile[#d.drawPile].rank ~= '5' then return false, 'lowest not sunk: ' .. deckRanks(d) end
  if #g.state.dealer.hand ~= 3 then return false, 'dealer=' .. tostring(#g.state.dealer.hand) end
  return requireAudit(g)
end)

check('skill dealer_fill_to_2', function()
  local g = newGame(); enterPlayer(g)
  local cup = armCup(g, 'dealer_fill_to_2')
  field(g, {'7','8'}, {'5'}, {'3','9'})
  local ok, err = g:action('bar_ability', { id = cup.drink })
  if not ok then return false, tostring(err) end
  if #g.state.dealer.hand < 3 then return false, 'dealer=' .. labels(g.state.dealer.hand) end
  return requireAudit(g)
end)

check('skill dealer_draw_1', function()
  local g = newGame(); enterPlayer(g)
  local cup = armCup(g, 'dealer_draw_1')
  field(g, {'7'}, {'5'}, {'3','9'})
  local ok, err = g:action('bar_ability', { id = cup.drink })
  if not ok then return false, tostring(err) end
  if #g.state.dealer.hand ~= 3 then return false, 'dealer=' .. tostring(#g.state.dealer.hand) end
  return requireAudit(g)
end)

check('skill dealer_draw_2', function()
  local g = newGame(); enterPlayer(g)
  local cup = armCup(g, 'dealer_draw_2')
  field(g, {'7','8'}, {'5'}, {'3','9'})
  local ok, err = g:action('bar_ability', { id = cup.drink })
  if not ok then return false, tostring(err) end
  if #g.state.dealer.hand ~= 4 then return false, 'dealer=' .. tostring(#g.state.dealer.hand) end
  return requireAudit(g)
end)

check('skill dealer_copy_last', function()
  local g = newGame(); enterPlayer(g)
  local cup = armCup(g, 'dealer_copy_last')
  field(g, {'7'}, {'5'}, {'3','9'})
  local ok, err = g:action('bar_ability', { id = cup.drink })
  if not ok then return false, tostring(err) end
  if #g.state.dealer.hand ~= 3 then return false, 'dealer=' .. labels(g.state.dealer.hand) end
  if countRank(g.state.dealer.hand, '9') ~= 2 then return false, 'no clone: ' .. labels(g.state.dealer.hand) end
  return requireAudit(g)
end)

check('skill dealer_draw_2_stop', function()
  local g = newGame(); enterPlayer(g)
  local cup = armCup(g, 'dealer_draw_2_stop')
  field(g, {'7','8'}, {'5'}, {'3','9'})
  local ok, err = g:action('bar_ability', { id = cup.drink })
  if not ok then return false, tostring(err) end
  if #g.state.dealer.hand ~= 4 then return false, 'dealer=' .. tostring(#g.state.dealer.hand) end
  if g.state.dealer.forcedStand ~= true then return false, 'forcedStand not set' end
  return requireAudit(g)
end)

check('skill deck_sort_asc', function()
  local g = newGame(); enterPlayer(g)
  local cup = armCup(g, 'deck_sort_asc')
  field(g, {'9','5','7'}, {'K'}, {'3','4'})
  local ok, err = g:action('bar_ability', { id = cup.drink })
  if not ok then return false, tostring(err) end
  local r = deckRanks(g.state.deck)
  if r ~= '5,7,9' then return false, 'sorted=' .. r end
  return requireAudit(g)
end)

check('skill sink_top_5', function()
  local g = newGame(); enterPlayer(g)
  local cup = armCup(g, 'sink_top_5')
  field(g, {'1','2','3','4','5','6','7'}, {'K'}, {'3','4'})
  local ok, err = g:action('bar_ability', { id = cup.drink })
  if not ok then return false, tostring(err) end
  local d = g.state.deck
  if #d.drawPile ~= 7 then return false, 'draw=' .. tostring(#d.drawPile) end
  if d.drawPile[1].rank ~= '6' or d.drawPile[#d.drawPile].rank ~= '5' then
    return false, 'wrong order: ' .. deckRanks(d)
  end
  return requireAudit(g)
end)

check('skill deck_rebuild_shuffle', function()
  local g = newGame(); enterPlayer(g)
  local cup = armCup(g, 'deck_rebuild_shuffle')
  field(g, {'5','6','7'}, {'K'}, {'3','4'})
  local ok, err = g:action('bar_ability', { id = cup.drink })
  if not ok then return false, tostring(err) end
  if #g.state.deck.drawPile ~= 100 then return false, 'draw=' .. tostring(#g.state.deck.drawPile) end
  if #g.state.deck.discardPile ~= 3 then return false, 'discard=' .. tostring(#g.state.deck.discardPile) end
  return requireAudit(g)
end)

check('skill dealer_draw_1_give_random', function()
  local g = newGame(); enterPlayer(g)
  local cup = armCup(g, 'dealer_draw_1_give_random')
  field(g, {'7'}, {'5'}, {'3','9'})
  local ok, err = g:action('bar_ability', { id = cup.drink })
  if not ok then return false, tostring(err) end
  if #g.state.player.hand ~= 0 then return false, 'player should have given card: ' .. labels(g.state.player.hand) end
  if #g.state.dealer.hand ~= 4 then return false, 'dealer=' .. labels(g.state.dealer.hand) end
  if not hasRank(g.state.dealer.hand, '5') then return false, 'dealer missing 5: ' .. labels(g.state.dealer.hand) end
  return requireAudit(g)
end)

check('skill swap_dealer_lowest_with_draw', function()
  local g = newGame(); enterPlayer(g)
  local cup = armCup(g, 'swap_dealer_lowest_with_draw')
  field(g, {'7','8'}, {'5'}, {'3','9','5'})
  local ok, err = g:action('bar_ability', { id = cup.drink })
  if not ok then return false, tostring(err) end
  if g.state.dealer.hand[3].rank ~= '7' then return false, 'dealer=' .. labels(g.state.dealer.hand) end
  if g.state.deck.drawPile[1].rank ~= '5' then return false, 'old low not on top: ' .. deckRanks(g.state.deck) end
  return requireAudit(g)
end)

check('skill dealer_draw_3', function()
  local g = newGame(); enterPlayer(g)
  local cup = armCup(g, 'dealer_draw_3')
  field(g, {'7','8','6'}, {'5'}, {'3','9'})
  local ok, err = g:action('bar_ability', { id = cup.drink })
  if not ok then return false, tostring(err) end
  if #g.state.dealer.hand ~= 5 then return false, 'dealer=' .. tostring(#g.state.dealer.hand) end
  return requireAudit(g)
end)

check('skill deck_remove_random_10', function()
  local g = newGame(); enterPlayer(g)
  local cup = armCup(g, 'deck_remove_random_10')
  local cards = {}
  for i = 1, 20 do cards[i] = tostring(i) end
  field(g, cards, {'K'}, {'3','4'})
  local ok, err = g:action('bar_ability', { id = cup.drink })
  if not ok then return false, tostring(err) end
  if #g.state.deck.drawPile ~= 10 then return false, 'draw=' .. tostring(#g.state.deck.drawPile) end
  if #g.state.deck.removed ~= 10 then return false, 'removed=' .. tostring(#g.state.deck.removed) end
  return requireAudit(g)
end)

check('skill dealer_draw_highest', function()
  local g = newGame(); enterPlayer(g)
  local cup = armCup(g, 'dealer_draw_highest')
  field(g, {'5','10','3'}, {'K'}, {'3','9'})
  local ok, err = g:action('bar_ability', { id = cup.drink })
  if not ok then return false, tostring(err) end
  if not hasRank(g.state.dealer.hand, '10') then return false, 'no highest: ' .. labels(g.state.dealer.hand) end
  if #g.state.deck.drawPile ~= 2 then return false, 'draw=' .. deckRanks(g.state.deck) end
  return requireAudit(g)
end)

check('skill dealer_draw_until_21', function()
  local g = newGame(); enterPlayer(g)
  local cup = armCup(g, 'dealer_draw_until_21')
  field(g, {'10','2','2'}, {'K'}, {'3','9'})
  local ok, err = g:action('bar_ability', { id = cup.drink })
  if not ok then return false, tostring(err) end
  local t = BJ.handTotal(g.state.dealer.hand)
  if t < 21 then return false, 'total=' .. tostring(t) end
  return requireAudit(g)
end)

check('skill deck_insert_5_tens', function()
  local g = newGame(); enterPlayer(g)
  local cup = armCup(g, 'deck_insert_5_tens')
  field(g, {'1','2','3','4','5'}, {'K'}, {'3','4'})
  local ok, err = g:action('bar_ability', { id = cup.drink })
  if not ok then return false, tostring(err) end
  if #g.state.deck.drawPile ~= 10 then return false, 'draw=' .. tostring(#g.state.deck.drawPile) end
  local n10 = 0
  for i = 1, #g.state.deck.drawPile do
    if g.state.deck.drawPile[i].rank == '10' then n10 = n10 + 1 end
  end
  if n10 ~= 5 then return false, 'tens=' .. tostring(n10) end
  return requireAudit(g)
end)

check('skill dealer_fill_to_player_count', function()
  local g = newGame(); enterPlayer(g)
  local cup = armCup(g, 'dealer_fill_to_player_count')
  field(g, {'7','8'}, {'1','2','3'}, {'3','9'})
  local ok, err = g:action('bar_ability', { id = cup.drink })
  if not ok then return false, tostring(err) end
  if #g.state.dealer.hand - 1 < 3 then return false, 'dealer=' .. labels(g.state.dealer.hand) end
  return requireAudit(g)
end)

check('skill dealer_duplicate_ups', function()
  local g = newGame(); enterPlayer(g)
  local cup = armCup(g, 'dealer_duplicate_ups')
  field(g, {'7','8'}, {'5'}, {'3','9','5'})
  local ok, err = g:action('bar_ability', { id = cup.drink })
  if not ok then return false, tostring(err) end
  if #g.state.dealer.hand ~= 5 then return false, 'dealer=' .. labels(g.state.dealer.hand) end
  if countRank(g.state.dealer.hand, '9') ~= 2 or countRank(g.state.dealer.hand, '5') ~= 2 then
    return false, 'not duplicated: ' .. labels(g.state.dealer.hand)
  end
  return requireAudit(g)
end)

check('skill deck_compress_top_half', function()
  local g = newGame(); enterPlayer(g)
  local cup = armCup(g, 'deck_compress_top_half')
  field(g, {'1','2','3','4'}, {'K'}, {'3','4'})
  local ok, err = g:action('bar_ability', { id = cup.drink })
  if not ok then return false, tostring(err) end
  local d = g.state.deck
  if #d.drawPile ~= 2 then return false, 'draw=' .. deckRanks(d) end
  if not hasRank(d.drawPile, '4') or not hasRank(d.drawPile, '3') then return false, 'kept wrong half: ' .. deckRanks(d) end
  if #d.removed ~= 2 then return false, 'removed=' .. tostring(#d.removed) end
  return requireAudit(g)
end)

check('skill dealer_fill_to_3', function()
  local g = newGame(); enterPlayer(g)
  local cup = armCup(g, 'dealer_fill_to_3')
  field(g, {'7','8'}, {'5'}, {'3','9'})
  local ok, err = g:action('bar_ability', { id = cup.drink })
  if not ok then return false, tostring(err) end
  if #g.state.dealer.hand - 1 < 3 then return false, 'dealer=' .. labels(g.state.dealer.hand) end
  return requireAudit(g)
end)

-- ===================== 规则 / 费用 / 限制 =====================

check('rule unknown skill fails (no silent success)', function()
  local g = newGame(); enterPlayer(g)
  local def = findDef('redraw_hand')
  local cup = BarMode.newCup(def)
  cup.id = def.id; cup.drink = def.id; cup.buffLeft = 5
  cup.ability = { special = 'definitely_not_a_skill', interaction = 'instant' }
  local b = g.state.bar
  b.cups = { cup }; b.cupCount = 1; b.offered[def.id] = true; b.usedAbilityThisRound = false
  g.state.state = 'player'
  local ok, err = g:action('bar_ability', { id = cup.drink })
  if ok then return false, 'unknown skill returned success' end
  if err ~= 'unknown_skill' then return false, 'err=' .. tostring(err) end
  if b.usedAbilityThisRound then return false, 'marked used on failure' end
  return true
end)

check('rule ability locked until drink buff active', function()
  local g = newGame(); enterPlayer(g)
  local cup = armCup(g, 'redraw_hand')
  cup.buffLeft = 0
  local ok, err = g:action('bar_ability', { id = cup.drink })
  if ok then return false, 'used locked skill' end
  if err ~= 'ability_locked' then return false, 'err=' .. tostring(err) end
  return true
end)

check('rule ability once per round', function()
  local g = newGame(); enterPlayer(g)
  local cup = armCup(g, 'discard_random')
  field(g, {'7'}, {'5','9'}, {'3','4'})
  if not g:action('bar_ability', { id = cup.drink }) then return false, 'first use failed' end
  local ok, err = g:action('bar_ability', { id = cup.drink })
  if ok then return false, 'second use in same round succeeded' end
  if err ~= 'ability_used' then return false, 'err=' .. tostring(err) end
  return requireAudit(g)
end)

check('rule two-step cancel does not consume ability', function()
  local g = newGame(); enterPlayer(g)
  local cup = armCup(g, 'swap_hand_card')
  field(g, {'7'}, {'5'}, {'3','4'})
  if not g._g:bar_ability({ id = cup.drink }) then return false, 'begin failed' end
  if not g._g:bar_pick({ cancel = true }) then return false, 'cancel failed' end
  if g.state.state ~= 'player' or g.state.bar.pending ~= nil then return false, 'not cleared' end
  if g.state.bar.usedAbilityThisRound then return false, 'cancel consumed ability' end
  if not g:action('bar_ability', { id = cup.drink }) then return false, 'reuse after cancel failed' end
  return requireAudit(g)
end)

check('rule hand cap 12 blocks duplicate_lowest', function()
  local g = newGame(); enterPlayer(g)
  local cup = armCup(g, 'duplicate_lowest')
  local hand = {}
  for i = 1, 12 do hand[i] = tostring(i) end
  field(g, {'7'}, hand, {'3','4'})
  local ok, err = g:action('bar_ability', { id = cup.drink })
  if ok then return false, 'exceeded hand cap' end
  if err ~= 'hand_full' then return false, 'err=' .. tostring(err) end
  if #g.state.player.hand ~= 12 then return false, 'hand mutated' end
  return requireAudit(g)
end)

check('rule hand cap 12 blocks pick_from_champion confirm', function()
  local g = newGame(); enterPlayer(g)
  local cup = armCup(g, 'pick_from_champion')
  local hand = {}
  for i = 1, 12 do hand[i] = tostring(i) end
  field(g, {'7'}, hand, {'3','4'})
  g.state.championCards = { DT.mk({rank='K',suit='H',kind='champion'}) }
  if not g._g:bar_ability({ id = cup.drink }) then return false, 'begin failed' end
  if not g._g:bar_pick({ index = 1 }) then return false, 'pick failed' end
  local ok, err = g._g:bar_confirm()
  if ok then return false, 'confirmed over hand cap' end
  if err ~= 'hand_full' then return false, 'err=' .. tostring(err) end
  return requireAudit(g)
end)

check('rule drink costs 1 mouth and unlocks buff 5', function()
  local g = newGame(); enterPlayer(g)
  local b = g.state.bar
  local cup = b.cups[1]
  local before = b.cups[1].mouth
  if not g:action('bar_drink', cup.drink) then return false, 'drink failed' end
  if cup.mouth ~= before + 1 then return false, 'mouth=' .. tostring(cup.mouth) end
  if cup.buffLeft ~= 5 then return false, 'buffLeft=' .. tostring(cup.buffLeft) end
  return true
end)

check('rule 5-round buff counts down and expires', function()
  local b = { cups = { { drink = 'x', mouth = 0, buffLeft = 5 } } }
  for i = 1, 4 do
    local e = BarMode.tickBuffs(b)
    if #e ~= 0 then return false, 'expired early at tick ' .. i end
    if b.cups[1].buffLeft ~= 5 - i then return false, 'buff=' .. tostring(b.cups[1].buffLeft) end
  end
  local e = BarMode.tickBuffs(b)
  if #e ~= 1 then return false, 'did not expire on 5th tick' end
  if b.cups[1].buffLeft ~= 0 then return false, 'buff not zero' end
  return true
end)

check('rule 6 cup cap', function()
  local g = newGame()
  local b = g.state.bar
  for i = 1, #Cocktails.LIST do
    if b.cupCount >= 6 then break end
    BarMode.addCup(b, Cocktails.LIST[i])
  end
  if b.cupCount ~= 6 then return false, 'cupCount=' .. tostring(b.cupCount) end
  local extra = nil
  for i = 1, #Cocktails.LIST do
    if not b.offered[Cocktails.LIST[i].id] then extra = Cocktails.LIST[i]; break end
  end
  local cup, err = BarMode.addCup(b, extra)
  if cup then return false, '7th cup accepted' end
  if err ~= 'cups_full' then return false, 'err=' .. tostring(err) end
  return true
end)

check('rule round 1 pity gift', function()
  local g = newGame()
  g:action('bar_begin')
  g:flush()
  if g.state.state ~= 'bar_gift' then return false, 'state=' .. tostring(g.state.state) end
  if #g.state.bar.pendingGift ~= 3 then return false, 'options=' .. tostring(#g.state.bar.pendingGift) end
  return true
end)

check('rule pity round 20 fires even at 0 chance', function()
  local g = newGame(); enterPlayer(g)
  local b = g.state.bar
  b.round = 19
  b.giftChance = 0
  b.usedAbilityThisRound = false
  g._g:barBeginRound()
  if b.round ~= 20 then return false, 'round=' .. tostring(b.round) end
  if g.state.state ~= 'bar_gift' then return false, 'state=' .. tostring(g.state.state) end
  return true
end)

check('rule successful gift resets prob to 0.01', function()
  local g = newGame()
  local b = g.state.bar
  b.giftChance = 0.5
  if not g:action('bar_begin') then return false, 'begin failed' end
  if g.state.state == 'bar_gift' then
    if not g:action('bar_gift_pick', 1) then return false, 'pick failed' end
  end
  if math.abs(b.giftChance - BarMode.GIFT_BASE) > 1e-9 then
    return false, 'prob=' .. tostring(b.giftChance)
  end
  return true
end)

check('rule win adds 0.005 to prob', function()
  local g = newGame(); enterPlayer(g)
  local b = g.state.bar
  b.giftChance = 0.10
  b.round = 3
  g.state.result = { outcome = 'player' }
  local nxt = g._g:barAfterRound()
  if nxt ~= 'bar_next' then return false, 'next=' .. tostring(nxt) end
  if math.abs(b.giftChance - 0.105) > 1e-9 then return false, 'prob=' .. tostring(b.giftChance) end
  return true
end)

check('rule loss resets prob and forces 1 mouth', function()
  local g = newGame(); enterPlayer(g)
  local b = g.state.bar
  local cup = b.cups[1]
  b.giftChance = 0.30
  b.round = 3
  local before = cup.mouth
  g.state.result = { outcome = 'dealer' }
  local nxt = g._g:barAfterRound()
  if math.abs(b.giftChance - BarMode.GIFT_BASE) > 1e-9 then return false, 'prob=' .. tostring(b.giftChance) end
  if cup.mouth ~= before + 1 then return false, 'mouth=' .. tostring(cup.mouth) end
  if nxt ~= 'bar_next' then return false, 'next=' .. tostring(nxt) end
  return true
end)

check('rule empty bar immediate fail', function()
  local g = newGame(); enterPlayer(g)
  local b = g.state.bar
  for i = 1, 5 do g:action('bar_drink', b.cups[1].drink) end
  if g.state.state ~= 'bar_ending' then return false, 'state=' .. tostring(g.state.state) end
  if b.ending ~= 'fail' then return false, 'ending=' .. tostring(b.ending) end
  return true
end)

check('rule ending classification', function()
  local g = newGame()
  local b = g.state.bar
  local function mk(id) return BarMode.newCup(findDef('redraw_hand')) end
  -- date: exactly 1 mouth remaining
  local c1 = BarMode.newCup(findDef('redraw_hand')); c1.mouth = 4
  b.cups = { c1 }
  if BarMode.classify(b) ~= 'date' then return false, 'date got ' .. tostring(BarMode.classify(b)) end
  -- buddies: >0 remaining, not date, not 6 cups
  local c2 = BarMode.newCup(findDef('redraw_hand')); c2.mouth = 0
  local c3 = BarMode.newCup(findDef('redraw_hand'))
  b.cups = { c2, c3 }
  if BarMode.classify(b) ~= 'buddies' then return false, 'buddies got ' .. tostring(BarMode.classify(b)) end
  -- fish: 6 cups all with remaining
  b.cups = {}
  for i = 1, 6 do local c = BarMode.newCup(findDef('redraw_hand')); c.mouth = 0; b.cups[i] = c end
  if BarMode.classify(b) ~= 'fish' then return false, 'fish got ' .. tostring(BarMode.classify(b)) end
  -- fail: all empty
  for i = 1, 6 do b.cups[i].mouth = 5 end
  if BarMode.classify(b) ~= 'fail' then return false, 'fail got ' .. tostring(BarMode.classify(b)) end
  return true
end)

check('rule 100 rounds triggers ending, ending set', function()
  local g = newGame(); enterPlayer(g)
  local b = g.state.bar
  b.round = 100
  g.state.result = { outcome = 'player' }
  local nxt = g._g:barAfterRound()
  if nxt ~= 'bar_ending' then return false, 'next=' .. tostring(nxt) end
  g._g:barEnding()
  if b.ending == nil then return false, 'ending nil' end
  return true
end)

check('rule hangover is display-only', function()
  local g = newGame(); enterPlayer(g)
  local b = g.state.bar
  local cup = b.cups[1]
  cup.buffLeft = 1
  cup.mouth = 0
  b.round = 3
  local remainBefore = BarMode.totalRemaining(b)
  local totalBefore = BJ.handTotal(g.state.player.hand)
  g.state.result = { outcome = 'player' }
  g._g:barAfterRound()
  if b.hangover ~= true then return false, 'hangover not set' end
  if type(b.hangoverColor) ~= 'table' or b.hangoverColor.r == nil then return false, 'no hangover color' end
  if BarMode.totalRemaining(b) ~= remainBefore then return false, 'logic: remaining changed' end
  if BJ.handTotal(g.state.player.hand) ~= totalBefore then return false, 'logic: hand changed' end
  return true
end)

check('rule dealer extra cards respect 12 cap', function()
  local g = newGame(); enterPlayer(g)
  local cup = armCup(g, 'dealer_draw_3')
  field(g, {'1','2','3'}, {'5'}, {'3','9','10','K','Q','J'})
  -- fill dealer to 8 cards then draw 3 -> must clamp at 12
  for i = 1, 4 do
    g.state.dealer.hand[#g.state.dealer.hand + 1] = DT.mk({ rank = '2', suit = 'S', kind = 'basic' })
  end
  local ok, err = g:action('bar_ability', { id = cup.drink })
  if ok and #g.state.dealer.hand > 12 then return false, 'dealer exceeded cap: ' .. tostring(#g.state.dealer.hand) end
  return true
end)

-- ===================== 全流程 100 局 drive =====================

check('full bar drive terminates cleanly', function()
  local g = newGame()
  g:action('bar_begin'); g:flush()
  local steps = 0
  local terminal = false
  while steps < 20000 do
    steps = steps + 1
    local s = g.state.state
    if s == 'bar_ending' or s == 'title' or s == 'forceExit' then terminal = true; break end
    if s == 'bar_gift' then
      local ok = g:action('bar_gift_pick', 1)
      if not ok then return false, 'gift rejected at step ' .. steps end
    elseif s == 'bar_brief' then
      g:action('bar_begin')
    elseif s == 'player' then
      local t = BJ.handTotal(g.state.player.hand)
      if t < 15 and #g.state.player.hand < 12 and not g.state.player.cageBlocked then g:action('hit') else g:action('stand') end
    elseif s == 'result' then
      g:action('continue')
    elseif s == 'dealer' then
      g:flush()
    else
      return false, 'unhandled state ' .. tostring(s) .. ' @' .. steps
    end
    g:flush()
  end
  if not terminal then return false, 'no terminal state after ' .. steps .. ' steps' end
  local b = g.state.bar
  if b and b.cups then
    local ext = {}
    for i = 1, #g.state.player.hand do ext[#ext + 1] = g.state.player.hand[i] end
    if g.state.dealer and g.state.dealer.hand then
      for i = 1, #g.state.dealer.hand do ext[#ext + 1] = g.state.dealer.hand[i] end
    end
    local a = g.state.deck:audit(ext)
    if not a.ok then
      return false, table.concat({ 'audit after full run total=', tostring(a.total), ' expected=', tostring(a.expected),
        ' init=', tostring(a.initialTotal), ' synthC=', tostring(a.syntheticCreated), ' synthR=', tostring(a.syntheticRecycled),
        ' dup=', tostring(#(a.duplicates or {})), ' miss=', tostring(#(a.missingUid or {})),
        ' round=', tostring(b and b.round), ' ending=', tostring(b and b.ending), ' st=', tostring(g.state.state),
        ' dp=', tostring(#g.state.deck.drawPile), ' disc=', tostring(#g.state.deck.discardPile), ' rem=', tostring(#g.state.deck.removed),
        ' ph=', tostring(#g.state.player.hand), ' dh=', tostring(#g.state.dealer.hand) }, '')
    end
  end
  if b and b.round and b.round > 100 then return false, 'round exceeded 100: ' .. tostring(b.round) end
  return true
end)

check('long 100-round drive reaches round 100 and conserves all cards', function()
  local g = newGame()
  g:action('bar_begin'); g:flush()
  local steps = 0
  local terminal = false
  while steps < 60000 do
    steps = steps + 1
    local s = g.state.state
    local b = g.state.bar
    if s == 'bar_ending' or s == 'title' or s == 'forceExit' then terminal = true; break end
    if s == 'bar_gift' then
      if not g:action('bar_gift_pick', 1) then return false, 'gift rejected @' .. steps end
    elseif s == 'bar_brief' then
      g:action('bar_begin')
    elseif s == 'player' then
      local p = g.state.player
      local t = BJ.handTotal(p.hand)
      if t < 17 and #p.hand < 12 and not p.cageBlocked then g:action('hit') else g:action('stand') end
    elseif s == 'result' then
      -- 保持调酒栏不空，强制跑到第 100 局
      for i = 1, #b.cups do b.cups[i].mouth = 0 end
      g:action('continue')
    elseif s == 'dealer' then
      g:flush()
    else
      return false, 'unhandled state ' .. tostring(s) .. ' @' .. steps
    end
    g:flush()
  end
  if not terminal then return false, 'no terminal after ' .. steps .. ' steps' end
  local b = g.state.bar
  if not b or b.round < 100 then return false, 'did not reach round 100, got ' .. tostring(b and b.round) .. ' ending=' .. tostring(b and b.ending) end
  if b.round > 100 then return false, 'round over 100: ' .. tostring(b.round) end
  if b.ending == nil then return false, 'ending not set after round 100' end
  local ext = {}
  for i = 1, #g.state.player.hand do ext[#ext + 1] = g.state.player.hand[i] end
  for i = 1, #g.state.dealer.hand do ext[#ext + 1] = g.state.dealer.hand[i] end
  local a = g.state.deck:audit(ext)
  if not a.ok then return false, 'audit over 100 rounds total=' .. tostring(a.total) .. ' expected=' .. tostring(a.expected) end
  return true
end)

check('text: generic has 200 unique non-empty lines', function()
  local g = BarLines.generic
  if #g ~= 200 then return false, 'generic=' .. #g end
  local seen = {}
  for i = 1, #g do
    if type(g[i]) ~= 'string' or #g[i] == 0 then return false, 'empty at ' .. i end
    if seen[g[i]] then return false, 'dup at ' .. i end
    seen[g[i]] = true
  end
  return true
end)

check('text: 34 drinks each >=2 lines, 68 total, all unique', function()
  local total, ids = 0, 0
  local seen = {}
  for _, def in ipairs(Cocktails.LIST) do
    ids = ids + 1
    local list = BarLines.byDrink[def.id]
    if not list then return false, 'missing drink ' .. def.id end
    if #list < 2 then return false, def.id .. ' only ' .. #list end
    for i = 1, #list do
      if type(list[i]) ~= 'string' or #list[i] == 0 then return false, 'empty line ' .. def.id end
      if seen[list[i]] then return false, 'dup line: ' .. list[i] end
      seen[list[i]] = true
    end
    total = total + #list
  end
  if ids ~= 34 then return false, 'drinks=' .. ids end
  if total ~= 68 then return false, 'drinkTotal=' .. total end
  return true
end)

check('text: generic shuffle bag cycles all 200 without repeat, then refills', function()
  local st = { seed = 7 }
  local function r(a, b)
    st.seed = (st.seed * 1103515245 + 12345) % 2147483648
    return a + (st.seed % (b - a + 1))
  end
  local bag = BarLines.shuffleBag(BarLines.generic, r)
  if #bag ~= 200 then return false, 'bag=' .. #bag end
  local seen = {}
  for i = 1, 200 do
    local s = table.remove(bag)
    if seen[s] then return false, 'repeat within cycle at ' .. i end
    seen[s] = true
  end
  if #bag ~= 0 then return false, 'bag not drained: ' .. #bag end
  local bag2 = BarLines.shuffleBag(BarLines.generic, r)
  if #bag2 ~= 200 then return false, 'refill=' .. #bag2 end
  return true
end)

check('text: generic bag and drink bag are independent', function()
  local function r(a, b) return a end
  local gb = BarLines.shuffleBag(BarLines.generic, r)
  local drinkList = BarLines.byDrink['ck_mercury']
  local db = BarLines.shuffleBag(drinkList, r)
  local before = {}
  for i = 1, #gb do before[i] = gb[i] end
  while #db > 0 do table.remove(db) end
  if #db ~= 0 then return false, 'drink bag not drained' end
  if #gb ~= #before then return false, 'generic bag size changed' end
  for i = 1, #before do if gb[i] ~= before[i] then return false, 'generic mutated at ' .. i end end
  local db2 = BarLines.shuffleBag(drinkList, r)
  local set = {}
  for i = 1, #db2 do set[db2[i]] = true end
  for i = 1, #drinkList do if not set[drinkList[i]] then return false, 'refill lost a line' end end
  return true
end)

check('text: bar round draws one generic line; gift draws one drink line', function()
  local g = newGame()
  local b = g.state.bar
  g:action('bar_begin'); g:flush()
  local genBag = b.lineBags['__generic']
  if not genBag then return false, 'generic bag never created' end
  if #genBag ~= 199 then return false, 'generic not drawn exactly once, left=' .. #genBag end
  if g.state.state == 'bar_gift' then
    local ok = g:action('bar_gift_pick', 1)
    if not ok then return false, 'gift pick failed' end
    local key = b.lastGift
    local db = b.lineBags[key]
    if not db then return false, 'drink bag not created for ' .. tostring(key) end
    if #db ~= 1 then return false, 'drink bag not drawn once, left=' .. #db end
    if b.lastLine == nil or b.lastLine == '' then return false, 'empty lastLine' end
  end
  return true
end)

check('text: 100-round run draws exactly one generic line per round with no refill', function()
  local g = newGame()
  g:action('bar_begin'); g:flush()
  local steps = 0
  while steps < 60000 do
    steps = steps + 1
    local s = g.state.state
    local b = g.state.bar
    if s == 'bar_ending' or s == 'title' or s == 'forceExit' then break end
    if s == 'bar_gift' then
      g:action('bar_gift_pick', 1)
    elseif s == 'bar_brief' then
      g:action('bar_begin')
    elseif s == 'player' then
      local p = g.state.player
      if BJ.handTotal(p.hand) < 17 and #p.hand < 12 and not p.cageBlocked then g:action('hit') else g:action('stand') end
    elseif s == 'result' then
      for i = 1, #b.cups do b.cups[i].mouth = 0 end
      g:action('continue')
    elseif s == 'dealer' then
      g:flush()
    else
      return false, 'unhandled ' .. tostring(s) .. ' @' .. steps
    end
    g:flush()
  end
  local b = g.state.bar
  if b.round ~= 100 then return false, 'round=' .. tostring(b.round) end
  local left = #(b.lineBags['__generic'] or {})
  if left ~= 100 then return false, 'generic left=' .. left .. ' round=' .. b.round end
  local drinkDraws = 0
  for k, v in pairs(b.lineBags) do
    if k ~= '__generic' then drinkDraws = drinkDraws + (2 - #v) end
  end
  if drinkDraws <= 0 then return false, 'no drink line drawn in whole run' end
  return true
end)

-- ===================== 汇总 =====================
print(string.format('bar_acceptance: %d passed, %d failed', pass, #failures))
for i = 1, #failures do print('  FAIL ' .. failures[i]) end
os.exit(#failures == 0 and 0 or 1)
