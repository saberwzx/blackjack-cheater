-- tests/run.lua : Blackjack Cheater 核心主测试套件（可由 main.lua --test 调用）
-- 契约：require('tests.run') 返回 function(opts) -> report { pass, fail, errors }
local Game = require('src.game')
local BJ = require('src.blackjack')
local Deck = require('src.deck')
local DT = require('src.deck_types')
local Classes = require('src.classes')
local Marks = require('src.marks')
local Relics = require('src.relics')
local Cocktails = require('src.cocktails')
local Scoring = require('src.scoring')
local Persist = require('src.persist')
local Tutorial = require('src.tutorial')
local Bar = require('src.bar_mode')
local Champion = require('src.champion')
local SI = require('src.shoe_info')
local MarksAcc = require('tests.marks_acceptance')
local ShopAcc = require('tests.shop_acceptance')
local ConsAcc = require('tests.conservation_acceptance')

local R = { pass = 0, fail = 0, errors = {} }

local function check(name, fn)
  local ok, err = pcall(fn)
  if ok then R.pass = R.pass + 1
  else R.fail = R.fail + 1; R.errors[#R.errors + 1] = name .. ': ' .. tostring(err) end
end
local function eq(a, b, msg)
  if a ~= b then error((msg and (msg .. ' ') or '') .. 'expected=' .. tostring(b) .. ' got=' .. tostring(a), 2) end
end
local function truthy(v, msg) if not v then error(msg or 'expected truthy', 2) end end

local function mkRng(seed)
  local s = seed or 987654321
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
  }, files
end
local function new(mode, seed)
  local fs = memfs()
  local g = Game.new({ rng = mkRng(seed), filesystem = fs })
  return g
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

local function runner(opts)
  opts = opts or {}
  R = { pass = 0, fail = 0, errors = {} }

  -- ===================== blackjack.lua =====================
  check('blackjack: A+K is natural', function() truthy(BJ.isBlackjack({ c('A', nil), c('K', 10) })) end)
  check('blackjack: A+A is not natural, total 12', function()
    local h = { c('A', nil), c('A', nil) }
    eq(BJ.handTotal(h), 12); truthy(not BJ.isBlackjack(h))
  end)
  check('blackjack: A+5 is soft 16', function()
    local h = { c('A', nil), c('5', 5) }
    eq(BJ.handTotal(h), 16); truthy(BJ.isSoft(h))
  end)
  check('blackjack: A+5+10 is hard 16', function()
    local h = { c('A', nil), c('5', 5), c('10', 10) }
    eq(BJ.handTotal(h), 16); truthy(not BJ.isSoft(h))
  end)
  check('blackjack: explicit value wins over rank A', function()
    -- 明确 value 的牌以 value 为准（此为若干来源里 A 记 5 的特殊牌），另一张裸 A 记 11 → 16
    eq(BJ.handTotal({ c('A', nil), { rank = 'A', value = 5, kind = 'decimal' } }), 16)
  end)
  check('blackjack: 67 detection', function()
    local s6 = c('6', 6, { is_67 = true, s67_rank = '6' })
    local s7 = c('7', 7, { is_67 = true, s67_rank = '7' })
    truthy(BJ.has67({ s6, s7 }))
    truthy(not BJ.has67({ s6, c('8', 8) }))
  end)

  -- ===================== deck.lua =====================
  check('deck: conservation audit after draws', function()
    local d = Deck.new()
    d:addCards({ c('2', 2), c('3', 3), c('4', 4), c('5', 5) })
    eq(d:audit().ok, true)
    local a = d:draw(); eq(a.rank, '2')
    d:toDiscard(a)
    eq(d:audit().ok, true)
  end)
  check('deck: shuffle-in when draw pile empty', function()
    local d = Deck.new()
    d:addCards({ c('2', 2), c('3', 3) })
    local a = d:draw(); d:toDiscard(a)
    local b = d:draw(); d:toDiscard(b)
    local x = d:draw()
    truthy(x ~= nil, 'expected reshuffle from discard')
    -- x 现在在手中（external），审计牌堆自身应只剩 1 张
    eq(d:audit().total, 1)
    eq(#d.discardPile, 0)
    eq(d.shuffleCount, 1)
    -- 手中牌作为 external 计入审计，总量仍守恒
    eq(d:audit({ x }).ok, true)
  end)
  check('deck: synthetic uid accounting', function()
    local d = Deck.new()
    d:addCards({ c('2', 2) })
    local s = DT.mk({ rank = '6', kind = 's67', is_67 = true, s67_rank = '6', is_synthetic = true })
    d:assignUid(s)
    d:toDiscard(s)
    local rep = d:audit()
    eq(rep.syntheticCreated, 1)
    eq(rep.ok, true)
  end)

  -- ===================== deck_types.lua =====================
  check('deck_types: 12 deck keys', function()
    eq(#DT.ORDER, 12)
    for i = 1, #DT.ORDER do truthy(DT.info(DT.ORDER[i]) ~= nil, DT.ORDER[i]) end
  end)
  check('deck_types: champion pool is 345', function()
    eq(DT.championPoolSize(), 345)
    eq(#DT.championPool(), 345)
  end)
  check('deck_types: champion fixed price 21', function()
    eq(DT.price('champion', 'small', 1), 21)
  end)
  check('deck_types: generated deck sizes', function()
    eq(#DT.generate('decimal', 'small'), 6)
    eq(#DT.generate('negative', 'medium'), 12)
    eq(#DT.generate('multiplier', 'large'), 18)
  end)

  -- ===================== classes.lua =====================
  check('classes: 7 player classes and 7 dealer classes', function()
    eq(#Classes.ORDER, 7)
    for i = 1, 7 do truthy(Classes.get(Classes.ORDER[i]), Classes.ORDER[i]) end
    eq(Classes.get('nope'), nil)
    local n = 0; for _ in pairs(Classes.DEALER) do n = n + 1 end; eq(n, 7)
  end)
  check('classes: randomAnother excludes previous', function()
    for i = 1, 20 do truthy(Classes.randomAnother('saber', mkRng(i)) ~= 'saber') end
  end)
  check('classes: 7 shards', function()
    local n = 0; for _ in pairs(Classes.SHARDS) do n = n + 1 end; eq(n, 7)
  end)

  -- ===================== marks.lua =====================
  check('marks: ink price by stage and thief', function()
    eq(Marks.inkPrice(1, false), 50)
    eq(Marks.inkPrice(2, false), 200)
    eq(Marks.inkPrice(3, true), 500)
  end)
  check('marks: ink limit 5 and consort 7', function()
    eq(Marks.baseLimit(), 5); eq(Marks.limitWith(true), 7)
  end)
  check('marks: new ink and count', function()
    local st = {}
    local card = c('5', 5)
    Marks.newInk(card, { by = 'player', stage = 1 })
    truthy(Marks.isMarked(card))
    truthy(Marks.isInk(card))
  end)

  -- ===================== relics.lua =====================
  check('relics: 139 definitions with unique ids', function()
    local list = Relics.all()
    eq(Relics.count(), 139)
    local seen, dup = {}, 0
    for i = 1, #list do
      local id = list[i].id
      truthy(id ~= nil and id ~= '', 'missing id at ' .. i)
      if seen[id] then dup = dup + 1 end
      seen[id] = true
      truthy(Relics.MAP[id] == list[i], 'MAP mismatch ' .. tostring(id))
    end
    eq(dup, 0)
    local excl = 0
    for _ in pairs(Relics.POOL_EXCLUDED) do excl = excl + 1 end
    eq(excl, 4)
  end)
  check('relics: no unsupported specials with core handlers registered', function()
    local g = new()
    Relics.auditSpecial(g._g:specialHandlerIds())
    eq(#(Relics.unsupported or {}), 0)
  end)

  -- ===================== cocktails.lua =====================
  check('cocktails: 34 unique recipes', function()
    eq(Cocktails.count(), 34)
    local seen, dup = {}, 0
    for i = 1, #Cocktails.LIST do
      local d = Cocktails.LIST[i]
      truthy(d.id ~= nil, 'missing id ' .. i)
      truthy(d.ability and d.ability.special, 'missing ability ' .. tostring(d.id))
      if seen[d.id] then dup = dup + 1 end
      seen[d.id] = true
      truthy(Cocktails.MAP[d.id] == d, 'MAP mismatch ' .. tostring(d.id))
    end
    eq(dup, 0)
  end)

  -- ===================== scoring.lua =====================
  check('scoring: baseFor win/natural/push/loss', function()
    eq(Scoring.baseFor('player', 100, false), 200)
    eq(Scoring.baseFor('player', 100, true), 150)
    eq(Scoring.baseFor('push', 100, false), 100)
    eq(Scoring.baseFor('dealer', 100, false), 0)
  end)
  check('scoring: mult additive, x_mult multiplicative', function()
    local ctx = Scoring.newCtx({ hand = {}, total = 20 }, { hand = {}, total = 18 }, {})
    ctx.forceResult = 'player'
    ctx.score.mult = ctx.score.mult + 1
    ctx.score.x_mult = ctx.score.x_mult * 2
    local w, info = Scoring.finalize(ctx)
    eq(info.outcome, 'player')
    truthy(info.mult >= 2, 'mult')
    truthy(w >= 4 * ctx.bet, 'winnings')
  end)
  check('scoring: 67 applies x67 at the end', function()
    local ctx = Scoring.newCtx({ hand = {}, total = 21, is67 = true }, { hand = {}, total = 18 }, {})
    ctx.forceResult = 'player'
    ctx.is67 = true
    local w = Scoring.finalize(ctx)
    truthy(w >= 2 * ctx.bet * 67, 'expected x67 applied')
  end)

  -- ===================== persist.lua =====================
  check('persist: progress roundtrip', function()
    local fs = memfs()
    local p = Persist.new({ fs = fs, saveDir = 'saves21' })
    local prog = Persist.defaultProgress()
    prog.meta.maxChips = 4242
    eq(p:writeProgress(prog), true)
    local got, loaded = p:readProgress()
    truthy(loaded); eq(got.meta.maxChips, 4242)
  end)
  check('persist: corrupted file falls back to defaults', function()
    local p = Persist.new({ fs = { read = function() return 'not lua !' end, mkdir = function() return true end } })
    local st, loaded = p:readProgress()
    eq(loaded, false); truthy(type(st.meta) == 'table'); truthy(type(st.settings) == 'table')
  end)
  check('persist: backend write rejection surfaces', function()
    local p = Persist.new({ fs = { write = function() return false, 'disk full' end, mkdir = function() return true end } })
    eq(p:writeProgress(Persist.defaultProgress()), false)
  end)

  -- ===================== tutorial.lua =====================
  check('tutorial: exactly 14 phases', function()
    eq(#Tutorial.PHASES, 14)
    local seen = {}
    for i = 1, #Tutorial.PHASES do truthy(not seen[Tutorial.PHASES[i].id], 'dup ' .. tostring(Tutorial.PHASES[i].id)); seen[Tutorial.PHASES[i].id] = true end
  end)
  check('tutorial: requireAction gating', function()
    local t = Tutorial.new()
    -- 前几步是纯文字，推进到第一个 requireAction 步骤再验证门禁
    local guard = 0
    while t:current() and t:current().type ~= 'requireAction' and guard < 20 do
      t:advance(); guard = guard + 1
    end
    local step = t:current()
    truthy(step and step.type == 'requireAction', 'expected a requireAction step')
    local ok, reason = t:advance('bogus')
    truthy(not ok)
    eq(reason, 'require_action')
    eq(t:current().id, step.id, 'rejected advance must not move on')
    local ok2 = t:advance(step.action)
    truthy(ok2, 'the required action should advance')
  end)

  -- ===================== bar_mode.lua =====================
  check('bar_mode: constants and cup lifecycle', function()
    eq(Bar.ROUNDS, 100); eq(Bar.MAX_CUPS, 6); eq(Bar.MOUTHS, 5)
    local s = Bar.newState()
    local cup = Bar.newCup({ id = 'ck_mercury', name = 'M' })
    truthy(cup ~= nil)
  end)
  check('bar_mode: gift pity rounds', function()
    truthy(Bar.isPityRound(1)); truthy(Bar.isPityRound(100)); truthy(not Bar.isPityRound(2))
  end)
  check('bar_mode: ending classification precedence', function()
    local date = { cups = { { mouth = 4 }, { mouth = 5 }, { mouth = 5 }, { mouth = 5 }, { mouth = 5 }, { mouth = 5 } } }
    eq(Bar.classify(date), 'date')
  end)

  -- ===================== champion.lua =====================
  check('champion: requires exactly 36 cards', function()
    eq(Champion.SIZE, 36); eq(Champion.PRICE, 21); eq(Champion.required(), 36)
    local ok = Champion.validate({})
    truthy(not ok)
  end)
  check('champion: expand sizes double/triple', function()
    eq(Champion.EXPAND.small, 1); eq(Champion.EXPAND.medium, 2); eq(Champion.EXPAND.large, 3)
  end)

  -- ===================== game_state: 核心回归 =====================
  check('gs: pushHand tolerates nil card', function()
    local g = new(); local s = g.state
    local ok = g._g:pushHand('player', nil)
    eq(ok, false); eq(#s.player.hand, 0)
  end)
  check('gs: blackhole keeps its own uid and inherits traits, prior card discarded', function()
    local g = new(); local s = g.state
    s.deck = Deck.new()
    local mb = c('5', 5, { is_chip = true, chip_value = 5 }); s.deck:assignUid(mb)
    local bh = DT.mk({ rank = 'X', suit = 'S', kind = 'blackhole', is_blackhole = true }); s.deck:assignUid(bh)
    g._g:pushHand('player', mb)
    g._g:pushHand('player', bh)
    -- 黑洞吸收上一张：被吸收的牌移出，黑洞自身留在手牌，故只剩 1 张
    eq(#s.player.hand, 1)
    local got = s.player.hand[1]
    eq(got.is_blackhole, true, 'is_blackhole')
    eq(got.uid, bh.uid, 'blackhole uid preserved')
    eq(got.absorbed_from, mb.uid, 'absorbed marker')
    eq(got.is_chip, true, 'inherited chip trait')
    local inDiscard = false
    for i = 1, #s.deck.discardPile do if s.deck.discardPile[i].uid == mb.uid then inDiscard = true end end
    truthy(inDiscard, 'prior card discarded')
  end)
  check('gs: opening cage is immune', function()
    local g = new(); local s = g.state
    s.deck = Deck.new()
    local cage = DT.mk({ rank = '6', suit = 'S', kind = 'cage', is_cage = true, value = 6 }); s.deck:assignUid(cage)
    g._g:pushHand('player', cage)
    truthy(s.player.hand[1]._cageImmune)
  end)
  check('gs: hit-drawn cage blocks further hit', function()
    local g = new(); local s = g.state
    s.deck = Deck.new()
    g._g:pushHand('player', c('10', 10))
    g._g:pushHand('player', c('7', 7))
    local cage = DT.mk({ rank = '6', suit = 'S', kind = 'cage', is_cage = true, value = 6 }); s.deck:assignUid(cage)
    g._g:pushHand('player', cage)
    g._g:refreshPlayer()
    eq(s.player.cageBlocked, true)
    s.state = 'player'
    local ok, err = g._g:playerHit()
    eq(ok, false); eq(err, 'action_unavailable')
  end)
  check('gs: Berserker player busts above 25 only', function()
    local g = new(); local s = g.state
    s.playerClass = Classes.getRuntime('berserker')
    s.player.hand = { c('10', 10), c('10', 10), c('3', 3) }
    g._g:refreshPlayer(); eq(s.player.busted, false, '23 not bust')
    s.player.hand = { c('10', 10), c('10', 10), c('6', 6) }
    g._g:refreshPlayer(); eq(s.player.busted, true, '26 bust')
  end)
  check('gs: dealer Lancer/Berserker bust above 25 only', function()
    local g = new(); local s = g.state
    s.dealerClass = Classes.dealerRuntime('lancer')
    s.dealer.hand = { c('10', 10), c('10', 10), c('3', 3) }
    g._g:refreshDealer(); eq(s.dealer.busted, false)
    s.dealer.hand = { c('10', 10), c('10', 10), c('6', 6) }
    g._g:refreshDealer(); eq(s.dealer.busted, true)
    s.dealerClass = Classes.dealerRuntime('saber')
    s.dealer.hand = { c('10', 10), c('10', 10), c('3', 3) }
    g._g:refreshDealer(); eq(s.dealer.busted, true, 'saber busts at 23')
  end)
  check('gs: surrender uses self:relicById', function()
    local g = new(); local s = g.state
    s.state = 'player'; s.bet = 100; s.chips = 1000
    s.player.hand = { c('10', 10), c('5', 5) }
    s.relics[#s.relics + 1] = g._g:makeRelicInstance(Relics.byId('late_surrender'))
    s.relics[#s.relics]._active = true
    g._g:refreshPlayer()
    local ok = g._g:playerSurrender()
    truthy(ok, 'surrender should succeed')
    eq(s.result.halfLoss or s.result.refund, 50)
  end)
  check('gs: fill67 consumes shoe per slot and stops when empty', function()
    local g = new(); local s = g.state
    s.deck = Deck.new()
    s.deck:addCards({ c('2', 2), c('3', 3), c('4', 4), c('5', 5) })
    s.player.hand = { c('6', 6), c('7', 7) }
    s.player.is67 = true
    g._g:fill67()
    -- 每填充位消耗牌靴一张；4 张牌靴靠弃牌堆洗回循环供牌，真实牌始终守恒为 4
    eq(#s.player.hand, 12)
    eq(s.deck.initialTotal, 4)
    eq(s.deck:auditTotal(), 4, 'real cards conserved across draw/discard')
    eq(s.deck.syntheticCreated, 10, 'one synthetic per filled slot')
    local n = #s.player.hand
    for i = 3, n do truthy(s.player.hand[i].uid ~= nil, 'uid ' .. i) end
    -- 完全空靴：不凭空补充
    local g2 = new(); local s2 = g2.state
    s2.deck = Deck.new()
    s2.player.hand = { c('6', 6), c('7', 7) }
    s2.player.is67 = true
    g2._g:fill67()
    eq(#s2.player.hand, 2)
    eq(s2.deck.syntheticCreated, 0)
    eq(s2.player.total, 21)
  end)
  check('gs: cheat D takes exact-needed card out of order', function()
    local g = new(); local s = g.state
    s.dealer.hand = { c('10', 10), c('7', 7) }; s.dealer.total = 17
    s.deck = Deck.new(); s.deck:addCards({ c('9', 9), c('4', 4), c('2', 2) })
    local uid = s.deck.drawPile[1].uid
    s.cheatIntent = { move = 'D', pending = true, executed = false }
    g._g:dealerDrawOne()
    eq(s.dealer.hand[3].rank, '4')
    eq(s.deck.drawPile[1].uid, uid, 'top preserved')
    eq(#s.deck.discardPile, 0, 'no discard')
    truthy(s.cheatIntent.executed)
  end)
  check('gs: false accusation ends player turn and penalizes', function()
    local g = new(); local s = g.state
    s.state = 'player'; s.bet = 100; s.chips = 1000
    s.player.hand = { c('10', 10), c('7', 7) }
    s.dealer.hand = { c('10', 10), c('8', 8) }
    s.cheatIntent = { executed = false }
    truthy(g:action('accuse'))
    g:flush()
    truthy(s.state ~= 'player')
    truthy(s.chips <= 950, 'penalty applied')
  end)
  check('gs: dealer-turn accusation interrupts pending draws', function()
    local g = new(); local s = g.state
    s.state = 'dealer'; s.bet = 100
    s.cheatIntent = { executed = true }
    s.player.hand = { c('10', 10), c('7', 7) }
    s.dealer.hand = { c('10', 10), c('8', 8) }
    local fired = false
    g._g:after(1, function() fired = true end)
    truthy(g:action('accuse'))
    g:flush()
    truthy(not fired, 'stale dealer queue ran')
    truthy(s.result and s.result.outcome == 'player')
  end)
  check('gs: stage 1 does not clear before its final round', function()
    local g = new(); local s = g.state
    s.stage = 1; s.stageTarget = 2000; s.chips = 2500
    s.roundsInStage = 1; s.stageRounds = 15; s.roundsSinceShop = 0
    g._g:scheduleAfterRound()
    truthy(s.afterResult ~= 'stageClear' and s.afterResult ~= 'victory')
  end)
  check('gs: stage 1 clears at round 15 when solvent', function()
    local g = new(); local s = g.state
    s.stage = 1; s.stageTarget = 2000; s.chips = 2500
    s.roundsInStage = 15; s.stageRounds = 15; s.roundsSinceShop = 0
    g._g:scheduleAfterRound(); eq(s.afterResult, 'stageClear')
  end)
  check('gs: stage 3 clears immediately on target', function()
    local g = new(); local s = g.state
    s.stage = 3; s.stageTarget = 2000000; s.chips = 2000000
    s.roundsInStage = 1; s.stageRounds = 30; s.roundsSinceShop = 0
    g._g:scheduleAfterRound()
    truthy(s.afterResult == 'stageClear' or s.afterResult == 'victory')
  end)
  check('gs: autoEndOnBroke=false preserves debt play', function()
    local g = new(); local s = g.state
    s.settings.autoEndOnBroke = false; s.chips = -100; s.roundsInStage = 1
    g._g:scheduleAfterRound()
    truthy(s.afterResult ~= 'forceExit')
  end)
  check('gs: assassin does not disable reading-free cheats', function()
    local g = new(); local s = g.state
    s.stage = 2; s.playerClass = Classes.getRuntime('assassin')
    eq(g._g:cheatChance(), 0.2)
  end)
  check('gs: sidebet insurance on dealer bust pays out', function()
    local g = started('normal', 7)
    local s = g.state
    eq(g:action('bet_set', 100), true)
    eq(g:action('toggle_bust_bet'), true)
    eq(g:action('bet_confirm'), true)
    g:flush()
    truthy(s.bustBet.on, 'bust bet on')
    eq(s.bustBet.amount, 50)
    s.player.hand = { c('10', 10), c('8', 8) }; s.player.stood = true
    s.dealer.hand = { c('10', 10), c('10', 10), c('5', 5) }; s.dealer.holeRevealed = true
    g._g:settle()
    truthy(s.result and s.result.bustBet, 'bustBet result')
    eq(s.result.bustBet.hit, true)
    truthy(s.result.bustBet.payout and s.result.bustBet.payout > 0)
  end)
  check('gs: sidebet with unknown upcard locks max odds 8', function()
    local g = new(); local s = g.state
    s.deck = Deck.new()
    s.bustBet = { on = true, amount = 50, locked = true, odds = nil }
    s.dealer.hand = {}; s.player.total = 18
    g._g:lockBustBetOdds()
    eq(s.bustBet.odds, 8.0)
  end)
  check('gs: shoe odds use full draw pile and keep coverage info', function()
    local g = new(); local s = g.state
    s.deck = Deck.new()
    -- 真实牌靴的标准牌无 value 字段（由 rank 分类），不能用带 value 的测试牌
    local cards = {}
    for i = 1, 60 do cards[i] = c('5', nil) end
    s.deck:addCards(cards)
    s.player.hand = { c('10', nil), c('7', nil) }; s.player.total = 17
    s.dealer.hand = { c('10', nil), c('6', nil) }; s.dealer.difficulty = 1
    s.shoeOpen = true
    g._g:refreshShoe()
    truthy(s.shoe.composition ~= nil)
    truthy(s.shoe.nextBustOdds ~= nil, 'next bust odds from full pile')
    truthy(s.shoe.dealerBustOdds ~= nil, 'dealer bust odds')
    truthy(type(s.shoe.coverageGap) == 'string')
  end)

  check('gs: sidebet accepts p=0 as a known zero-bust line', function()
    local g = new(); local s = g.state
    s.deck = Deck.new(); s.dealer.hand = { c('10', 10), c('6', 6) }; s.player.total = 18
    local SImod = require('src.shoe_info'); local old = SImod.dealerBustOdds
    SImod.dealerBustOdds = function() return 0, { nodes = 0 } end
    s.bustBet = { on = true, amount = 50, locked = true, odds = nil }
    g._g:lockBustBetOdds()
    SImod.dealerBustOdds = old
    eq(s.bustBet.odds, 8.0); eq(s.bustBet.prob, 0); truthy(not s.bustBet.unknown)
  end)
  check('gs: sidebet accepts p=1 and clamps to 1.2', function()
    local g = new(); local s = g.state
    s.deck = Deck.new(); s.dealer.hand = { c('10', 10), c('6', 6) }; s.player.total = 18
    local SImod = require('src.shoe_info'); local old = SImod.dealerBustOdds
    SImod.dealerBustOdds = function() return 1, { nodes = 0 } end
    s.bustBet = { on = true, amount = 50, locked = true, odds = nil }
    g._g:lockBustBetOdds()
    SImod.dealerBustOdds = old
    eq(s.bustBet.prob, 1); eq(s.bustBet.odds, 1.2)
  end)
  check('gs: sidebet budget failure is unknown, odds 8, reason preserved', function()
    local g = new(); local s = g.state
    s.deck = Deck.new(); s.dealer.hand = { c('10', 10), c('6', 6) }; s.player.total = 18
    local SImod = require('src.shoe_info'); local old = SImod.dealerBustOdds
    SImod.dealerBustOdds = function() return nil, { reason = 'budget_exceeded', coverageGap = 'g' } end
    s.bustBet = { on = true, amount = 50, locked = true, odds = nil }
    g._g:lockBustBetOdds()
    SImod.dealerBustOdds = old
    eq(s.bustBet.prob, nil); eq(s.bustBet.odds, 8.0); eq(s.bustBet.unknown, true)
    eq(s.bustBet.oddsInfo.reason, 'budget_exceeded')
  end)
  check('gs: distractor only rolls when the no-cheat branch was taken', function()
    -- 依据 GDD 476-481：先掷是否出千，只有 else（不出千）分支才掷干扰项；
    -- 进入出千分支后即使选中 A/E 被屏蔽放弃，本小局也不再掷干扰项。
    local g = new(); local s = g.state
    s.mode = 'hard'; s.stage = 2
    local gg = g._g
    local oChance, oRchance, oWeighted, oShielded = gg.cheatChance, gg.rchance, gg.rweighted, gg.isCheatShielded
    gg.cheatChance = function() return 0.2 end
    -- 出千分支：选中真招 → 不掷干扰
    gg.rchance = function() return true end
    gg.rweighted = function() return 'B' end
    local it = gg:decideCheat()
    eq(it.move, 'B'); eq(it.pending, true); eq(it.distractor, nil)
    -- 出千分支：A/E 被屏蔽放弃 → 仍属出千分支，不掷干扰
    gg.rweighted = function() return 'A' end
    gg.isCheatShielded = function() return true end
    local it2 = gg:decideCheat()
    eq(it2.move, nil); eq(it2.shielded, true); eq(it2.distractor, nil)
    -- 不出千分支：才掷干扰项
    local calls = 0
    gg.rchance = function() calls = calls + 1; return calls > 1 end
    local it3 = gg:decideCheat()
    eq(it3.move, nil); truthy(it3.distractor ~= nil)
    gg.cheatChance, gg.rchance, gg.rweighted, gg.isCheatShielded = oChance, oRchance, oWeighted, oShielded
  end)
  -- ===================== cheat execution / marks / shop =====================
  check('gs: cheat A replaces hole with needed ace', function()
    local g = started('normal'); local s = g._g.state
    s.mode = 'hard'; s.stage = 2; s.deck = Deck.new()
    s.player.hand = { c('10', 10), c('9', 9) }; s.player.total = 19
    s.dealer.hand = { c('5', 5), c('10', 10) }; s.dealer.holeRevealed = false
    local hole = s.dealer.hand[1]; s.deck:assignUid(hole)
    local intent = { move = 'A' }
    g._g:executeCheatDeal(intent)
    eq(intent.executed, true); eq(intent.tell, 'A')
    eq(s.dealer.hand[1].rank, 'A')
    eq(BJ.handTotal(s.dealer.hand), 21)
    eq(s.deck.discardPile[#s.deck.discardPile].uid, hole.uid)
  end)

  check('gs: cheat E mirrors player first card', function()
    local g = started('normal'); local s = g._g.state
    s.mode = 'hard'; s.stage = 2; s.deck = Deck.new()
    s.player.hand = { c('7', 7), c('9', 9) }; s.player.total = 16
    s.dealer.hand = { c('5', 5), c('6', 6) }
    local pc = s.player.hand[1]; s.deck:assignUid(pc)
    local intent = { move = 'E' }
    g._g:executeCheatDeal(intent)
    eq(intent.executed, true); eq(intent.tell, 'E')
    eq(s.dealer.hand[1].rank, '7')
    truthy(s.dealer.hand[1].uid ~= nil)
    truthy(s.dealer.hand[1].uid ~= pc.uid)
  end)

  check('marks: deterministic discovery penalizes bet x3', function()
    local cc = c('5', 5); Marks.newInk(cc, { by = 'dealer' })
    local st = { dealer = { hand = { cc } }, bet = 100 }
    local r0 = function(a, b) if a == nil then return 0 end return a end
    local roll = Marks.rollDiscovery(st, r0, {})
    eq(roll.count, 1); eq(roll.penalty, 300); eq(roll.keep, false)
    local rollNo = Marks.rollDiscovery(st, function() return 0.5 end, {})
    eq(rollNo.count, 0)
  end)

  check('marks: sharp family halves penalty and may keep', function()
    local cc = c('5', 5); Marks.newInk(cc, { by = 'dealer' })
    local st = { dealer = { hand = { cc } }, bet = 100 }
    local seq = { 0, 0.1 }
    local rr = function(a, b)
      if a == nil then local v = seq[1]; table.remove(seq, 1); return v end
      return a
    end
    local roll = Marks.rollDiscovery(st, rr, { sharpFamily = true })
    eq(roll.count, 1); eq(roll.penalty, 150); eq(roll.half, true); eq(roll.keep, true)
  end)

  check('gs: finalizeRound mark discovery clears cheat intent', function()
    local g = started('normal'); local s = g._g.state
    local cc = c('6', 6); s.deck:assignUid(cc); Marks.newInk(cc, { by = 'dealer' })
    s.dealer.hand = { cc }
    s.bet = 100; s.chips = 1000; s.cheatIntent = { move = 'B' }
    g._g.rng = function(a, b) if a == nil then return 0 end return a end
    local result = { outcome = 'push', winnings = 0, halfLoss = false }
    g._g:finalizeRound(result, false)
    eq(result.marks.discovered, 1)
    eq(s.chips, 700)
    eq(s.cheatIntent, nil)
    eq(Marks.isMarked(cc), false)
  end)

  check('gs: shop opens after five rounds since last shop', function()
    local g = started('normal'); local s = g._g.state
    s.chips = 2500; s.roundsInStage = 3; s.roundsSinceShop = 5; s.supremeClear = false
    g._g:scheduleAfterRound()
    eq(s.afterResult, 'shop')
  end)

  check('gs: refreshShoe keeps dealerBustOddsInfo table on nil result', function()
    local g = started('normal'); local s = g._g.state
    local old = SI.dealerBustOdds
    SI.dealerBustOdds = function() return nil, { reason = 'budget_exceeded', coverageGap = 'gap-x' } end
    s.shoeOpen = true; s.shoe = s.shoe or {}
    g._g:refreshShoe()
    SI.dealerBustOdds = old
    eq(s.shoe.dealerBustOdds, nil)
    eq(s.shoe.dealerBustOddsInfo.reason, 'budget_exceeded')
    truthy(string.find(s.shoe.coverageGap, 'gap%-x') ~= nil)
  end)

  -- ===================== card types / cheat B C =====================
  check('gs: RPS skips totals and resolves rock-paper-scissors', function()
    local g = started('normal'); local s = g._g.state
    s.playerClass = nil; s.dealerClass = nil; s.dealer.holeRevealed = true
    local function rps(sym) return c(sym, 0, { is_rps = true, rps_symbol = sym, kind = 'rps' }) end
    s.player.hand = { rps('rock') }; s.dealer.hand = { rps('scissors') }
    eq(g._g:collectFinalResult(), 'player')
    s.player.hand = { rps('paper') }; s.dealer.hand = { rps('scissors') }
    eq(g._g:collectFinalResult(), 'dealer')
    s.player.hand = { rps('paper') }; s.dealer.hand = { rps('paper') }
    eq(g._g:collectFinalResult(), 'player')
  end)

  check('gs: chip and multiplier cards feed cardBonuses', function()
    local g = started('normal'); local s = g._g.state
    s.player.hand = { c('5', 5, { is_chip = true, chip_value = 5 }), c('X', 0, { is_multiplier = true, mult_bonus = 0.5 }) }
    local chips, mult = g._g:cardBonuses('player')
    eq(chips, 500); eq(mult, 0.5)
  end)

  check('gs: dice card rolls once and freezes its token', function()
    local g = started('normal'); local s = g._g.state
    local d6 = c('D6', 0, { is_dice6 = true })
    s.player.hand = { d6 }
    local chips1 = g._g:cardBonuses('player')
    truthy(d6.dice_token ~= nil); truthy(d6.dice_token >= 1 and d6.dice_token <= 6)
    local chips2 = g._g:cardBonuses('player')
    eq(chips1, chips2)
    eq(chips1, d6.dice_token * 100)
  end)

  check('gs: cheat B replaces drawn card to reach 10/4 target', function()
    local g = started('normal'); local s = g._g.state
    s.mode = 'hard'; s.stage = 2
    s.deck = Deck.new(); s.deck:addCards({ c('2', 2) })
    s.dealer.hand = { c('5', 5), c('6', 6) }; s.dealer.total = 11
    s.cheatIntent = { move = 'B', pending = true }
    local drawn = g._g:dealerDrawOne()
    eq(drawn.rank, '10'); eq(s.cheatIntent.executed, true); eq(s.cheatIntent.tell, 'B')
    eq(s.dealer.hand[#s.dealer.hand].rank, '10')
    local t; for i = #s.fx, 1, -1 do if s.fx[i].kind == 'tell' and s.fx[i].tellKind == 'B' then t = s.fx[i]; break end end
    truthy(t, 'B tell missing'); eq(t.uid, drawn.uid); eq(t.slot, 'dealer')
    truthy(not s._distractorShown, 'real B must not set distractor latch')
  end)

  check('gs: cheat C swaps a low draw for ten and records tell rank', function()
    local g = started('normal'); local s = g._g.state
    s.mode = 'hard'; s.stage = 2
    s.deck = Deck.new(); s.deck:addCards({ c('3', 3) })
    s.dealer.hand = { c('5', 5), c('4', 4) }; s.dealer.total = 9
    s.cheatIntent = { move = 'C', pending = true }
    local drawn = g._g:dealerDrawOne()
    eq(drawn.rank, '10'); eq(s.cheatIntent.executed, true); eq(s.cheatIntent.tell, 'C')
    local last = s.deck.discardPile[#s.deck.discardPile]
    eq(last.rank, '3'); eq(last._tellOldRank, '3')
    local t; for i = #s.fx, 1, -1 do if s.fx[i].kind == 'tell' and s.fx[i].tellKind == 'C' then t = s.fx[i]; break end end
    truthy(t, 'C tell missing'); eq(t.oldRank, '3'); eq(t.uid, drawn.uid); eq(t.slot, 'dealer')
  end)

  check('gs: cheat B does not execute at 17 or above', function()
    local g = started('normal'); local s = g._g.state
    s.mode = 'hard'; s.stage = 2
    s.deck = Deck.new(); s.deck:addCards({ c('2', 2) })
    s.dealer.hand = { c('10', 10), c('7', 7) }; s.dealer.total = 17
    s.cheatIntent = { move = 'B', pending = true }
    local drawn = g._g:dealerDrawOne()
    eq(drawn.rank, '2'); truthy(not s.cheatIntent.executed); eq(s.cheatIntent.tell, nil)
  end)

  local function lastTellIn(s, from, kind)
    for i = #s.fx, from + 1, -1 do
      local e = s.fx[i]
      if e.kind == 'tell' and (kind == nil or e.tellKind == kind) then return e end
    end
    return nil
  end

  check('gs: cheat A emits real tell bound to the new hole uid', function()
    local g = started('normal'); local s = g._g.state
    s.mode = 'hard'; s.stage = 2; s.deck = Deck.new()
    s.player.hand = { c('10', 10), c('9', 9) }; s.player.total = 19
    s.dealer.hand = { c('5', 5), c('10', 10) }; s.dealer.holeRevealed = false
    local intent = { move = 'A' }; local n = #s.fx
    g._g:executeCheatDeal(intent)
    local t = lastTellIn(s, n)
    truthy(t, 'no tell emitted for executed A')
    eq(t.tellKind, 'A'); eq(t.slot, 'hole'); eq(t.uid, s.dealer.hand[1].uid)
    eq(t.card, s.dealer.hand[1])
    truthy(not s._distractorShown, 'real A must not touch distractor latch')
  end)

  check('gs: invalid cheat A emits no tell and does not execute', function()
    local g = started('normal'); local s = g._g.state
    s.mode = 'hard'; s.stage = 2; s.deck = Deck.new()
    s.player.hand = { c('10', 10), c('9', 9) }; s.player.total = 19
    s.dealer.hand = { c('5', 5), c('2', 2) }  -- 可见 2 + 11 = 13 < 19
    local intent = { move = 'A' }; local n = #s.fx
    g._g:executeCheatDeal(intent)
    eq(intent.executed, nil)
    eq(lastTellIn(s, n), nil)
  end)

  check('gs: cheat A counts a visible ace as 11', function()
    local g = started('normal'); local s = g._g.state
    s.mode = 'hard'; s.stage = 2; s.deck = Deck.new()
    s.player.hand = { c('10', 10), c('9', 9) }; s.player.total = 19
    s.dealer.hand = { c('5', 5), c('A', nil) }; s.dealer.holeRevealed = false
    local intent = { move = 'A' }
    g._g:executeCheatDeal(intent)
    eq(intent.executed, true)
    eq(s.dealer.hand[1].rank, '10')  -- 可见 A=11 -> 塞 10
    eq(BJ.handTotal(s.dealer.hand), 21)
  end)

  check('gs: cheat E emits hole tell plus player link uid', function()
    local g = started('normal'); local s = g._g.state
    s.mode = 'hard'; s.stage = 2; s.deck = Deck.new()
    s.player.hand = { c('7', 7), c('9', 9) }; s.player.total = 16
    s.dealer.hand = { c('5', 5), c('6', 6) }
    local pc = s.player.hand[1]; s.deck:assignUid(pc)
    local intent = { move = 'E' }; local n = #s.fx
    g._g:executeCheatDeal(intent)
    local hole, link
    for i = n + 1, #s.fx do
      local e = s.fx[i]
      if e.kind == 'tell' and e.tellKind == 'E' then if e.slot == 'hole' then hole = e else link = e end end
    end
    truthy(hole, 'E hole tell missing'); truthy(link, 'E player link tell missing')
    eq(hole.uid, s.dealer.hand[1].uid); eq(link.uid, pc.uid); eq(link.link, true)
    truthy(s.dealer.hand[1].uid ~= pc.uid)
  end)

  check('gs: cheat D emits tell bound to the out-of-order card', function()
    local g = started('normal'); local s = g._g.state
    s.mode = 'hard'; s.stage = 2
    s.dealer.hand = { c('10', 10), c('7', 7) }; s.dealer.total = 17
    s.deck = Deck.new(); s.deck:addCards({ c('9', 9), c('4', 4), c('2', 2) })
    s.cheatIntent = { move = 'D', pending = true, executed = false }
    local n = #s.fx
    local found = g._g:dealerDrawOne()
    local t = lastTellIn(s, n)
    truthy(t, 'D tell missing'); eq(t.tellKind, 'D'); eq(t.uid, found.uid); eq(t.slot, 'dealer')
  end)

  check('gs: distractor materializes once, bound to a public upcard', function()
    local g = started('normal'); local s = g._g.state
    s.cheatIntent = { move = nil, distractor = 'dA' }
    s.dealer.hand = { c('5', 5), c('10', 10) }
    s.player.hand = { c('7', 7) }
    s.deck:assignUid(s.dealer.hand[1]); s.deck:assignUid(s.dealer.hand[2]); s.deck:assignUid(s.player.hand[1])
    s._distractorShown = nil; local n = #s.fx
    eq(g._g:emitDistractor(), true)
    eq(g._g:emitDistractor(), false)
    local cnt = 0; local t
    for i = n + 1, #s.fx do if s.fx[i].kind == 'tell' then cnt = cnt + 1; t = s.fx[i] end end
    eq(cnt, 1); eq(t.tellKind, 'dA'); eq(t.uid, s.dealer.hand[2].uid); eq(t.slot, 'up')
    eq(s._distractorShown, true)
  end)

  -- ===================== shop / marks =====================
  check('shop: reroll doubles cost, deducts chips and keeps sold slots', function()
    local g = started('normal'); local s = g._g.state
    s.chips = 100000; g._g:openShop()
    local c0 = s.shop.rerollCost
    s.shop.shelves[1].sold = true
    g._g:reroll()
    eq(s.shop.rerollCost, c0 * 2); eq(s.chips, 100000 - c0)
    eq(s.shop.shelves[1].sold, true)
    g._g:reroll()
    eq(s.shop.rerollCost, c0 * 4); eq(s.chips, 100000 - c0 - c0 * 2)
  end)

  check('shop: buy_relic deducts chips and marks the shelf sold', function()
    local g = started('normal'); local s = g._g.state
    s.chips = 100000; g._g:openShop()
    local def
    for i = 1, #Relics.LIST do if not g._g:hasRelic(Relics.LIST[i].id) then def = Relics.LIST[i]; break end end
    truthy(def ~= nil)
    s.shop.shelves[1] = { kind = 'relic', def = def, id = def.id, name = def.name, price = 100, sold = false }
    local ok = g._g:buy_relic(1)
    eq(ok, true); eq(s.chips, 100000 - 100); eq(s.shop.shelves[1].sold, true)
    truthy(g._g:hasRelic(def.id))
  end)

  check('shop: forge consumes a special mark once for 10000', function()
    local g = started('normal'); local s = g._g.state
    s.chips = 20000
    s.shop = { shelves = {}, rerollCost = 200, forgeOffer = { { kind = 'mark', id = 'mark_vanish' } }, forgeUsed = false, forgeOpen = true, forgeSel = { kind = 'mark', id = 'mark_vanish' } }
    Marks.gainSpecial(s, 'mark_vanish')
    local ok = g._g:confirm_forge()
    eq(ok, true); eq(s.chips, 10000); eq(s.shop.forgeUsed, true)
    eq(s.specialMarks.held.forged, true)
    eq(g._g:confirm_forge(), false)
  end)

  check('marks: ink limit blocks the sixth mark and charges stage price', function()
    local g = started('normal'); local s = g._g.state
    s.chips = 100000; s.stage = 1; s.specialMarks = {}; s.flags.specialMarkUsedThisRound = false
    g._g:buildShoe()
    local pile = s.deck.drawPile
    for i = 1, 5 do eq(g._g:markCard(pile[i]), true) end
    eq(Marks.countInk(s), 5); eq(s.chips, 100000 - 5 * Marks.inkPrice(1, false))
    local ok, code = g._g:markCard(pile[6])
    eq(ok, false); eq(code, 'mark_limit')
  end)

  check('marks: placing a special mark consumes one use and sets the round latch', function()
    local g = started('normal'); local s = g._g.state
    s.specialMarks = {}; s.flags.specialMarkUsedThisRound = false
    g._g:buildShoe()
    Marks.gainSpecial(s, 'mark_bomb')
    local card = s.deck.drawPile[1]
    eq(g._g:markCard(card), true)
    truthy(card.marked ~= nil)
    truthy(not card.marked.ink)
    eq(Marks.specialUsesLeft(s), 2)
    eq(s.flags.specialMarkUsedThisRound, true)
  end)

  check('marks: ink thief halves the stage price', function()
    local g = started('normal'); local s = g._g.state
    s.chips = 100000; s.stage = 3; s.specialMarks = {}; s.flags.specialMarkUsedThisRound = false
    g._g:buildShoe()
    g._g:addRelic(Relics.byId('ink_thief'))
    eq(g._g:markCard(s.deck.drawPile[1]), true)
    eq(s.chips, 100000 - Marks.inkPrice(3, true))
  end)

  -- 标记 / 短牌靴 / 调酒 forcedStand 验收（tests/marks_acceptance.lua）
  local okAcc, acc = pcall(MarksAcc.run)
  if okAcc and type(acc) == 'table' then
    R.pass = R.pass + (acc.pass or 0)
    R.fail = R.fail + (acc.fail or 0)
    local errs = acc.errors or {}
    for i = 1, #errs do R.errors[#R.errors + 1] = errs[i] end
  else
    R.fail = R.fail + 1
    R.errors[#R.errors + 1] = 'marks_acceptance: ' .. tostring(acc)
  end

  -- 商店 / 经济 / 阶段边界验收（tests/shop_acceptance.lua）
  local okShop, shop = pcall(ShopAcc.run)
  if okShop and type(shop) == 'table' then
    R.pass = R.pass + (shop.pass or 0)
    R.fail = R.fail + (shop.fail or 0)
    local serrs = shop.errors or {}
    for i = 1, #serrs do R.errors[#R.errors + 1] = serrs[i] end
  else
    R.fail = R.fail + 1
    R.errors[#R.errors + 1] = 'shop_acceptance: ' .. tostring(shop)
  end

  -- 牌堆 UID 守恒验收（tests/conservation_acceptance.lua）
  local okCons, cons = pcall(ConsAcc.run)
  if okCons and type(cons) == 'table' then
    R.pass = R.pass + (cons.pass or 0)
    R.fail = R.fail + (cons.fail or 0)
    local cerrs = cons.errors or {}
    for i = 1, #cerrs do R.errors[#R.errors + 1] = cerrs[i] end
  else
    R.fail = R.fail + 1
    R.errors[#R.errors + 1] = 'conservation_acceptance: ' .. tostring(cons)
  end

  if opts.verbose or R.fail > 0 then
    for i = 1, #R.errors do print('  FAIL ' .. R.errors[i]) end
  end
  print(string.format('tests: PASS=%d FAIL=%d', R.pass, R.fail))
  return R
end

local modname = ...
if modname == nil then
  local rep = runner({})
  if rep.fail > 0 then error('tests failed: ' .. rep.fail) end
end
return runner
