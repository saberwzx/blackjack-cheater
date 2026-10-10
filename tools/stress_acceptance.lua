-- tools/stress_acceptance.lua
-- 确定性整局压力驱动（memory fs，无正式存档污染）。
--
-- 目标：用真实公开动作（Game:action / Game:start）把整局从开局驱动到合法终局，
-- 覆盖 normal / hard / bar 三种模式，并在每一步断言核心不变量。
--
-- 断言（每步）：
--   * deck:audit(双手外部牌) 的 UID 守恒（无重复 / 无缺 UID / 总数 == 初始 + 合成）
--   * 筹码有限（非 NaN / Inf）
--   * 玩家与庄家手牌 <= 12
--   * result.errors 为空（src/scoring.lua 用 pcall 吞掉 fx 错误，必须显式检查）
--   * 只读情报（audit / getView）不得消耗游戏 RNG
--   * 进度写只在合法事件发生；bar 模式 0 次 persist 写
--
-- 覆盖边界（诚实声明）：
--   * 策略只做「合法动作」随机游走：下注/要牌/停牌/加倍/投降/指认、商店购买/重掷、
--     选职业/碎片、酒吧喝 1 口 + 只用无需目标的自我技能（9 个 special）。
--   * 不覆盖：forge（需 10000 筹码）、需要目标的酒吧技能（换牌/换庄家牌/挑冠军牌）、
--     冠军编辑器/教程 UI（由 tools/meta_acceptance.lua 覆盖）。
--   * 本测试证明「这些路径在随机长局中不破坏不变量」，不是「139 个遗物效果全部正确」。
--
-- 运行：
--   python tools/run_lua.py tools/stress_acceptance.lua
--   可用环境变量缩短：STRESS_NORMAL=2 STRESS_HARD=2 STRESS_BAR=1 python tools/run_lua.py tools/stress_acceptance.lua

local Game = require('src.game')
local Persist = require('src.persist')

local pass, fails = 0, {}
local function check(name, fn)
  local ok, e = pcall(fn)
  if ok then
    pass = pass + 1
    print('PASS ' .. name)
  else
    fails[#fails + 1] = name .. ': ' .. tostring(e)
    print('FAIL ' .. fails[#fails])
  end
end
local function eq(a, b) assert(a == b, tostring(a) .. ' ~= ' .. tostring(b)) end

-- 可种子的可调用 RNG 表：rng() -> [0,1)，rng(a,b) -> [a,b] 整数；count 记录调用次数。
local function makeRng(seed)
  local s = math.floor(math.abs(seed or 1)) % 2147483646 + 1
  local t = { count = 0 }
  local function nxt()
    s = (s * 16807) % 2147483647
    return s
  end
  return setmetatable(t, {
    __call = function(self, a, b)
      self.count = self.count + 1
      local r = nxt() / 2147483647
      if a == nil then return r end
      return a + math.floor(r * (b - a + 1))
    end,
  })
end

local function envInt(name, default)
  local get = os and os.getenv
  if not get then return default end
  local v = tonumber(get(name))
  return v or default
end

local MAX_STEPS = 5000
local MOUTHS = 5
local SAFE_BAR_SPECIALS = {
  redraw_hand = true, peek_sink_pick = true, burn_half = true,
  duplicate_lowest = true, dealer_stop = true, discard_highest = true,
  discard_random = true, take_dealer_highest_sink = true, give_lowest_to_dealer = true,
}
local TERMINAL = { victory = true, forceExit = true, bar_ending = true }

-- 每 seed 独立环境：memory fs + 记录 persist 写的 spy persist + 独立游戏 RNG。
local function newEnv(seed)
  local files = {}
  local fs = {
    read = function(p) return files[p] end,
    write = function(p, v) files[p] = v; return true end,
    mkdir = function() return true end,
    getInfo = function(p) return files[p] and { type = 'file' } or nil end,
  }
  local real = Persist.new({ fs = fs })
  local spy = setmetatable({ progressWrites = 0, collectionWrites = 0, resetWrites = 0 }, { __index = real })
  function spy:writeProgress(p) self.progressWrites = self.progressWrites + 1; return real:writeProgress(p) end
  function spy:writeCollection(c) self.collectionWrites = self.collectionWrites + 1; return real:writeCollection(c) end
  function spy:resetProgress() self.resetWrites = self.resetWrites + 1; return real:resetProgress() end
  local rng = makeRng(seed)
  local g = Game.new({ filesystem = fs, persist = spy, rng = rng })
  return g, spy, files, rng
end

-- 规范化牌面（rank+suit），不含全局 uid：uid 会随合成牌与模块装载顺序漂移，
-- 因此回放记录 / 断言只依赖可复现的 cardface 与状态。
local function normFaces(h)
  if not h or #h == 0 then return '-' end
  local out = {}
  for i = 1, #h do
    local c = h[i]
    if c then out[#out + 1] = tostring(c.rank) .. tostring(c.suit) end
  end
  table.sort(out)
  return table.concat(out, ',')
end

local function traceTail(ctx, n)
  local t = ctx.trace
  if not t or #t == 0 then return '' end
  local from = #t - (n - 1); if from < 1 then from = 1 end
  local parts = { string.format('\n  replay: mode=%s seed=%s steps=%d (uid-free cardfaces)',
    tostring(ctx.mode), tostring(ctx.seed), #t) }
  for i = from, #t do parts[#parts + 1] = '  ' .. t[i] end
  return table.concat(parts, '\n')
end

local function ctxErr(ctx, msg)
  return string.format('[seed=%s mode=%s state=%s lastAction=%s] %s%s',
    tostring(ctx.seed), tostring(ctx.mode), tostring(ctx.state), tostring(ctx.lastAction), msg, traceTail(ctx, 12))
end

-- 动作失败不是「可回退」的情况：立刻带上下文报错，绝不无条件继续。
local function doAction(g, ctx, name, arg)
  ctx.lastAction = name .. (arg ~= nil and (':' .. tostring(arg)) or '')
  local ok, res
  if arg ~= nil then ok, res = g:action(name, arg) else ok, res = g:action(name) end
  g:flush()
  -- 规范化回放记录：只用 cardface / state / chips，不含全局 uid
  ctx.trace = ctx.trace or {}
  ctx.step = (ctx.step or 0) + 1
  local ss = g.state
  ctx.trace[#ctx.trace + 1] = string.format('step=%d state=%s action=%s chips=%s P=%s D=%s',
    ctx.step, tostring(ss.state), ctx.lastAction, tostring(ss.chips),
    normFaces(ss.player and ss.player.hand), normFaces(ss.dealer and ss.dealer.hand))
  if #ctx.trace > 400 then table.remove(ctx.trace, 1) end
  if ok == false then
    error(ctxErr(ctx, 'action_failed ' .. name .. ' err=' .. tostring(res) ..
      ' lastError=' .. tostring(g.state.lastError)))
  end
  return ok
end

local TRACE = os and os.getenv and os.getenv('STRESS_TRACE')
local PROBE = os and os.getenv and os.getenv('STRESS_PROBE')
if PROBE then
  local Deck = require('src.deck')
  local orig = Deck.toDiscard
  function Deck:toDiscard(card)
    if card then
      local gs = self._probeGs
      if gs then
        for _, who in ipairs({ 'player', 'dealer' }) do
          local h = gs.state[who] and gs.state[who].hand
          if h then for i = 1, #h do if h[i] == card then
            print('HAND->DISCARD uid=' .. tostring(card.uid) .. ' state=' .. tostring(gs.state.state))
            print(debug.traceback('', 2))
          end end end
        end
      end
    end
    return orig(self, card)
  end
end

-- STRESS_LEDGER: 追踪每张牌的 uid 首次归属牌堆、以及 syntheticCreated 计入哪一代牌堆，
-- 用于区分「账本未计 / 牌属于旧代牌堆」与「实际多造了一张牌」。只包装、不改计数。
local LEDGER = os and os.getenv and os.getenv('STRESS_LEDGER')
local _deckSeq = 0
if LEDGER then
  local Deck = require('src.deck')
  local origAdd = Deck.addCards
  function Deck:addCards(cards, label)
    local r = origAdd(self, cards, label)
    if cards then for i = 1, #cards do local c = cards[i]; if c and not c.is_synthetic then c._ledgerBase = true end end end
    return r
  end
  local origAssign = Deck.assignUid
  function Deck:assignUid(card)
    if not self._dbgId then _deckSeq = _deckSeq + 1; self._dbgId = _deckSeq end
    local sb = self.syntheticCreated
    local r = origAssign(self, card)
    if card then
      if not card._firstDeck then card._firstDeck = self end
      if self.syntheticCreated ~= sb then card._synthDeck = self end
    end
    return r
  end
end

local function ledgerDetail(s)
  if not LEDGER then return '' end
  local parts = {}
  local cur = (s.deck and s.deck._dbgId) or -1
  local function tag(c)
    local fd = (c._firstDeck and c._firstDeck._dbgId) or -1
    local sd = (c._synthDeck and c._synthDeck._dbgId) or -1
    return string.format('%s%s uid=%s synth=%s counted=%s firstD=%s synthD=%s',
      tostring(c.rank), tostring(c.suit), tostring(c.uid), tostring(c.is_synthetic),
      tostring(c._synthCounted), tostring(fd), tostring(sd))
  end
  local function scan(list, zone)
    if not list then return end
    for i = 1, #list do
      local c = list[i]
      if c and c._firstDeck and c._firstDeck._dbgId ~= cur then
        parts[#parts + 1] = string.format('foreign@%s[%d] %s', zone, i, tag(c))
      end
    end
  end
  scan(s.deck and s.deck.drawPile, 'draw')
  scan(s.deck and s.deck.discardPile, 'discard')
  scan(s.deck and s.deck.removed, 'removed')
  scan(s.player and s.player.hand, 'phand')
  scan(s.dealer and s.dealer.hand, 'dhand')
  -- 物理存在但既未通过 addCards 计入 initialTotal、也未计入 syntheticCreated 的牌 = 账本漏记/凭空多造。
  local function scanUncounted(list, zone)
    if not list then return end
    for i = 1, #list do
      local c = list[i]
      if c and not c._synthCounted and not c._ledgerBase then
        parts[#parts + 1] = string.format('UNCOUNTED@%s[%d] %s', zone, i, tag(c))
      end
    end
  end
  scanUncounted(s.deck and s.deck.drawPile, 'draw')
  scanUncounted(s.deck and s.deck.discardPile, 'discard')
  scanUncounted(s.deck and s.deck.removed, 'removed')
  scanUncounted(s.player and s.player.hand, 'phand')
  scanUncounted(s.dealer and s.dealer.hand, 'dhand')
  local synt = 0
  local function countSyn(list) if list then for i = 1, #list do if list[i] and list[i].is_synthetic then synt = synt + 1 end end end end
  countSyn(s.deck and s.deck.drawPile); countSyn(s.deck and s.deck.discardPile); countSyn(s.deck and s.deck.removed)
  countSyn(s.player and s.player.hand); countSyn(s.dealer and s.dealer.hand)
  parts[#parts + 1] = string.format('ledger: curDeck=%d initialTotal=%d syntheticCreated=%d syntheticRecycled=%d synthPhysical=%d',
    cur, s.deck.initialTotal, s.deck.syntheticCreated, s.deck.syntheticCount, synt)
  return '\n  ' .. table.concat(parts, '\n  ')
end

local function zoneSnap(s)
  local m = {}
  local function put(list, z)
    if not list then return end
    for i = 1, #list do local c = list[i]; if c and c.uid and not m[c.uid] then m[c.uid] = z end end
  end
  put(s.deck and s.deck.drawPile, 'draw')
  put(s.deck and s.deck.discardPile, 'discard')
  put(s.deck and s.deck.removed, 'removed')
  put(s.player and s.player.hand, 'phand')
  put(s.dealer and s.dealer.hand, 'dhand')
  -- 合法寄存区（跨小局持有）：真实牌，需标注；若仍留在牌堆区则以牌堆区为准
  if s.cardPack and s.cardPack.uid and not m[s.cardPack.uid] then m[s.cardPack.uid] = 'cardPack' end
  if s.salvageCard and s.salvageCard.uid and not m[s.salvageCard.uid] then m[s.salvageCard.uid] = 'salvageCard' end
  return m
end

-- 构造审计 external：手牌 + 合法寄存区（card_pack 的 st.cardPack、打捞的 st.salvageCard）。
-- 手牌直接计入（重复 uid 必须被 audit 报出）；寄存牌若仍在牌堆三区则跳过，
-- 避免与牌堆扫描重复计数（打捞目标 mark 时仍留在弃牌堆，命中才移出）。
-- 返回 ext, holdingStr, holding。
local function buildExternal(s)
  local inZone, ext, extSeen, holding = {}, {}, {}, {}
  local function markZone(list) if list then for i = 1, #list do local c = list[i]; if c and c.uid then inZone[c.uid] = true end end end end
  if s.deck then markZone(s.deck.drawPile); markZone(s.deck.discardPile); markZone(s.deck.removed) end
  local function addExt(c, zone)
    if not c then return end
    ext[#ext + 1] = c
    if c.uid then extSeen[c.uid] = true end
    holding[zone] = (holding[zone] or 0) + 1
  end
  local function addHand(list) if list then for i = 1, #list do addExt(list[i], 'hand') end end end
  addHand(s.player and s.player.hand)
  addHand(s.dealer and s.dealer.hand)
  local function addHeld(c, zone)
    if not c or not c.uid then return end
    if inZone[c.uid] or extSeen[c.uid] then return end
    addExt(c, zone)
  end
  addHeld(s.cardPack, 'cardPack')
  addHeld(s.player and s.player.cardPack, 'cardPack')
  addHeld(s.salvageCard, 'salvageCard')
  local hparts = {}
  for _, z in ipairs({ 'hand', 'cardPack', 'salvageCard' }) do
    if holding[z] then hparts[#hparts + 1] = z .. '=' .. holding[z] end
  end
  return ext, ((#hparts > 0) and table.concat(hparts, ',') or 'none'), holding
end

local function invariants(g, ctx, rng)
  local s = g.state
  local chips = s.chips
  assert(type(chips) == 'number' and chips == chips and chips ~= math.huge and chips ~= -math.huge,
    ctxErr(ctx, 'chips_not_finite=' .. tostring(chips)))
  if s.player and s.player.hand then
    assert(#s.player.hand <= 12, ctxErr(ctx, 'player_hand_overflow=' .. #s.player.hand))
  end
  if s.dealer and s.dealer.hand then
    assert(#s.dealer.hand <= 12, ctxErr(ctx, 'dealer_hand_overflow=' .. #s.dealer.hand))
  end
  if s.result and s.result.errors and #s.result.errors > 0 then
    local parts = {}
    for i = 1, #s.result.errors do parts[i] = tostring(s.result.errors[i]) end
    error(ctxErr(ctx, 'result_errors=' .. table.concat(parts, ' | ')))
  end
  -- 只读情报读取：不得消耗游戏 RNG
  local before = rng.count
  local view = g:getView()
  assert(view == s, ctxErr(ctx, 'getView_identity_mismatch'))
  -- 审计 external = 手牌 + 合法寄存区（见 buildExternal）。
  assert(s.deck, ctxErr(ctx, 'no_deck'))
  local ext, holdingStr = buildExternal(s)
  local a = s.deck:audit(ext)
  if rng.count ~= before then
    error(ctxErr(ctx, 'intel_read_consumed_game_rng delta=' .. tostring(rng.count - before)))
  end
  local snap = zoneSnap(s)
  if not a.ok then
    local vanish = {}
    if ctx.snap then
      for uid, z in pairs(ctx.snap) do if not snap[uid] then vanish[#vanish + 1] = tostring(uid) .. '@' .. z end end
    end
    error(ctxErr(ctx, string.format('deck_audit_failed total=%d expected=%d dup=%d missing=%d holding[%s] vanished[%s]',
      a.total, a.expected, #a.duplicates, #a.missingUid, holdingStr, table.concat(vanish, ','))) .. ledgerDetail(s))
  end
  ctx.snap = snap
end

local function drinkableCups(b)
  if not b or not b.cups then return nil end
  local out = {}
  for i = 1, #b.cups do
    if (b.cups[i].mouth or 0) < MOUTHS then out[#out + 1] = i end
  end
  if #out == 0 then return nil end
  return out
end

local function safeAbilities(b)
  if not b or b.usedAbilityThisRound then return nil end
  local out = {}
  for i = 1, #b.cups do
    local c = b.cups[i]
    if (c.buffLeft or 0) > 0 and c.ability and SAFE_BAR_SPECIALS[c.ability.special] then
      out[#out + 1] = c.drink
    end
  end
  if #out == 0 then return nil end
  return out
end

local function playPlayerTurn(g, ctx)
  local s = g.state
  local p = s.player
  if s.mode == 'bar' then
    if ctx.drng(1, 100) <= 35 then
      local cups = drinkableCups(s.bar)
      if cups then doAction(g, ctx, 'bar_drink', cups[ctx.drng(1, #cups)]) end
    end
    if g.state.state == 'player' then
      local ab = safeAbilities(g.state.bar)
      if ab and ctx.drng(1, 100) <= 45 then
        doAction(g, ctx, 'bar_ability', { id = ab[ctx.drng(1, #ab)] })
      end
    end
  end
  if g.state.state ~= 'player' then return end
  s = g.state
  p = s.player
  if p.busted or p.stood or p.surrendered or p.blackjack or p.cageBlocked then
    return doAction(g, ctx, 'stand')
  end
  if not s.flags.accusedThisRound and ctx.drng(1, 100) <= 12 then
    return doAction(g, ctx, 'accuse')
  end
  if #p.hand == 2 and not p.is67 and s.chips >= s.bet and ctx.drng(1, 100) <= 30 then
    return doAction(g, ctx, 'double')
  end
  if p.total < 18 and g._g:hasRelic('late_surrender') then
    local r = g._g:relicById('late_surrender')
    if r and r._active and ctx.drng(1, 100) <= 25 then
      return doAction(g, ctx, 'surrender')
    end
  end
  if p.total >= 17 or #p.hand >= 12 then return doAction(g, ctx, 'stand') end
  if ctx.drng(1, 100) <= 15 then return doAction(g, ctx, 'stand') end
  return doAction(g, ctx, 'hit')
end

local function shopOption(g, ctx)
  local s = g.state
  local shop = s.shop
  if not shop then return nil end
  local slots = {}
  for i = 1, #shop.shelves do
    local sh = shop.shelves[i]
    if sh and not sh.sold and s.chips >= sh.price then
      if sh.kind == 'relic' then
        if #g._g:activeRelics() < s.relicSlotMax then
          slots[#slots + 1] = { action = 'buy_relic', arg = i }
        end
      else
        slots[#slots + 1] = { action = 'buy_deck', arg = i }
      end
    end
  end
  if #slots == 0 then return nil end
  return slots[ctx.drng(1, #slots)]
end

local function playShop(g, ctx)
  local guard = 0
  while guard < 8 do
    guard = guard + 1
    local opt = shopOption(g, ctx)
    if not opt then break end
    doAction(g, ctx, opt.action, opt.arg)
    if g.state.state ~= 'shop' then return end
  end
  local shop = g.state.shop
  if shop and g.state.chips >= shop.rerollCost and ctx.drng(1, 100) <= 20 then
    doAction(g, ctx, 'reroll')
  end
  if g.state.state == 'shop' then doAction(g, ctx, 'leave_shop') end
end

local function dispatchState(g, ctx)
  local s = g.state
  local st = s.state
  if st == 'relic_select' then
    local cands = s.relicSelect and s.relicSelect.candidates or {}
    assert(#cands > 0, ctxErr(ctx, 'no_relic_candidates'))
    doAction(g, ctx, 'pick_relic', ctx.drng(1, #cands))
  elseif st == 'bet' then
    if ctx.drng(1, 10) == 1 then doAction(g, ctx, 'toggle_bust_bet') end
    local mn, mx = g._g:betLimits()
    if mx < mn then mx = mn end
    doAction(g, ctx, 'bet_set', mn + ctx.drng(0, mx - mn))
    doAction(g, ctx, 'bet_confirm')
  elseif st == 'player' then
    playPlayerTurn(g, ctx)
  elseif st == 'dealer' then
    g:update(0.5)
    g:flush()
  elseif st == 'result' or st == 'stageClear' then
    doAction(g, ctx, 'continue')
  elseif st == 'shop' then
    playShop(g, ctx)
  elseif st == 'classSelect' then
    local cands = s.classOffer and s.classOffer.candidates or {}
    assert(#cands > 0, ctxErr(ctx, 'no_class_candidates'))
    doAction(g, ctx, 'choose_class', cands[ctx.drng(1, #cands)].id)
  elseif st == 'classOffer' then
    local cands = s.classOffer and s.classOffer.candidates or {}
    if #cands > 0 and ctx.drng(1, 10) > 3 then
      doAction(g, ctx, 'take_class_offer', ctx.drng(1, #cands))
    else
      doAction(g, ctx, 'skip_class_offer')
    end
  elseif st == 'bar_brief' then
    doAction(g, ctx, 'bar_begin')
  elseif st == 'bar_gift' then
    local b = s.bar
    local n = (b and b.pendingGift and #b.pendingGift) or 0
    assert(n > 0, ctxErr(ctx, 'bar_gift_without_pending'))
    doAction(g, ctx, 'bar_gift_pick', ctx.drng(1, n))
  else
    error(ctxErr(ctx, 'unhandled_state=' .. tostring(st)))
  end
end

local function drive(g, ctx, spy, rng)
  local steps = 0
  while true do
    local s = g.state
    ctx.state = s.state
    if TERMINAL[s.state] or s.state == 'title' then return s.state end
    steps = steps + 1
    if steps > (ctx.maxSteps or MAX_STEPS) then
      error(ctxErr(ctx, 'step_cap round=' .. tostring(s.round)))
    end
    local preState = s.state
    local pw0, cw0 = spy.progressWrites, spy.collectionWrites
    dispatchState(g, ctx)
    local dpw = spy.progressWrites - pw0
    local dcw = spy.collectionWrites - cw0
    if dcw > 0 then error(ctxErr(ctx, 'collection_written')) end
    if dpw > 0 then
      local ns = g.state.state
      if ctx.mode == 'bar' then
        error(ctxErr(ctx, 'bar_wrote_progress'))
      elseif not ((preState == 'stageClear' or preState == 'result') and (ns == 'victory' or ns == 'forceExit')) then
        error(ctxErr(ctx, string.format('illegal_progress_write pre=%s post=%s', tostring(preState), tostring(ns))))
      end
    end
    invariants(g, ctx, rng)
    if TRACE then
      local ss = g.state
      print(string.format('TRACE %s st=%s round=%d hand=%d/%d draw=%d disc=%d rem=%d inzone=%d exp=%d',
        ctx.mode, tostring(ss.state), ss.round or -1, #ss.player.hand, #ss.dealer.hand,
        #ss.deck.drawPile, #ss.deck.discardPile, #ss.deck.removed, ss.deck:audit({}).total, ss.deck:audit({}).expected))
    end
  end
end

local function runSeed(mode, seed)
  local g, spy, files, rng = newEnv(seed)
  local ctx = { seed = seed, mode = mode, state = '', lastAction = '-', drng = makeRng(seed * 7919 + 13) }
  local ok, err = pcall(function()
    assert(g:start(mode, seed) ~= false, ctxErr(ctx, 'start_failed'))
    if PROBE then g.state.deck._probeGs = g end
    ctx.state = g.state.state
    local terminal = drive(g, ctx, spy, rng)
    assert(TERMINAL[terminal], ctxErr(ctx, 'non_terminal_exit=' .. tostring(terminal)))
    if mode == 'bar' then
      assert(spy.progressWrites == 0, ctxErr(ctx, 'bar_persist_writes=' .. spy.progressWrites))
      assert(spy.collectionWrites == 0, ctxErr(ctx, 'bar_collection_writes=' .. spy.collectionWrites))
    else
      assert(spy.progressWrites == 1, ctxErr(ctx, 'progress_writes=' .. spy.progressWrites))
      assert(spy.collectionWrites == 0, ctxErr(ctx, 'collection_writes=' .. spy.collectionWrites))
    end
    if g.state.state ~= 'title' then doAction(g, ctx, 'continue') end
    assert(g.state.state == 'title', ctxErr(ctx, 'not_title_after_continue=' .. tostring(g.state.state)))
    assert(g:start(mode, seed + 7777) ~= false, ctxErr(ctx, 'isolation_start_failed'))
    local s2 = g.state.state
    if mode == 'bar' then
      assert(s2 == 'bar_brief', ctxErr(ctx, 'isolation_bar_state=' .. tostring(s2)))
    else
      assert(s2 == 'relic_select', ctxErr(ctx, 'isolation_state=' .. tostring(s2)))
    end
  end)
  if not ok then error(err, 0) end
  return true
end

-- ---------------------------------------------------------------------------
-- 种子回放：规范化 cardfaces / 状态，不含全局 uid（uid 随合成牌与装载顺序漂移）
-- ---------------------------------------------------------------------------
local function runReplay(mode, seed, cap)
  local g, spy, files, rng = newEnv(seed)
  local ctx = { seed = seed, mode = mode, state = '', lastAction = '-', step = 0,
    drng = makeRng(seed * 7919 + 13), trace = {}, maxSteps = cap }
  local ok, err = pcall(function()
    assert(g:start(mode, seed) ~= false, ctxErr(ctx, 'start_failed'))
    ctx.state = g.state.state
    drive(g, ctx, spy, rng)
  end)
  return ctx.trace, ok, err
end

local REPLAY_SEED = os and os.getenv and tonumber(os.getenv('STRESS_REPLAY'))
if REPLAY_SEED then
  local mode = (os.getenv('STRESS_REPLAY_MODE') or 'normal')
  local cap = tonumber(os.getenv('STRESS_REPLAY_STEPS') or '') or 400
  local trace, ok, err = runReplay(mode, REPLAY_SEED, cap)
  print(string.format('REPLAY %s seed=%d ok=%s steps=%d (normalized cardfaces, uid-free)',
    mode, REPLAY_SEED, tostring(ok), #trace))
  for i = 1, #trace do print('  ' .. trace[i]) end
  if not ok then print('  ERROR: ' .. tostring(err)) end
  if os.exit then os.exit(0) end
end

-- 调试 / 回放用法：
--   STRESS_REPLAY=1037 STRESS_REPLAY_MODE=normal STRESS_REPLAY_STEPS=120 python tools/run_lua.py tools/stress_acceptance.lua
--
-- ---------------------------------------------------------------------------
-- 基础自检：证明检查本身有牙齿（不是空跑）
-- ---------------------------------------------------------------------------
check('sanity: deck audit detects an injected duplicate UID', function()
  local g = newEnv(7)
  local s = g.state
  local card = { rank = 'A', suit = 'S', kind = 'basic', is_basic = true }
  s.deck:assignUid(card)
  s.deck.drawPile[#s.deck.drawPile + 1] = card
  local a = s.deck:audit({ card })
  assert(not a.ok, 'audit should fail on duplicate')
  assert(#a.duplicates > 0, 'expected duplicate report')
end)

check('sanity: decision RNG is independent from game RNG', function()
  local g, spy, files, rng = newEnv(42)
  local before = rng.count
  local d = makeRng(999)
  for i = 1, 100 do d(1, 10) end
  local floating = d()
  eq(rng.count, before)
  assert(type(floating) == 'number' and floating >= 0 and floating < 1, 'float out of range')
end)

check('sanity: seeded runs reproduce the identical opening deal', function()
  local function opening()
    local g = newEnv(12345)
    g:start('normal', 12345)
    local s = g.state
    assert(#s.relicSelect.candidates >= 1, 'need at least one relic candidate')
    g:action('pick_relic', 1); g:flush()
    g:action('bet_set', 100); g:action('bet_confirm'); g:flush()
    local out = {}
    for i = 1, #s.player.hand do out[#out + 1] = s.player.hand[i].rank .. s.player.hand[i].suit end
    for i = 1, #s.dealer.hand do out[#out + 1] = s.dealer.hand[i].rank .. s.dealer.hand[i].suit end
    return table.concat(out, ',')
  end
  eq(opening(), opening())
end)

check('sanity: seed replay is deterministic and uid-free', function()
  local t1, ok1 = runReplay('normal', 1037, 60)
  local t2, ok2 = runReplay('normal', 1037, 60)
  eq(ok1, ok2)
  eq(#t1, #t2)
  assert(#t1 >= 4, 'replay trace too short: ' .. #t1)
  for i = 1, #t1 do
    eq(t1[i], t2[i])
    assert(not t1[i]:find('uid='), 'replay record must not contain raw uid')
  end
end)

check('sanity: holding zones (cardPack/salvageCard) count as audit external', function()
  local function C(r, u) return { rank = r, suit = u, kind = 'basic', is_basic = true } end
  local g = newEnv(11)
  local s = g.state
  s.deck:addCards({ C('A', 'S'), C('K', 'H'), C('Q', 'D'), C('J', 'C') }, 'sanity')
  -- cardPack：牌已移出牌堆 -> 必须计入 external，审计仍 ok，且标注 holding
  local card = table.remove(s.deck.drawPile, 1)
  s.cardPack = card
  local ext, holdingStr, holding = buildExternal(s)
  local a = s.deck:audit(ext)
  assert(a.ok, 'cardPack external should keep audit ok: total=' .. a.total .. ' expected=' .. a.expected .. ' holding=' .. holdingStr)
  assert(holding.cardPack == 1 and not holding.hand, 'cardPack holding should be annotated: ' .. holdingStr)
  -- salvageCard：目标 mark 时仍留在弃牌堆 -> 不得重复计入 external
  local g2 = newEnv(12)
  local s2 = g2.state
  s2.deck:addCards({ C('A', 'S'), C('K', 'H'), C('Q', 'D'), C('J', 'C') }, 'sanity')
  local salv = table.remove(s2.deck.drawPile, 1)
  table.insert(s2.deck.discardPile, salv)
  s2.salvageCard = salv
  local ext2, holdingStr2, holding2 = buildExternal(s2)
  assert(holding2.salvageCard == nil, 'salvageCard still in discard must not double-count: ' .. holdingStr2)
  local a2 = s2.deck:audit(ext2)
  assert(a2.ok, 'salvage-in-discard audit should stay ok: total=' .. a2.total .. ' expected=' .. a2.expected)
end)

-- ---------------------------------------------------------------------------
-- 整局压力：normal / hard 各 20 seeds，bar 5 seeds
-- ---------------------------------------------------------------------------
local COUNTS = {
  normal = envInt('STRESS_NORMAL', 20),
  hard = envInt('STRESS_HARD', 20),
  bar = envInt('STRESS_BAR', 5),
}
local BASE = { normal = 1000, hard = 2000, bar = 3000 }
for _, mode in ipairs({ 'normal', 'hard', 'bar' }) do
  for i = 1, COUNTS[mode] do
    local seed = BASE[mode] + i * 37
    check(string.format('%s seed %d full run', mode, seed), function()
      runSeed(mode, seed)
    end)
  end
end

print(string.format('Stress acceptance: PASS=%d FAIL=%d', pass, #fails))
if #fails > 0 then error(table.concat(fails, '\n')) end
