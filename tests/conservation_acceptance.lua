-- tests/conservation_acceptance.lua : 牌堆 UID 守恒（多回合 / 换靴 / 卡包寄存 / 酒吧）
-- 契约：require('tests.conservation_acceptance') 返回 { run = function() -> report { pass, fail, errors } }
local Game = require('src.game')
local Relics = require('src.relics')
local Bar = require('src.bar_mode')
local BJ = require('src.blackjack')
local DT = require('src.deck_types')

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
  local s = seed or 123456789
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
local function started(mode, seed)
  local g = Game.new({ rng = mkRng(seed or 424242), filesystem = memfs() })
  assert(g:start(mode or 'normal', 20260101))
  g:flush()
  if g.state.state == 'relic_select' then assert(g:action('pick_relic', 1)); g:flush() end
  return g
end
local function hands(g)
  local st = g.state
  local out = {}
  local function push(side)
    if not side or not side.hand then return end
    for i = 1, #side.hand do out[#out + 1] = side.hand[i] end
  end
  push(st.player); push(st.dealer)
  return out
end
local function dealTo(gs, np, nd)
  for _ = 1, np do local c = gs:drawCard('player'); if c then gs:pushHand('player', c) end end
  for _ = 1, nd do local c = gs:drawCard('dealer'); if c then gs:pushHand('dealer', c) end end
end

local function build()
  R = { pass = 0, fail = 0, errors = {} }

  check('conservation: 多回合 beginBet 回收手牌、UID 守恒', function()
    local g = started('normal'); local gs = g._g; local st = g.state
    gs:buildShoe()
    for r = 1, 8 do
      gs:beginBet()
      dealTo(gs, 3, 2)
      local ext = hands(g)
      local m = st.deck:audit(ext)
      truthy(st.deck:auditOk(ext), 'mid r=' .. r .. ' total=' .. tostring(m.total))
      gs:beginBet()
      eq(#st.player.hand, 0, 'player hand cleared r=' .. r)
      eq(#st.dealer.hand, 0, 'dealer hand cleared r=' .. r)
      truthy(st.deck:auditOk(hands(g)), 'after beginBet r=' .. r)
    end
    eq(st.deck:audit(hands(g)).total, 52, 'all 52 uids still present')
  end)

  check('conservation: buildShoe 回收旧手牌且新牌堆不复用旧 UID', function()
    local g = started('normal'); local gs = g._g; local st = g.state
    gs:buildShoe()
    gs:beginBet()
    dealTo(gs, 3, 2)
    local oldDeck = st.deck
    local handCount = #st.player.hand + #st.dealer.hand
    eq(handCount, 5)
    local oldUid = {}
    for i = 1, #oldDeck.drawPile do oldUid[oldDeck.drawPile[i].uid] = true end
    st.stage = 2
    gs:buildShoe()
    eq(st.deck.initialTotal, 104, 'stage2 shoe size')
    eq(#st.player.hand, 0)
    eq(#st.dealer.hand, 0)
    truthy(#oldDeck.discardPile >= handCount, 'old hands went into old deck discard')
    truthy(st.deck:auditOk(hands(g)), 'new deck audit')
    for i = 1, #st.deck.drawPile do
      if oldUid[st.deck.drawPile[i].uid] then error('old uid leaked into new shoe: ' .. tostring(st.deck.drawPile[i].uid)) end
    end
  end)

  check('conservation: card_pack 寄存跨回合保留、换靴归还旧牌堆', function()
    local g = started('normal'); local gs = g._g; local st = g.state
    gs:buildShoe(); gs:beginBet()
    gs:addRelic(Relics.byId('card_pack'))
    dealTo(gs, 3, 0)
    local reserved = table.remove(st.player.hand, #st.player.hand)
    truthy(reserved ~= nil, 'reserved card taken')
    eq(#st.player.hand, 2)
    st.cardPack = reserved
    if st.player then st.player.cardPack = reserved end
    gs:beginBet()
    eq(st.cardPack, reserved, 'reserved survives beginBet')
    local ext = hands(g); ext[#ext + 1] = reserved
    truthy(st.deck:auditOk(ext), 'audit including reserved')
    local oldDeck = st.deck
    st.stage = 2
    gs:buildShoe()
    eq(st.cardPack, nil, 'reserved cleared on shoe change')
    local found = false
    for i = 1, #oldDeck.discardPile do if oldDeck.discardPile[i] == reserved then found = true end end
    truthy(found, 'reserved returned to old deck discard')
  end)

  check('conservation: 酒吧 barDeal 在 st.barDeck 上回收手牌', function()
    local g = started('bar'); local gs = g._g; local st = g.state
    truthy(st.barDeck ~= nil, 'barDeck exists')
    st.bar.round = 5
    for _ = 1, 3 do local c = st.barDeck:draw(); if c then st.player.hand[#st.player.hand + 1] = c end end
    truthy(st.barDeck:auditOk(hands(g)), 'bar mid')
    local before = #st.barDeck.discardPile
    st.state = 'player'
    gs:barDeal()
    eq(#st.player.hand, 2)
    eq(#st.dealer.hand, 2)
    truthy(#st.barDeck.discardPile >= before, 'bar hands recycled into barDeck discard')
    truthy(st.barDeck:auditOk(hands(g)), 'bar after deal')
  end)

  -- 千招 A / E 在发牌后新建/复制实体：必须登记为合成牌（is_synthetic + 清 _synthCounted），
  -- 否则 Deck.syntheticCreated 少算一张，审计 total = expected + 1。
  check('conservation: 千招 A 替换暗牌计入合成牌', function()
    local g = started('normal'); local gs = g._g; local st = g.state
    gs:buildShoe(); gs:beginBet()
    for _ = 1, 2 do gs:pushHand('player', gs:drawCard('player')) end
    for _ = 1, 2 do gs:pushHand('dealer', gs:drawCard('dealer')) end
    if BJ.isBlackjack(st.player.hand) then gs:pushHand('player', gs:drawCard('player')) end
    local old = st.dealer.hand[2]
    local up = st.deck:drawWhere(function(c) return BJ.cardValue(c) == 10 end)
    truthy(up, 'found a ten upcard')
    st.dealer.hand[2] = up
    st.deck:toDiscard(old)
    local before = st.deck.syntheticCreated
    gs:executeCheatDeal({ move = 'A' })
    eq(st.deck.syntheticCreated, before + 1, 'A replacement counted synthetic')
    truthy(st.deck.auditOk and st.deck:auditOk(hands(g)), 'A conservation audit')
  end)

  check('conservation: 千招 E 镜影复制计入合成牌（含源牌本身为合成牌）', function()
    local g = started('normal'); local gs = g._g; local st = g.state
    gs:buildShoe(); gs:beginBet()
    for _ = 1, 2 do gs:pushHand('player', gs:drawCard('player')) end
    for _ = 1, 2 do gs:pushHand('dealer', gs:drawCard('dealer')) end
    local before = st.deck.syntheticCreated
    gs:executeCheatDeal({ move = 'E' })
    eq(st.deck.syntheticCreated, before + 1, 'E mirror counted synthetic')
    truthy(st.deck:auditOk(hands(g)), 'E conservation audit')
    -- 源牌本身已是合成牌：clone 会带上 _synthCounted，必须清掉才会再计一次
    local synth = DT.mk({ rank = '9', suit = 'H', kind = 'basic', is_synthetic = true })
    st.deck:assignUid(synth)
    local oldFirst = st.player.hand[1]
    st.player.hand[1] = synth
    st.deck:toDiscard(oldFirst)
    local b2 = st.deck.syntheticCreated
    gs:executeCheatDeal({ move = 'E' })
    eq(st.deck.syntheticCreated, b2 + 1, 'mirror of synthetic source counted again')
    truthy(st.deck:auditOk(hands(g)), 'E2 conservation audit')
  end)

  return R
end

local modname = ...
if modname == nil then
  local rep = build()
  if rep.fail > 0 then
    for i = 1, #rep.errors do print('  FAIL ' .. rep.errors[i]) end
    error('conservation tests failed: ' .. rep.fail)
  end
  print(string.format('conservation: PASS=%d FAIL=%d', rep.pass, rep.fail))
end
return { run = build }
