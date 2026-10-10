-- src/game_state.lua 对局状态机（核心）：下注、发牌、行动、出千、结算、商店、标记、职阶、酒吧、教程
-- 与 main.lua / ui 无关；只暴露给 src/game.lua。
local U = require('src.util')
local R = require('src.rng')
local BJ = require('src.blackjack')
local Deck = require('src.deck')
local DT = require('src.deck_types')
local Relics = require('src.relics')
local Classes = require('src.classes')
local Marks = require('src.marks')
local Scoring = require('src.scoring')
local SI = require('src.shoe_info')
local Persist = require('src.persist')
local Champion = require('src.champion')
local Tutorial = require('src.tutorial')
local Cocktails = require('src.cocktails')
local Bar = require('src.bar_mode')
local EM = require('src.event_manager')

local GS = {}
GS.__index = GS

GS.STAGES = {
  { name = '新手赌场', rounds = 15, target = 2000,    decks = 1, ai = 1, cheat = 0.00, distract = 0.00, markPrice = 50 },
  { name = '老练赌场', rounds = 15, target = 20000,   decks = 2, ai = 2, cheat = 0.20, distract = 0.15, markPrice = 200 },
  { name = '黑暗赌场', rounds = 30, target = 2000000, decks = 3, ai = 3, cheat = 0.45, distract = 0.25, markPrice = 1000 },
}
GS.HAND_MAX = 12
GS.SHOP_EVERY = 5
GS.REROLL_BASE = 200
GS.FORGE_PRICE = 10000
GS.CHEAT_WEIGHTS = { { value = 'A', weight = 28 }, { value = 'B', weight = 28 }, { value = 'C', weight = 22 }, { value = 'D', weight = 11 }, { value = 'E', weight = 11 } }
GS.RARITY_WEIGHTS = { { value = 'common', weight = 45 }, { value = 'uncommon', weight = 30 }, { value = 'rare', weight = 18 }, { value = 'legendary', weight = 7 } }
GS.START_RELIC_WEIGHTS = { { value = 'common', weight = 40 }, { value = 'uncommon', weight = 35 }, { value = 'rare', weight = 18 }, { value = 'legendary', weight = 5 } }
GS.BET_PRESETS = { 50, 100, 200, 500, 1000 }

-- ===================== 构造 / 重置 =====================

function GS.new(opts)
  opts = opts or {}
  local self = setmetatable({}, GS)
  self.opts = opts
  self.rng = R.wrap(opts.rng)
  self.persist = opts.persist or Persist.new({ fs = opts.filesystem, dir = opts.saveDir })
  self.progress = opts.progress or self.persist:readProgress()
  self.settings = self.progress.settings or { volume = 0.6, resolution = '1280x720', fullscreen = false, autoEndOnBroke = true }
  self.fx = {}
  self.log = {}
  self.queue = {}
  self.lastError = nil
  self.seed = nil
  self.em = EM.new()
  self.specials = {}
  self.scoreHandlers = {}
  self:registerSpecials()
  self.state = {}
  self:resetState()
  return self
end

local function newPlayer()
  return {
    hand = {}, total = 0, rawTotal = 0, busted = false, stood = false,
    blackjack = false, is67 = false, isRps = false, surrendered = false,
    doubled = false, cageBlocked = false, peekIndex = nil, cardPack = nil,
  }
end

local function newDealer()
  return {
    hand = {}, total = 0, rawTotal = 0, busted = false, holeRevealed = false,
    difficulty = 1, standOn = 17, is67 = false, isRps = false,
  }
end

function GS:resetState()
  self.fx = {}
  self.log = {}
  self.queue = {}
  local meta = self.progress and self.progress.meta or {}
  self.state = {
    state = 'title', prevState = nil, mode = 'normal', seed = self.seed,
    stage = 1, stageName = GS.STAGES[1].name, stageTarget = GS.STAGES[1].target,
    stageRounds = GS.STAGES[1].rounds, roundsInStage = 0, round = 0,
    chips = 2500, bet = 0,
    bustBet = { on = false, amount = 0, odds = nil, hit = false, locked = false },
    player = newPlayer(), dealer = newDealer(),
    deck = Deck.new({ rng = self.rng }),
    relics = {}, relicSlotMax = 5,
    specialMarks = { held = nil },
    playerClass = nil, class = nil, dealerClass = nil,
    shop = nil, relicSelect = nil, classOffer = nil, forge = nil,
    message = '', messageTone = 'info', result = nil,
    shoe = { order = {}, composition = {}, nextBustOdds = nil, dealerBustOdds = nil, discard = {}, revealSlots = {}, coverageGap = '', offset = 0 },
    streak = 0, fx = self.fx, log = self.log,
    progress = {
      hardCleared = meta.hardCleared or false, hardClearCount = meta.hardClearCount or 0,
      maxStage = meta.maxStage or 1, maxChips = meta.maxChips or 2500,
      totalRuns = meta.totalRuns or 0, bestRoundsBasic = meta.bestRoundsBasic or 0,
      bestRoundsHard = meta.bestRoundsHard or 0,
    },
    settings = self.settings,
    tutorial = nil, bar = nil,
    flags = { specialMarkUsedThisRound = false, cheatUsedThisRound = false, accusedThisRound = false, firstHitUsed = false, autoStandNext = false },
    roundsSinceShop = 0, deckItems = {}, removedDeckIds = {},
    championCards = {}, revealSlots = {}, peekDepth = 0,
    rift = nil, lastError = nil, turn = 0, stat = {},
  }
  return self.state
end

function GS:setState(name)
  local st = self.state
  if name == 'result' or name == 'shop' or name == 'stageClear' or name == 'victory' or name == 'forceExit' then
    st.prevState = st.state
  end
  st.state = name
end

function GS:emit(t) t = t or {}; self.fx[#self.fx + 1] = t; return t end
function GS:msg(text, tone) local st = self.state; st.message = text or ''; st.messageTone = tone or 'info'; self.fx[#self.fx + 1] = { kind = 'message', text = st.message, tone = st.messageTone } end
function GS:logline(s) self.log[#self.log + 1] = s end
function GS:fail(code)
  self.lastError = code
  local st = self.state
  if st then st.lastError = code end
  return false, code
end

-- 真痕迹/干扰项：统一发 kind='tell' 事件；UI 依赖 tellKind + uid + 槽位。
-- 真招只在真正改动手牌/牌堆后调用；干扰项走 emitDistractor（置 _distractorShown 闩）。
function GS:emitTell(kind, card, slot, extra)
  if not kind or not card or not card.uid then return nil end
  local t = { kind = 'tell', tellKind = kind, uid = card.uid, card = card, slot = slot or 'dealer' }
  if extra then for k, v in pairs(extra) do t[k] = v end end
  return self:emit(t)
end

-- 干扰项：每小局最多物化一次，绑定一张已公开的明牌（庄家明牌优先，否则玩家首张）。
-- 只有干扰项路径置 _distractorShown；真痕迹不碰这个闩。
function GS:emitDistractor(card, slot)
  local st = self.state
  local intent = st.cheatIntent
  if not intent or not intent.distractor or st._distractorShown then return false end
  local target = card or (st.dealer.hand and st.dealer.hand[2]) or (st.player.hand and st.player.hand[1])
  if not target or not target.uid then return false end
  local where = slot
  if not where then
    if st.dealer.hand and st.dealer.hand[2] == target then where = 'up' else where = 'player' end
  end
  st._distractorShown = true
  self:emitTell(intent.distractor, target, where)
  return true
end

function GS:after(delay, fn, tag)
  self.queue[#self.queue + 1] = { t = delay or 0, elapsed = 0, fn = fn, tag = tag }
  return true
end

function GS:update(dt)
  dt = dt or 0
  local i = 1
  local guard = 0
  while i <= #self.queue do
    local item = self.queue[i]
    item.elapsed = item.elapsed + dt
    if item.elapsed >= item.t then
      table.remove(self.queue, i)
      guard = guard + 1
      item.fn()
      if guard > 5000 then break end
    else
      i = i + 1
    end
  end
  return true
end

function GS:flush()
  local n = 0
  while #self.queue > 0 do
    local item = table.remove(self.queue, 1)
    n = n + 1
    item.fn()
    if n > 20000 then break end
  end
  return n
end

-- ===================== 通用小工具 =====================

function GS:rfloat() return R.float(self.rng) end
function GS:rint(a, b) return R.int(self.rng, a, b) end
function GS:rchance(p) return R.chance(self.rng, p) end
function GS:rpick(list) return R.pick(self.rng, list) end
function GS:rweighted(entries) return R.weighted(self.rng, entries) end

function GS:hasRelic(id)
  for i = 1, #self.state.relics do
    local r = self.state.relics[i]
    if r.id == id and not r._expired then return true end
  end
  return false
end

function GS:relicById(id)
  for i = 1, #self.state.relics do
    if self.state.relics[i].id == id then return self.state.relics[i] end
  end
  return nil
end

function GS:activeRelics()
  local out = {}
  for i = 1, #self.state.relics do
    local r = self.state.relics[i]
    if not r._expired then out[#out + 1] = r end
  end
  return out
end

function GS:makeRelicInstance(d)
  return {
    id = d.id, name = d.name, desc = d.desc, spec = d.spec, rarity = d.rarity,
    price = d.price, def = d, group = d.group, kind = d.kind, trigger = d.trigger,
    special = d.special, pre = d.pre, markDot = d.markDot,
    _active = false, _auto = (d.trigger ~= 'active'), _preGame = d.pre == true,
    _consumable = d.consumes == true, _usesLeft = d.uses or (d.consumes and 1 or nil),
    _forged = false, _roundActive = false, _sold = false, _expired = false,
    active = false, consumable = d.consumes == true, usesLeft = d.uses or (d.consumes and 1 or nil), forged = false,
  }
end

function GS:syncRelicAliases()
  for i = 1, #self.state.relics do
    local r = self.state.relics[i]
    r.active = r._active
    r.consumable = r._consumable and not r._forged
    r.usesLeft = r._forged and nil or r._usesLeft
    r.forged = r._forged
    if r._consumable and not r._forged and (r._usesLeft or 0) <= 0 then r._expired = true end
  end
end

-- ===================== 阶段 / 开局 =====================

function GS:stageCfg(stage)
  return GS.STAGES[stage] or GS.STAGES[#GS.STAGES]
end

function GS:applyStage(stage)
  local st = self.state
  st.stage = stage
  local cfg = self:stageCfg(stage)
  st.stageName = cfg.name
  st.stageTarget = cfg.target
  st.stageRounds = cfg.rounds
  st.roundsInStage = 0
  st.dealer.difficulty = cfg.ai
  st.shoeDecks = cfg.decks
end

function GS:start(mode, seed)
  mode = mode or 'normal'
  if mode ~= 'normal' and mode ~= 'hard' and mode ~= 'bar' then return self:fail('invalid_arg') end
  self.seed = seed
  if seed and love and love.math and love.math.setRandomSeed then pcall(love.math.setRandomSeed, seed) end
  self:resetState()
  local st = self.state
  st.mode = mode
  st.seed = seed
  st.round = 0
  st.chips = 2500
  if mode == 'bar' then
    self:barStart()
    return true
  end
  self:applyStage(1)
  if mode == 'hard' then
    st.playerClass = Classes.getRuntime(self:rpick(Classes.ORDER))
    st.class = st.playerClass
  end
  -- 开局三选一（只出消耗品）
  st.relicSelect = { candidates = self:rollRelicChoices(3, true), picked = nil }
  self:setState('relic_select')
  self:logline('开局：' .. tostring(st.stageName))
  return true
end

function GS:rollRelicChoices(n, consumablesOnly, rarityWeights)
  local out = {}
  local seen = {}
  local guard = 0
  while #out < n and guard < 400 do
    guard = guard + 1
    local rarity = self:rweighted(rarityWeights or GS.RARITY_WEIGHTS)
    local pool = {}
    for i = 1, #Relics.LIST do
      local d = Relics.LIST[i]
      if d.rarity == rarity and not Relics.isPoolExcluded(d) then
        if not consumablesOnly or (d.consumes == true and not self:isShopOnlyRelic(d)) then
          if not seen[d.id] and not self:hasRelic(d.id) then pool[#pool + 1] = d end
        end
      end
    end
    if #pool > 0 then
      local d = pool[self:rint(1, #pool)]
      seen[d.id] = true
      out[#out + 1] = { id = d.id, name = d.name, desc = d.desc, rarity = d.rarity, price = d.price, def = d, consumable = d.consumes == true }
    end
  end
  return out
end


function GS:pick_relic(index)
  local st = self.state
  if st.state ~= 'relic_select' or not st.relicSelect then return self:fail('action_unavailable') end
  local c = st.relicSelect.candidates[index or 0]
  if not c then return self:fail('invalid_arg') end
  st.relicSelect.picked = c.id
  -- 防御：特种标记即使意外进入候选也要进专属库存（正常已被开局池排除）。
  if c.def and (c.def.markDot == true or c.def.group == 'mark') then
    Marks.gainSpecial(st, c.def.id)
  else
    self:addRelic(c.def)
  end
  st.state = 'bet'
  self:beginBet()
  return true
end

function GS:addRelic(d)
  local st = self.state
  if #self:activeRelics() >= st.relicSlotMax then return false, 'relic_slots_full' end
  local inst = self:makeRelicInstance(d)
  st.relics[#st.relics + 1] = inst
  self:hookRelicGained(inst)
  self:syncRelicAliases()
  return true, inst
end

-- ===================== 下注 =====================

function GS:betLimits()
  local st = self.state
  local credit = 0
  for i = 1, #st.relics do
    local d = st.relics[i].def
    if d and d.special == 'credit' then
      local p1 = d.param1 or 0
      local p2 = d.param2 or 0
      local v = p1 * st.chips + p2
      if v > credit then credit = v end
    end
  end
  local max = st.chips + credit
  if max < 1 then max = 1 end
  local min = 1
  if st.stage == 3 then min = math.max(1, math.floor(st.chips / 2)) end
  return min, max, credit
end

-- 新回合/换靴前把双方手牌回收到当前牌堆弃牌堆，保证 UID 守恒。
-- card_pack 的寄存牌不在手牌里（跨小局保留），因此天然不动。
function GS:recycleHands(targetDeck)
  local st = self.state
  local deck = targetDeck or st.deck
  local reserved = st.cardPack
  local function flush(side)
    if not side or not side.hand then return end
    local keep = {}
    for i = 1, #side.hand do
      local c = side.hand[i]
      if c and c ~= reserved and deck then
        deck:toDiscard(c)
      elseif c then
        keep[#keep + 1] = c
      end
    end
    side.hand = keep
  end
  flush(st.player)
  flush(st.dealer)
  return true
end

function GS:beginBet()
  local st = self.state
  self:recycleHands()
  st.bet = 0
  st.bustBet.on = st.bustBet.on or false
  st.bustBet.locked = false
  st.bustBet.hit = false
  st.bustBet.amount = 0
  st.player = newPlayer()
  st.dealer = newDealer()
  st.dealer.difficulty = self:stageCfg(st.stage).ai
  st.flags.accusedThisRound = false
  st.supremeClear = false
  st.flags.cheatUsedThisRound = false
  st.flags.specialMarkUsedThisRound = false
  st.flags.firstHitUsed = false
  st.cheatIntent = nil
  st.result = nil
  st.deck.discardPile = st.deck.discardPile or {}
  self:setState('bet')
  -- 回合开始：抽牌堆 <16 且有弃牌 -> 提前洗回
  if #st.deck.drawPile < 16 and #st.deck.discardPile > 0 then
    st.deck:shuffleDiscardIn()
    self:hookShoeRebuilt()
  end
  self:hookBetPre()
  self:refreshShoe()
  return true
end

function GS:bet_set(amount)
  local st = self.state
  if st.state ~= 'bet' then return self:fail('action_unavailable') end
  amount = math.floor(tonumber(amount) or 0)
  local min, max = self:betLimits()
  if amount < 0 then amount = 0 end
  if amount < min then amount = min end
  if amount > max then amount = max end
  st.bet = amount
  return true
end

function GS:bet_adjust(delta)
  return self:bet_set((self.state.bet or 0) + (tonumber(delta) or 0))
end

function GS:bet_preset(i)
  local v = GS.BET_PRESETS[i or 0]
  if not v then return self:fail('invalid_arg') end
  return self:bet_set(v)
end

function GS:toggle_bust_bet()
  local st = self.state
  if st.state ~= 'bet' and st.state ~= 'player' then return self:fail('action_unavailable') end
  if st.bustBet.locked then return self:fail('action_unavailable') end
  st.bustBet.on = not st.bustBet.on
  return true
end

function GS:bet_confirm()
  local st = self.state
  if st.state ~= 'bet' then return self:fail('action_unavailable') end
  local min, max = self:betLimits()
  if st.bet < min then return self:fail('invalid_arg') end
  st.creditUsed = (st.bet > st.chips)
  st.chips = st.chips - st.bet
  -- 爆注
  if st.bustBet.on then
    st.bustBet.amount = math.floor(st.bet * 0.5)
    st.chips = st.chips - st.bustBet.amount
    st.bustBet.locked = true
    st.bustBet.odds = nil
  end
  st.round = st.round + 1
  st.roundsInStage = st.roundsInStage + 1
  st.roundsSinceShop = st.roundsSinceShop + 1
  if not st.deck or #st.deck.drawPile == 0 then self:buildShoe() end
  self:dealInitial()
  self:setState('player')
  return true
end

function GS:skip_round()
  local st = self.state
  if st.state ~= 'bet' and st.state ~= 'player' then return self:fail('action_unavailable') end
  local cans = false
  if st.playerClass and st.playerClass.id == 'rider' and (st.playerClass.usesLeft or 0) > 0 then cans = true end
  if self:hasRelic('class_rider_shard') and not st.flags.riderUsedThisRound then cans = true end
  if self:hasRelic('rod_lost') then cans = true end
  if not cans and not self:hasRelic('class_rider_shard') then return self:fail('action_unavailable') end
  -- 下注全额归还
  if st.bet > 0 and st.state == 'bet' then st.chips = st.chips + st.bet end
  if st.bustBet.on and st.bustBet.amount > 0 then st.chips = st.chips + st.bustBet.amount end
  if st.playerClass and st.playerClass.id == 'rider' and st.state == 'player' then
    st.playerClass.usesLeft = (st.playerClass.usesLeft or 0) - 1
  end
  st.flags.riderUsedThisRound = true
  st.result = { outcome = 'push', bet = st.bet, netChange = 0, skipped = true }
  self:setState('result')
  self:scheduleAfterRound()
  self:msg('跳过本小局，下注已归还。', 'info')
  return true
end

-- ===================== 发牌 =====================

function GS:buildShoe()
  local st = self.state
  -- 换靴：先把旧手牌回收进旧牌堆（不能把旧 UID 塞进新牌堆），并归还卡包寄存牌。
  if st.deck then
    self:recycleHands(st.deck)
    if st.cardPack then
      st.deck:toDiscard(st.cardPack)
      st.cardPack = nil
      if st.player then st.player.cardPack = nil end
    end
  end
  local deck = Deck.new({ rng = self.rng })
  local cfg = self:stageCfg(st.stage)
  for i = 1, cfg.decks do deck:addCards(DT.standard52(), 'basic') end
  for i = 1, #st.deckItems do
    local item = st.deckItems[i]
    if item.key == 'champion' then
      deck:addCards(DT.generate('champion', item.size or 'small', { championCards = st.championCards }), 'champion')
    else
      deck:addCards(DT.generate(item.key, item.size or 'small'), item.key)
    end
  end
  local removeCount = 0
  for i = 1, #st.removedDeckIds do
    local it = st.removedDeckIds[i]
    removeCount = removeCount + DT.removedDecks(it.key, it.size)
  end
  for i = 1, removeCount do
    local c = deck:drawWhere(function(card) return card.is_basic end)
    if c then deck:toRemoved(c) end
  end
  deck:shuffle()
  st.deck = deck
  self:refreshShoe()
  return deck
end

-- 抽一张给 who（'player'|'dealer'）；处理标记效果与特殊牌
function GS:drawCard(who)
  local st = self.state
  local deck = st.deck
  local chain = 0
  while true do
    if #deck.drawPile == 0 and #deck.discardPile == 0 then return nil end
    local c = deck:draw()
    if not c then return nil end
    -- 标记：消失（仅玩家触发；最多连锁跳过 3 张，第 4 张返回真实牌）
    if who == 'player' and Marks.isMarked(c) and c.marked.markId == 'mark_vanish' then
      if chain < 3 then
        deck:toDiscard(c)
        chain = chain + 1
        self:emit({ kind = 'mark_fx', markId = 'mark_vanish', anchor = who, card = c })
        -- 继续摸下一张
      else
        return c
      end
    else
      -- 标记：爆炸（任何人摸到即炸毁其后 2 张，移入弃牌堆，守恒）
      if Marks.isMarked(c) and c.marked.markId == 'mark_bomb' then
        self:emit({ kind = 'mark_fx', markId = 'mark_bomb', anchor = who, card = c })
        for k = 1, 2 do
          local nx = deck:draw()
          if nx then deck:toDiscard(nx) end
        end
      end
      -- 标记：赏金（庄家要这张牌时立刻 +$500）
      if who == 'dealer' and Marks.isMarked(c) and c.marked.markId == 'mark_bounty' then
        st.chips = st.chips + 500
        self:emit({ kind = 'mark_fx', markId = 'mark_bounty', anchor = who, card = c })
        self:msg('赏金标记：+$500', 'success')
      end
      -- 标记：火焰（庄家无法要这张牌；放回牌靴顶，庄家转为停牌）
      if who == 'dealer' and st.state == 'dealer'
         and Marks.isMarked(c) and c.marked.markId == 'mark_flame' then
        self:emit({ kind = 'mark_fx', markId = 'mark_flame', anchor = who, card = c })
        deck:addToDraw(c, 1)
        return nil
      end
      return c
    end
  end
end

function GS:handOf(who)
  if who == 'player' then return self.state.player.hand end
  return self.state.dealer.hand
end

function GS:pushHand(who, card)
  local st = self.state
  if not card then return false end
  local hand = self:handOf(who)
  if #hand >= GS.HAND_MAX then
    st.deck:toDiscard(card)
    return false
  end
  -- 开局发牌免疫：牢笼在开局被发到时本局免疫
  if card.is_cage and (st._dealing or #hand < 2) and not card._cageImmune then
    card._cageImmune = true
  end
  -- 黑洞吸收上一张：保留黑洞实体（uid/is_blackhole），继承前牌全部特殊词条，前牌进弃牌堆
  if card.is_blackhole and #hand > 0 then
    local prev = table.remove(hand, #hand)
    st.deck:toDiscard(prev)
    local traits = { 'is_multiplier','mult_bonus','is_rps','rps_symbol','is_67','s67_rank',
                     'is_cage','is_chip','chip_value','is_dice','dice_sides','is_remove','is_champion' }
    for _, k in ipairs(traits) do
      if prev[k] ~= nil then card[k] = prev[k] end
    end
    card.absorbed_from = prev.uid
    self:emit({ kind = 'card_discard', card = prev, from = who })
    self:emit({ kind = 'mark_fx', markId = 'black_hole', anchor = who, card = card })
  end
  hand[#hand + 1] = card
  self:emit({ kind = 'deal', target = who, card = card, index = #hand })
  return true
end

function GS:dealInitial()
  local st = self.state
  st._dealing = true
  st._distractorShown = nil
  self:hookDealPre()
  st.cheatIntent = self:decideCheat()
  -- 玩家两张（不凭空造牌：牌靴/弃牌堆皆空时宁缺毋滥）
  local c1 = self:drawCard('player'); if c1 then self:pushHand('player', c1) end
  local c2 = self:drawCard('player'); if c2 then self:pushHand('player', c2) end
  -- 庄家两张（hand[1] 为暗牌）
  local c3 = self:drawCard('dealer'); if c3 then self:pushHand('dealer', c3) end
  local c4 = self:drawCard('dealer'); if c4 then self:pushHand('dealer', c4) end
  st.dealer.holeRevealed = false
  -- 千招 A（暗牌换 BJ）/ E（镜影）在发牌后执行
  if st.cheatIntent then self:executeCheatDeal(st.cheatIntent) end
  -- 职阶：Lancer 玩家发三张
  if st.playerClass and st.playerClass.id == 'lancer' then
    local c = self:drawCard('player')
    if c then self:pushHand('player', c) end
  end
  -- 庄家职阶：Lancer 发三张
  if st.dealerClass and st.dealerClass.id == 'lancer' then
    local c = self:drawCard('dealer')
    if c then
      -- 保证 <=21
      self:pushHand('dealer', c)
      if BJ.handTotal(st.dealer.hand) > 21 then
        table.remove(st.dealer.hand, #st.dealer.hand)
        st.deck:toDiscard(c)
      end
    end
  end
  st._dealing = nil
  self:hookDealAfter()
  self:refreshPlayer()
  self:refreshDealer()
  -- 窥视遗物（算牌师）
  if self:hasRelic('peek_auto') then
    st.peekDepth = math.max(st.peekDepth, 1)
  end
  self:lockBustBetOdds()
  self:refreshShoe()
  self:hookRoundStart()
  -- 假痕迹（干扰项）：发牌后最多物化一次，绑定已公开明牌
  self:emitDistractor()
end

function GS:refreshPlayer()
  local st = self.state
  local p = st.player
  p.total = BJ.handTotal(p.hand)
  p.rawTotal = BJ.handRawTotal(p.hand)
  local berserker = st.playerClass and st.playerClass.id == 'berserker'
  p.busted = p.total > (berserker and 25 or 21)
  if p.is67 or BJ.has67(p.hand) then p.is67 = true; p.busted = false end
  p.blackjack = BJ.isBlackjack(p.hand)
  p.isRps = BJ.rpsSymbol(p.hand) ~= nil
  p.cageBlocked = false
  local n = #p.hand
  if n > 0 and p.hand[n].is_cage and not p.hand[n]._cageImmune then p.cageBlocked = true end
  if p.doubled then p.stood = true end
  return p
end

function GS:refreshDealer()
  local st = self.state
  local d = st.dealer
  d.total = BJ.handTotal(d.hand)
  d.rawTotal = BJ.handRawTotal(d.hand)
  local tolerant = st.dealerClass and (st.dealerClass.id == 'lancer' or st.dealerClass.id == 'berserker')
  d.busted = (tolerant and d.total > 25) or ((not tolerant) and d.total > 21)
  d.is67 = BJ.has67(d.hand)
  d.isRps = BJ.rpsSymbol(d.hand) ~= nil
  return d
end

-- ===================== 玩家行动 =====================

function GS:playerHit()
  local st = self.state
  if st.state ~= 'player' then return self:fail('action_unavailable') end
  local p = st.player
  if p.stood or p.busted or p.surrendered then return self:fail('action_unavailable') end
  if p.cageBlocked then return self:fail('action_unavailable') end
  if st.flags.autoStandNext then
    st.flags.autoStandNext = false
    self:msg('陷阱：自动停牌。', 'info')
    return self:playerStand()
  end
  if self:hasRelic('auto_surrender_16') and p.total >= 16 then
    return self:playerStand()
  end
  if p.blackjack then return self:fail('action_unavailable') end
  if #p.hand >= GS.HAND_MAX then
    self:msg('手牌已满，自动停牌。', 'warning')
    return self:playerStand()
  end
  local hitCard = self:drawCard('player')
  if hitCard then self:pushHand('player', hitCard) end
  self:hookPlayerHit()
  self:refreshPlayer()
  if p.total > 21 and not p.is67 then
    self:emit({ kind = 'sfx', name = 'lose' })
    -- 67 组合自动填满
  end
  if p.is67 and #p.hand < GS.HAND_MAX then self:fill67() end
  if p.busted then
    return self:playerStand()
  end
  if p.total == 21 and not p.is67 then
    return self:playerStand()
  end
  return true
end

function GS:fill67()
  local st = self.state
  local p = st.player
  local i = 0
  while #p.hand < GS.HAND_MAX do
    i = i + 1
    local wasted = st.deck:draw()
    if not wasted then break end -- 牌靴已尽：不凭空造牌，保持守恒
    st.deck:toDiscard(wasted)
    local r = (i % 2 == 1) and '6' or '7'
    local card = DT.mk({ rank = r, suit = 'S', kind = 's67', is_67 = true, s67_rank = r, is_synthetic = true })
    st.deck:assignUid(card)
    p.hand[#p.hand + 1] = card
    self:emit({ kind = 'deal', target = 'player', card = card, index = #p.hand })
  end
  p.total = 21
  p.busted = false
  self:emit({ kind = 'sfx', name = '67' })
end

function GS:playerStand()
  local st = self.state
  if st.state ~= 'player' then return self:fail('action_unavailable') end
  st.player.stood = true
  self:dealerPlay()
  return true
end

function GS:playerDouble()
  local st = self.state
  if st.state ~= 'player' then return self:fail('action_unavailable') end
  local p = st.player
  if #p.hand ~= 2 then return self:fail('cannot_double') end
  if p.blackjack or p.is67 then return self:fail('cannot_double') end
  if p.cageBlocked then return self:fail('cannot_double') end
  if st.chips < st.bet then return self:fail('not_enough_chips') end
  st.chips = st.chips - st.bet
  st.bet = st.bet * 2
  p.doubled = true
  local dblCard = self:drawCard('player')
  if dblCard then self:pushHand('player', dblCard) end
  self:hookPlayerHit()
  self:refreshPlayer()
  self:playerStand()
  return true
end

function GS:playerSurrender()
  local st = self.state
  if st.state ~= 'player' then return self:fail('action_unavailable') end
  local p = st.player
  if not self:hasRelic('late_surrender') then return self:fail('cannot_surrender') end
  if not self:relicById('late_surrender')._active then return self:fail('cannot_surrender') end
  if p.total >= 18 then return self:fail('cannot_surrender') end
  p.surrendered = true
  local refund = math.floor(st.bet * 0.5)
  st.chips = st.chips + refund
  st.result = { outcome = 'push', bet = st.bet, surrendered = true, netChange = refund - st.bet, refund = refund }
  self:setState('result')
  self:scheduleAfterRound()
  self:msg('你投降了，退回 ' .. U.money(refund) .. '。', 'info')
  return true
end

-- ===================== 出千 =====================

function GS:isCheatShielded()
  local st = self.state
  if st.playerClass and st.playerClass.id == 'assassin' then return true end
  local sh = self:relicById('class_assassin_shard')
  if sh and sh._active then return true end
  return false
end

function GS:cheatChance()
  local st = self.state
  local base = self:stageCfg(st.stage).cheat
  if self:hasRelic('cheat_fear') and st.stage == 3 then base = base * 0.5 end
  return base
end

function GS:decideCheat()
  local st = self.state
  if st.mode == 'bar' then return nil end
  if st.stage == 1 then
    -- 阶段 1 不出千，但可能产生干扰项？阶段1 干扰 0
    return nil
  end
  local chance = self:cheatChance()
  local intent = { move = nil, executed = false, tell = nil, distractor = nil }
  -- GDD 476-481：先掷是否出千；只有「不出千」分支才掷干扰项。
  -- 一旦进入出千分支（即使选中的 A/E 被屏蔽而放弃），本小局不再掷干扰项。
  local cheated = self:rchance(chance)
  if cheated then
    local move = self:rweighted(GS.CHEAT_WEIGHTS)
    if self:isCheatShielded() and (move == 'A' or move == 'E') then
      intent.shielded = true
    else
      intent.move = move
    end
    if intent.move == 'B' or intent.move == 'C' or intent.move == 'D' then intent.pending = true end
  end
  if not cheated then
    local suppressed = self:hasRelic('cheat_probe') or self:hasRelic('cheat_eye')
    if not suppressed and self:rchance(self:stageCfg(st.stage).distract) then
      intent.distractor = ({ 'dA', 'dB', 'dC', 'dD', 'dE' })[self:rint(1, 5)]
    end
  end
  return intent
end

function GS:executeCheatDeal(intent)
  local st = self.state
  if intent.move == 'A' then
    local d = st.dealer
    local up = d.hand[2]
    -- GDD 495：前置只看「玩家不是自然 BJ」，不再额外排除 3 张 21。
    if up and not BJ.isBlackjack(st.player.hand) then
      local uv = BJ.cardValue(up)
      -- 可见 A 按 11 计（cardValue 的保守值 1 会让 A 明牌永远不满足），GDD 495。
      if BJ.isAce(up) then uv = 11 end
      if uv + 11 >= 19 then
        local need
        if uv == 10 then need = 'A' elseif uv == 11 then need = '10'
        else need = 19 - uv; if need <= 0 then need = 11 elseif need > 11 then need = 10 end
        if need == 1 or need == 11 then need = 'A' end end
        local hole = d.hand[1]
        local repl
        if need == 'A' then repl = DT.mk({ rank = 'A', suit = 'S', kind = 'basic', is_basic = true, is_synthetic = true })
        else repl = DT.mk({ rank = tostring(need), suit = 'H', kind = 'basic', is_basic = true, is_synthetic = true }) end
        st.deck:assignUid(repl)
        d.hand[1] = repl
        st.deck:toDiscard(hole)
        intent.executed = true
        intent.tell = 'A'
        self:emitTell('A', repl, 'hole')
      end
    end
  elseif intent.move == 'E' then
    local d = st.dealer
    local pc = st.player.hand[1]
    if pc then
      local cp = DT.clone(pc)
      cp.is_synthetic = true; cp._synthCounted = nil
      st.deck:assignUid(cp)
      local hole = d.hand[1]
      d.hand[1] = cp
      st.deck:toDiscard(hole)
      intent.executed = true
      intent.tell = 'E'
      self:emitTell('E', cp, 'hole')
      -- 镜像关联：玩家那张明牌也拿到同一 E 痕迹（蓝菱形关联 cardUID）
      self:emitTell('E', pc, 'player', { link = true })
    end
  end
  -- B/C/D 在庄家抽牌时执行
  if intent.move == 'B' or intent.move == 'C' or intent.move == 'D' then
    intent.pending = true
  end
end

-- 庄家抽一张（含千招 B/C/D 与遗物效果）
function GS:dealerDrawOne()
  local st = self.state
  local d = st.dealer
  local intent = st.cheatIntent
  -- 千招 D：神抽（越序从牌靴取出，不消耗顶部牌）
  if intent and intent.move == 'D' and not intent.executed then
    local need = 21 - d.total
    if need >= 2 then
      -- 先找恰好凑到 21 的那张（value == need）
      local found = st.deck:drawWhere(function(card)
        local v = nil
        if BJ.isAce(card) then v = 11 else
          local okv, cv = pcall(BJ.cardValue, card); if okv then v = cv end
        end
        return type(v) == 'number' and v == need
      end)
      -- 没有精确牌时按 GDD 回退：当前 ≤10 要 A，其余要 10
      if not found then
        local wantAce = d.total <= 10
        found = st.deck:drawWhere(function(card)
          if BJ.isAce(card) then return wantAce end
          if card.value ~= nil then return false end
          local okv, v = pcall(BJ.cardValue, card)
          return (not wantAce) and okv and v == 10
        end)
      end
      if found then
        intent.executed = true
        intent.tell = 'D'
        self:emitTell('D', found, 'dealer')
        self:pushHand('dealer', found)
        self:refreshDealer()
        self:hookDealerHit()
        return found
      end
    end
  end
  -- 遗物：庄家磁铁 / 庄家无面
  if self:hasRelic('dealer_magnet') and self:rchance(0.55) then
    local c = DT.mk({ rank = tostring(self:rint(2, 6)), suit = 'C', kind = 'basic', is_basic = true, is_synthetic = true })
    st.deck:assignUid(c)
    self:pushHand('dealer', c)
    self:refreshDealer()
    return c
  end
  local c = self:drawCard('dealer')
  if not c then return nil end
  -- 千招 B：抽牌必 10
  if intent and intent.pending and intent.move == 'B' then
    local t = d.total
    if t <= 16 then
      local spec
      if t <= 10 then spec = { rank = 'A', suit = 'S' }
      elseif t <= 15 then spec = { rank = '10', suit = 'H' }
      else spec = { rank = '4', suit = 'D' } end
      local repl = DT.mk({ rank = spec.rank, suit = spec.suit, kind = 'basic', is_basic = true, is_synthetic = true })
      st.deck:assignUid(repl)
      st.deck:toDiscard(c)
      c = repl
      intent.executed = true
      intent.tell = 'B'
      self:emitTell('B', c, 'dealer')
    end
  end
  -- 千招 C：低牌换掉
  if intent and intent.pending and intent.move == 'C' and not intent.executed then
    local v = BJ.cardValue(c)
    if v >= 2 and v <= 6 and (d.total + v) < 19 then
      local oldRank = c.rank or c.s67_rank or tostring(c.value or '?')
      local repl = DT.mk({ rank = '10', suit = 'C', kind = 'basic', is_basic = true, is_synthetic = true })
      st.deck:assignUid(repl)
      c._tellOldRank = oldRank
      st.deck:toDiscard(c)
      c = repl
      intent.executed = true
      intent.tell = 'C'
      intent.oldRank = oldRank
      self:emitTell('C', c, 'dealer', { oldRank = oldRank })
    end
  end
  -- 遗物：庄家无面
  if self:hasRelic('no_face_dealer') and BJ.isFace(c) then
    local repl = DT.mk({ rank = '10', suit = c.suit or 'C', kind = 'basic', is_basic = true, is_synthetic = true })
    st.deck:assignUid(repl)
    st.deck:toDiscard(c)
    c = repl
  end
  self:pushHand('dealer', c)
  self:refreshDealer()
  self:hookDealerHit()
  return c
end

function GS:dealerPlay()
  local st = self.state
  self:setState('dealer')
  st.dealer.steps = 0
  self:emit({ kind = 'state', from = 'player', to = 'dealer' })
  self:after(0.3, function()
    st.dealer.holeRevealed = true
    self:emit({ kind = 'sfx', name = 'deal' })
    self:dealerStep()
  end)
end

function GS:dealerStep()
  local st = self.state
  local d = st.dealer
  -- 调酒技能：强制庄家停牌（dealer_stop / dealer_draw_2_stop）
  if d.forcedStand then
    d.forcedStand = nil
    return self:settle()
  end
  self:refreshDealer()
  -- 行动步数上限：正常 5 步，被干扰 3 步（GDD line 203）
  d.steps = d.steps or 0
  local drawCap = (st.cheatIntent and st.cheatIntent.distractor) and 3 or 5
  if d.steps >= drawCap or #d.hand >= GS.HAND_MAX then
    self:after(0.3, function() self:settle() end)
    return
  end
  -- 庄家职阶：Rider 跳过
  if st.dealerClass and st.dealerClass.id == 'rider' and (st.dealerClass.usesLeft or 0) > 0 then
    if self:rchance(0.5) then
      st.dealerClass.usesLeft = st.dealerClass.usesLeft - 1
      self:msg('庄家跳过本局。', 'warning')
      self:after(0.3, function() self:settle() end)
      return
    end
  end
  -- 牢笼：庄家明牌最末尾是牢笼且未免疫时不能再要牌
  local dn = #d.hand
  if dn > 0 and d.hand[dn].is_cage and not d.hand[dn]._cageImmune then
    self:after(0.3, function() self:settle() end)
    return
  end
  -- 火焰标记：牌靴下一张若是火焰牌，庄家不得摸、只能停牌
  local topCard = st.deck and st.deck.drawPile and st.deck.drawPile[1]
  if topCard and Marks.isMarked(topCard) and topCard.marked.markId == 'mark_flame' then
    self:emit({ kind = 'mark_fx', markId = 'mark_flame', anchor = 'dealer', card = topCard })
    self:after(0.3, function() self:settle() end)
    return
  end
  -- 庄家爆牌 -> 停
  local bustAt = 21
  if st.dealerClass and st.dealerClass.id == 'lancer' then bustAt = 25 end
  if st.dealerClass and st.dealerClass.id == 'berserker' then bustAt = 25 end
  if self:hasRelic('cheat_buster_1') and st.cheatIntent and st.cheatIntent.executed then bustAt = 21 end
  if d.total > bustAt then
    self:after(0.3, function() self:settle() end)
    return
  end
  local playerTotal = st.player.total
  local difficulty = d.difficulty or 1
  if self:hasRelic('dealer_blind') then difficulty = 1 end
  if st.dealerClass and st.dealerClass.id == 'assassin' and st.stage == 3 then difficulty = 2 end
  if self:hasRelic('anti_cheat') and st.stage == 3 then playerTotal = nil end
  local opts = { bustAt = bustAt }
  if self:hasRelic('dealer_fatigue') then opts.standOn = 17 end
  -- Assassin 玩家 / 杀之残卷 屏蔽读牌
  if st.playerClass and st.playerClass.id == 'assassin' then playerTotal = nil end
  if self:hasRelic('class_assassin_shard') and self:relicById('class_assassin_shard')._active then playerTotal = nil end
  local hit = BJ.dealerShouldHit(d.hand, difficulty, playerTotal, opts)
  if st.dealerClass and st.dealerClass.id == 'lancer' and d.total > 21 then hit = false end
  if hit then
    d.steps = d.steps + 1
    self:after(0.35, function()
      self:dealerDrawOne()
      self:dealerStep()
    end)
  else
    self:after(0.3, function() self:settle() end)
  end
end

-- ===================== 指认 =====================

function GS:accuse()
  local st = self.state
  if st.state ~= 'player' and st.state ~= 'dealer' then return self:fail('action_unavailable') end
  if st.flags.accusedThisRound then return self:fail('accuse_used') end
  st.flags.accusedThisRound = true
  local executed = st.cheatIntent and st.cheatIntent.executed == true
  local res = { attempted = true, correct = executed, bonus = 0 }
  if executed then
    local bonus = st.bet * 3
    if self:hasRelic('iron_evidence') then bonus = st.bet * 5; self:consumeRelic('iron_evidence') end
    for i = 1, #st.relics do
      local d = st.relics[i].def
      if d.special == 'accuse_bonus' then
        bonus = bonus + st.bet * (d.param1 or 0)
        self:consumeRelic(st.relics[i].id)
      end
    end
    res.bonus = bonus
    -- 指认成功：打断庄家待执行队列，强制玩家赢并结算
    self.queue = {}
    st.accuseCorrect = true
    st.accuseRes = res
    st.accuseBonus = bonus
    st.chips = st.chips + bonus
    st.streak = st.streak + 1
    st.player.stood = true
    st.dealer.holeRevealed = true
    self:emit({ kind = 'shake', amount = 10 })
    self:emit({ kind = 'sfx', name = 'accuse_ok' })
    self:msg('指认成功！铁证如山，+' .. U.money(bonus), 'success')
    self:settle()
  else
    local penalty = math.min(50, st.bet)
    st.chips = st.chips - penalty
    st.streak = 0
    res.penalty = penalty
    self:emit({ kind = 'sfx', name = 'accuse_bad' })
    self:msg('指认失败，罚 ' .. U.money(penalty), 'error')
    -- 猜错：庄家继续行动（若在玩家回合则进入庄家回合）
    if st.state == 'player' then self:dealerPlay() end
  end
  return true
end

-- ===================== 结算 =====================

function GS:scoreCtxFor(opts)
  local st = self.state
  return Scoring.newCtx(st.player, st.dealer, st, {
    cardChips = opts.cardChips or 0,
    cardMultBonus = opts.cardMultBonus or 0,
    xMult = opts.xMult or 1,
    outcome = opts.outcome or 'dealer',
    bet = st.bet,
    naturalBJ = st.player.blackjack,
    is67 = st.player.is67,
    chipsBefore = opts.chipsBefore or st.chips,
    dealerUpAce = st.dealer.hand[2] and BJ.isAce(st.dealer.hand[2]),
  })
end

function GS:collectFinalResult()
  local st = self.state
  local p, d = st.player, st.dealer
  self:refreshPlayer(); self:refreshDealer()
  local outcome
  if p.is67 or BJ.has67(p.hand) then
    outcome = 'player'; p.busted = false
  elseif p.busted then
    outcome = 'dealer'
  elseif d.busted then
    outcome = 'player'
  elseif p.isRps and d.isRps then
    local ps, ds = BJ.rpsSymbol(p.hand), BJ.rpsSymbol(d.hand)
    if ps == ds then outcome = 'player'
    elseif (ps == 'rock' and ds == 'scissors') or (ps == 'scissors' and ds == 'paper') or (ps == 'paper' and ds == 'rock') then
      outcome = 'player'
    else outcome = 'dealer' end
  else
    outcome = BJ.compare(p.total, d.total, p.busted, d.busted)
  end
  -- 庄家职阶：Berserker 强制
  if st.dealerClass and st.dealerClass.id == 'berserker' and d.total >= 22 and d.total <= 25 then
    if p.total <= d.total then outcome = 'dealer' end
  end
  -- 玩家 Berserker：25 内不爆，未爆且 >= 庄家判胜
  if st.playerClass and st.playerClass.id == 'berserker' and p.total >= 22 and p.total <= 25 then
    if p.total >= d.total then outcome = 'player' else outcome = 'dealer' end
  end
  return outcome
end

function GS:lockBustBetOdds()
  local st = self.state
  if not (st.bustBet and st.bustBet.on and st.bustBet.locked) or st.bustBet.odds then return end
  local prob, unknown, info = nil, false, nil
  local up = st.dealer.hand and st.dealer.hand[2]
  if up then
    -- 完整牌靴；未知暗牌也计入候选池（不在显示层泄漏其身份）
    local pool = {}
    for i = 1, #st.deck.drawPile do pool[#pool + 1] = st.deck.drawPile[i] end
    local holeRevealed = st.dealer.holeRevealed == true
    if not holeRevealed and st.dealer.hand[1] then pool[#pool + 1] = st.dealer.hand[1] end
    local dotp = { cards = pool, playerTotal = st.player.total, holeUnknown = not holeRevealed,
                   holeCard = (holeRevealed and st.dealer.hand[1]) or nil }
    local okp, p, pinfo = pcall(SI.dealerBustOdds, { up }, st.dealer.difficulty or 1, dotp)
    if okp and type(p) == 'number' then
      prob = p
    else
      unknown = true
      info = (type(p) == 'table' and p) or pinfo or { reason = 'error', message = tostring(p) }
    end
  else
    unknown = true
    info = { reason = 'no_upcard' }
  end
  local odds
  if unknown or prob == nil then
    unknown = true
    odds = 8.0
  elseif prob <= 0 then
    odds = 8.0
  else
    odds = 0.9 / prob
    if odds < 1.2 then odds = 1.2 elseif odds > 8.0 then odds = 8.0 end
  end
  if unknown then st.bustBet.prob = nil else st.bustBet.prob = prob end
  st.bustBet.unknown = unknown or nil
  st.bustBet.oddsInfo = info
  st.bustBet.odds = odds
end

function GS:settle()
  local st = self.state
  self:setState('result_pending')
  self:refreshPlayer(); self:refreshDealer()
  -- 类 Berserker 的 22-25 免疫
  local function tolerantBust(side)
    if side == 'player' and st.playerClass and st.playerClass.id == 'berserker' then return true end
    if side == 'dealer' and st.dealerClass and st.dealerClass.id == 'lancer' then return true end
    if side == 'dealer' and st.dealerClass and st.dealerClass.id == 'berserker' then return true end
    return false
  end
  local cardChips, cardMult = self:cardBonuses('player')
  local outcome = self:collectFinalResult()
  local ctx = self:scoreCtxFor({ cardChips = cardChips, cardMultBonus = cardMult, outcome = outcome, chipsBefore = st.chips + st.bet })
  ctx.stage = st.stage
  ctx.creditUsed = st.creditUsed
  ctx.gs = self
  Scoring.run(ctx, self:activeRelics(), self.scoreHandlers, self)
  if st.accuseCorrect then ctx.forceResult = 'player' end
  -- 反作弊类覆盖
  if self:hasRelic('cheat_buster_1') and st.cheatIntent and st.cheatIntent.executed then
    ctx.forceResult = 'dealer'
    st.dealer.busted = true
  end
  local winnings, info = Scoring.finalize(ctx)
  local result = {
    outcome = info.outcome, bet = st.bet, baseChips = info.baseChips,
    additiveChips = info.additive, mult = info.mult, xMult = info.x_mult,
    winnings = winnings, netChange = info.netChange, chips = st.chips,
    breakdown = info.breakdown, naturalBJ = st.player.blackjack, is67 = st.player.is67,
    bustBet = { on = st.bustBet.on, amount = st.bustBet.amount, odds = st.bustBet.odds, hit = false, payout = 0 },
    accuse = { attempted = false, correct = false, bonus = 0 },
    marks = { discovered = 0, penalty = 0 },
    forcedStage = false, events = {}, halfLoss = info.halfLoss, errors = info.errors,
  }
  if st.accuseRes then
    result.accuse = st.accuseRes
    result.forcedWin = true
    result.netChange = (result.netChange or 0) + (st.accuseBonus or 0)
  end
  st.accuseCorrect, st.accuseRes, st.accuseBonus = nil, nil, nil
  self:finalizeRound(result, false)
end

function GS:cardBonuses(who)
  local st = self.state
  local hand = (who == 'player') and st.player.hand or st.dealer.hand
  local chips, mult = 0, 0
  for i = 1, #hand do
    local c = hand[i]
    if c.is_chip then chips = chips + (BJ.cardValue(c)) * 100 end
    if c.mult_bonus then mult = mult + (c.mult_bonus or 0) end
    if c.is_dice6 then
      if not c.dice_token then c.dice_token = self:rint(1, 6) end
      chips = chips + c.dice_token * 100
    elseif c.is_dice20 then
      if not c.dice_token then c.dice_token = self:rint(1, 20) end
      chips = chips + c.dice_token * 100
    end
  end
  return chips, mult
end

function GS:finalizeRound(result, forced)
  local st = self.state
  -- 标记发现判定
  if st.mode ~= 'bar' then
    local sharp = self:hasRelic('sharp_family')
    local roll = Marks.rollDiscovery(st, self.rng, { sharpFamily = sharp, suppressed = self:hasRelic('cheat_probe') and st.stage >= 2 })
    if roll.count > 0 then
      st.chips = st.chips - roll.penalty
      result.marks = { discovered = roll.count, penalty = roll.penalty, half = roll.half }
      if not roll.keep then Marks.remove(roll.card) end
      st.cheatIntent = nil
      self:msg('标记被发现！罚 ' .. U.money(roll.penalty), 'error')
      if sharp then self:consumeRelic('sharp_family') end
    end
  end
  -- 结算筹码：winnings 已在 finalize 内包含胜负/平局基础与遗物筹码
  st.chips = st.chips + (result.winnings or 0)
  if result.outcome == 'dealer' and result.halfLoss then
    st.chips = st.chips + math.floor(st.bet * 0.5)
  end
  -- 爆注结算：边注已在下注时扣除；命中返还本金+彩金，未中没收（对冲基金返一半、彩金 ×1.25）
  if st.bustBet.on and (st.bustBet.amount or 0) > 0 then
    local d = st.dealer
    local hit = (d.busted == true) or ((d.total or 0) > 21)
    local odds = st.bustBet.odds or 1.2
    local bb = result.bustBet or {}
    bb.on = true
    bb.amount = st.bustBet.amount
    bb.odds = odds
    bb.hit = hit
    bb.payout = 0
    if hit then
      local profit = math.floor(st.bustBet.amount * odds)
      if self:hasRelic('hedge_fund') then profit = math.floor(profit * 1.25) end
      local payout = st.bustBet.amount + profit
      st.chips = st.chips + payout
      bb.payout = payout
      self:msg('爆注命中！赔率 ' .. string.format('%.2f', odds) .. '，返还 ' .. U.money(payout), 'success')
    elseif self:hasRelic('hedge_fund') then
      local back = math.floor(st.bustBet.amount * 0.5)
      st.chips = st.chips + back
      bb.payout = back
    end
    result.bustBet = bb
  end
  -- 债务收藏家：输时先扣债
  if result.outcome == 'dealer' and st.debt and st.debt > 0 then
    local pay = math.min(st.debt, st.chips)
    st.chips = st.chips - pay
    st.debt = st.debt - pay
  end
  result.chips = st.chips
  st.result = result
  -- GDD §16.1 加速开店：玩家本局恰好 21 点时 roundsSinceShop 额外 +1（可累加；加倍后 21 同样计入；酒吧排除）
  if st.mode ~= 'bar' and st.player and (st.player.busted ~= true) and (st.player.total or 0) == 21 then
    st.roundsSinceShop = (st.roundsSinceShop or 0) + 1
  end
  -- 连胜
  if result.outcome == 'player' then st.streak = st.streak + 1
  elseif result.outcome == 'dealer' then st.streak = 0 end
  if result.is67 or (st.player and st.player.is67) then st.streak = st.streak end
  self:setState('result')
  self:logline(string.format('第 %d 局：%s 净变化 %s', st.round, tostring(result.outcome), U.money(result.netChange or 0)))
  self:syncRelicAliases()
  self:scheduleAfterRound()
end

function GS:scheduleAfterRound()
  local st = self.state
  if st.mode == 'bar' then
    st.afterResult = self:barAfterRound()
    return
  end
  local nextState = 'result'
  local autoEnd = (self.settings == nil) or (self.settings.autoEndOnBroke ~= false)
  if st.chips <= 0 and autoEnd then
    nextState = 'forceExit'
  elseif st.supremeClear then
    nextState = 'stageClear'
  elseif st.stage == 3 and st.chips >= st.stageTarget then
    nextState = 'stageClear'
  elseif st.roundsInStage >= st.stageRounds then
    -- 阶段 1/2 必须跑满轮数后才判定是否达标
    if st.chips >= st.stageTarget then nextState = 'stageClear' else nextState = 'forceExit' end
  elseif st.roundsSinceShop >= GS.SHOP_EVERY then
    nextState = 'shop'
  end
  st.afterResult = nextState
end

function GS:continue()
  local st = self.state
  if st.state == 'result' then
    local nextState = st.afterResult or 'bet'
    if nextState == 'shop' then
      st.roundsSinceShop = 0
      self:openShop()
    elseif nextState == 'stageClear' then
      self:setState('stageClear')
    elseif nextState == 'forceExit' then
      self:recordRunEnd(false)
      self:setState('forceExit')
    elseif nextState == 'bar_ending' then
      self:barEnding()
    elseif st.mode == 'bar' then
      self:barBeginRound()
    else
      self:beginBet()
    end
    return true
  elseif st.state == 'stageClear' then
    self:advanceStage()
    return true
  elseif st.state == 'victory' or st.state == 'forceExit' then
    self:setState('title')
    return true
  elseif st.state == 'bar_ending' then
    self:setState('title')
    return true
  end
  return self:fail('action_unavailable')
end

function GS:advanceStage()
  local st = self.state
  -- 阶段幸存者：阶段完成时 +$2,000（每个阶段只发一次）
  if self:hasRelic('stage_survivor') and not st.flags['stageBonus' .. st.stage] then
    st.flags['stageBonus' .. st.stage] = true
    self.specials.stage_bonus(self, self:relicById('stage_survivor'))
  end
  if st.stage >= 3 then
    self:recordRunEnd(true)
    self:setState('victory')
    return
  end
  if st.stage == 2 and not st.playerClass then
    st.classOffer = { mode = 'classSelect', candidates = self:rollClassCandidates() }
    self:setState('classSelect')
    return
  end
  local prevDealer = st.dealerClass and st.dealerClass.id
  self:applyStage(st.stage + 1)
  self:hookStageStart()
  -- 庄家职阶（困难模式）：换阶段必须与上一个不同
  if st.mode == 'hard' then
    local nid = Classes.randomAnother(prevDealer, self.rng) or self:rpick(Classes.ORDER)
    st.dealerClass = Classes.dealerRuntime(nid)
  end
  self:buildShoe()
  self:beginBet()
  self:msg('进入 ' .. st.stageName, 'info')
end

function GS:recordRunEnd(won)
  local st = self.state
  st.progress.maxStage = math.max(st.progress.maxStage or 1, st.stage)
  st.progress.maxChips = math.max(st.progress.maxChips or 0, st.chips)
  if won then
    if st.mode == 'hard' then
      st.progress.hardCleared = true
      st.progress.hardClearCount = (st.progress.hardClearCount or 0) + 1
      if st.progress.bestRoundsHard == 0 or st.round < st.progress.bestRoundsHard then st.progress.bestRoundsHard = st.round end
    else
      if st.progress.bestRoundsBasic == 0 or st.round < st.progress.bestRoundsBasic then st.progress.bestRoundsBasic = st.round end
    end
  end
  st.progress.totalRuns = (st.progress.totalRuns or 0) + 1
  self:saveProgress()
end

function GS:saveProgress()
  if not self.persist then return false end
  local meta = {
    hardCleared = self.state.progress.hardCleared, hardClearCount = self.state.progress.hardClearCount,
    maxStage = self.state.progress.maxStage, maxChips = self.state.progress.maxChips,
    totalRuns = self.state.progress.totalRuns, bestRoundsBasic = self.state.progress.bestRoundsBasic,
    bestRoundsHard = self.state.progress.bestRoundsHard,
  }
  return self.persist:writeProgress({ version = 1, meta = meta, settings = self.settings })
end

-- ===================== 遗物 special 注册 =====================

function GS:specialHandlerIds()
  local ids, seen = {}, {}
  for k in pairs(self.specials) do if not seen[k] then seen[k] = true; ids[#ids + 1] = k end end
  for k in pairs(self.scoreHandlers) do if not seen[k] then seen[k] = true; ids[#ids + 1] = k end end
  return ids
end

function GS:registerSpecials()
  local S = self.specials
  local H = self.scoreHandlers
  local st = function() return self.state end

  -- ---------- 结算链处理器（ctx） ----------
  H.stage_win = function(ctx)
    -- 21 至尊：恰好 21 点直接判该阶段胜利，奖励等同阶段目标并立刻转阶段（不占本局计数）
    local gs = ctx.gs
    local gst = gs and gs.state
    if ctx.player.total == 21 and gst then
      gst.supremeClear = true
      local reward = gst.stageTarget or 0
      ctx.score.chips = ctx.score.chips + reward
      ctx.score.breakdown[#ctx.score.breakdown + 1] = { label = '21 至尊', kind = 'chips', value = reward }
      if gst.roundsInStage and gst.roundsInStage > 0 then gst.roundsInStage = gst.roundsInStage - 1 end
      gs:msg('21 至尊：本阶段直接通关！', 'success')
    end
  end
  H.first_hit_safe = function() end -- 在 hookPlayerHit 中处理
  H.soft_22_safe = function(ctx)
    if ctx.player.total == 22 and BJ.isSoft(ctx.player.hand) then
      ctx.player.busted = false
      if ctx.outcome == 'dealer' then ctx.outcome = 'push'; ctx.forceResult = 'push' end
    end
  end
  H.soft_22_win = function(ctx)
    if ctx.player.total == 22 and BJ.isSoft(ctx.player.hand) then
      ctx.player.busted = false
      ctx.forceResult = 'player'
    end
  end
  H.last_card_save = function(ctx)
    if ctx.player.busted and #ctx.player.hand >= GS.HAND_MAX then ctx.player.busted = false end
  end
  H.ace_revolution = function(ctx)
    local total = 0
    for i = 1, #ctx.player.hand do
      total = total + (BJ.isAce(ctx.player.hand[i]) and 11 or BJ.cardValue(ctx.player.hand[i]))
    end
    if total <= 21 then
      ctx.player.total = total
      ctx.player.busted = false
      ctx.outcome = BJ.compare(total, ctx.dealer.total, false, ctx.dealer.busted)
    end
  end
  H.shard_saber = function(ctx)
    if ctx.outcome == 'player' then ctx.score.mult = ctx.score.mult + 0.5 end
  end
  H.shard_berserker = function(ctx)
    if ctx.player.total >= 22 and ctx.player.total <= 25 then ctx.forceResult = 'player' end
  end

  -- ---------- 发牌 / 手牌 hook ----------
  S.ace_guarantee = function() end
  S.second_ace = function() end
  S.ten_guarantee = function() end
  S.jackpot_two = function() end
  S.third_ten = function() end
  S.black_hole_absorb = function() end
  S.card_pack = function(gs, inst, arg)
    local n = (inst and inst.def and inst.def.param1) or 1
    for i = 1, n do
      local card = gs:drawCard('player')
      if card then gs:pushHand('player', card) end
    end
    gs:refreshPlayer()
  end
  S.eight_ball = function(gs)
    gs:giveNamedCard('player', { rank = '8', suit = 'S' })
  end
  S.give_card = function(gs, inst)
    local rank = tostring((inst and inst.def and inst.def.param1) or 'A')
    gs:giveNamedCard('player', { rank = rank, suit = 'S' })
  end
  S.hit_to_20 = function() end
  S.pair_to_21 = function() end
  S.auto_stand_next = function() end
  S.excluded = function() end

  -- ---------- 抽取偏好 ----------
  S.ace_magnet = function() end
  S.ten_magnet = function() end
  S.chase_ten = function() end
  S.chase_ace = function() end
  S.auto_stand_16 = function() end

  -- ---------- 庄家侧 ----------
  S.dealer_fatigue = function() end
  S.dealer_blind = function() end
  S.anti_cheat = function() end
  S.dealer_magnet = function() end
  S.no_face_dealer = function() end
  S.suppress_distractor = function() end
  S.cheat_force_bust = function() end
  S.halve_cheat = function() end
  S.first_hit_safe = function() end

  -- ---------- 下注 / 经济 ----------
  S.double_bet = function(gs, inst)
    if not gs.state.flags.doubleBetUsed then
      gs.state.flags.doubleBetUsed = true
      gs.state.bet = gs.state.bet * 2
      gs:msg('倍投：本局注额翻倍。', 'info')
    end
  end
  S.force_min_bet = function(gs)
    local min = gs:betLimits()
    if gs.state.bet < min then gs.state.bet = min end
  end
  S.late_surrender = function() end
  S.credit = function() end
  S.stage_bonus = function(gs, inst)
    local v = (inst and inst.def and inst.def.param1) or 2000
    gs.state.chips = gs.state.chips + v
    gs:msg('阶段奖励 +' .. U.money(v), 'success')
  end
  S.debt_borrow = function(gs, inst)
    local v = (inst and inst.def and inst.def.param1) or 5000
    gs.state.chips = gs.state.chips + v
    gs.state.debt = (gs.state.debt or 0) + v
    gs:msg('借债 +' .. U.money(v) .. '（须偿还）', 'warning')
  end
  S.hedge_fund = function() end
  S.iron_evidence = function() end
  S.accuse_bonus = function() end

  -- ---------- 标记 / 情报 ----------
  S.ink_half = function() end
  S.mark_limit_up = function() end
  S.sharp_family = function() end
  S.mind_memory = function(gs)
    local d = gs.state.dealer.hand[1]
    if d then gs.state.dealer.holeRevealed = true; gs:msg('心眼：看穿暗牌。', 'info') end
  end
  S.reveal_ink = function(gs)
    for _, list in ipairs({ gs.state.deck.drawPile, gs.state.dealer.hand, gs.state.player.hand }) do
      for i = 1, #list do
        if Marks.isInk(list[i]) then list[i].marked.revealed = true; list[i].revealed = true end
      end
    end
    gs:refreshShoe()
  end
  S.peek = function(gs, inst)
    local depth = (inst and inst.def and inst.def.param1) or 1
    gs:revealShoeRange(1, depth, 'peek')
    gs:msg('窥视前 ' .. depth .. ' 张。', 'info')
  end
  S.peek_auto = function(gs, inst)
    gs.state.peekDepth = math.max(gs.state.peekDepth or 0, (inst and inst.def and inst.def.param1) or 1)
    gs:refreshShoe()
  end
  S.burn = function(gs, inst)
    local n = (inst and inst.def and inst.def.param1) or 1
    local burned = 0
    for i = 1, n do
      local card = gs.state.deck:draw()
      if card then gs.state.deck:toRemoved(card); burned = burned + 1 end
    end
    gs:refreshShoe()
    gs:msg('焚牌 ' .. burned .. ' 张。', 'info')
  end
  S.reveal = function(gs, inst)
    local a = (inst and inst.def and inst.def.param1) or 1
    local b = (inst and inst.def and inst.def.param2) or a
    gs:revealShoeRange(a, b, 'reveal')
    gs:msg('揭示第 ' .. a .. '~' .. b .. ' 张。', 'info')
  end
  S.rod = function(gs, inst)
    gs.state.rodMode = (inst and inst.def and inst.def.param1) or 'standard'
    gs.state.shoeOpen = true
    gs:msg('钓具就绪：' .. tostring(gs.state.rodMode), 'info')
  end
  S.discard_rinse = function(gs, inst)
    gs.state.deck:shuffleDiscardIn()
    gs:refreshShoe()
    gs:msg('弃牌堆洗回抽牌堆。', 'info')
  end
  S.discard_backflow = function(gs, inst)
    local n = (inst and inst.def and inst.def.param1) or 3
    for i = 1, n do
      local d = gs.state.deck.discardPile
      if #d == 0 then break end
      local card = table.remove(d, #d)
      gs.state.deck:addToDraw(card)
    end
    gs:refreshShoe()
  end
  S.discard_salvager = function(gs, inst)
    local rem = gs.state.deck.removed
    if #rem > 0 then
      local card = table.remove(rem, #rem)
      gs.state.deck:addToDraw(card)
      gs:msg('打捞：' .. (card.label or '?'), 'info')
    end
    gs:refreshShoe()
  end
  S.gain_mark = function(gs, inst)
    local id = (inst and inst.def and inst.def.param1) or 'mark_vanish'
    Marks.gainSpecial(gs.state, id)
    gs:msg('获得特种标记。', 'success')
  end

  -- ---------- 职阶残卷主动 ----------
  S.shard_rider = function(gs)
    gs.state.flags.riderUsedThisRound = false
    gs:msg('骑：本局可跳过。', 'info')
  end
  S.shard_archer = function(gs)
    gs:revealShoeRange(1, 3, 'archer')
  end
  S.shard_lancer = function(gs)
    local card = gs:drawCard('player')
    if card then gs:pushHand('player', card) end
    gs:refreshPlayer()
  end
  S.shard_assassin = function(gs)
    gs.state.cheatIntent = nil
    gs.state.flags.assassinSuppress = true
    gs:msg('杀：庄家本局不出千。', 'info')
  end
  S.shard_caster = function(gs)
    gs.state.flags.casterBoost = true
    gs:msg('术：本局最终倍率 +1。', 'info')
  end
  S.shard_saber = function() end
  S.shard_berserker = function() end
  S.open_shop_early = function(gs)
    if gs.state.state == 'player' or gs.state.state == 'bet' then
      gs.state.roundsSinceShop = 0
      gs:openShop()
    end
  end
end

-- ===================== hook 实现 =====================

function GS:hookRelicGained(inst) end
function GS:hookShoeRebuilt() end
function GS:hookDealPre() end
function GS:hookRoundStart()
  local st = self.state
  st.flags.doubleBetUsed = false
  st.flags.assassinSuppress = false
  st.flags.casterBoost = false
  if self:hasRelic('mind_memory') and self:rchance(0.5) then
    if st.dealer.hand[1] then st.dealer.holeRevealed = true end
  end
end

function GS:giveNamedCard(who, spec)
  local st = self.state
  local card = DT.mk({ rank = spec.rank or 'A', suit = spec.suit or 'S', kind = 'basic', is_basic = false, is_synthetic = true })
  st.deck:assignUid(card)
  local hand = self:handOf(who)
  if #hand >= GS.HAND_MAX then return false end
  hand[#hand + 1] = card
  self:emit({ kind = 'deal', target = who, card = card, index = #hand })
  self:refreshPlayer(); self:refreshDealer()
  return true
end

function GS:replaceCard(who, index, newcard)
  if not newcard then return false end
  local hand = self:handOf(who)
  if not hand[index] then return false end
  local old = hand[index]
  hand[index] = newcard
  self.state.deck:toDiscard(old)
  self:emit({ kind = 'deal', target = who, card = newcard, index = index })
  self:refreshPlayer(); self:refreshDealer()
  return true
end

function GS:hookDealAfter()
  local st = self.state
  if self:hasRelic('ace_guarantee') and not BJ.hasAce(st.player.hand) then
    self:replaceCard('player', 2, self:drawCard('player'))
  end
  if self:hasRelic('second_ace') then
    if not BJ.isAce(st.player.hand[2]) then
      local c = DT.mk({ rank = 'A', suit = 'H', kind = 'basic', is_synthetic = true })
      st.deck:assignUid(c)
      self:replaceCard('player', 2, c)
    end
  end
  if self:hasRelic('ten_guarantee') and not BJ.isTenValue(st.player.hand[1]) and not BJ.isTenValue(st.player.hand[2]) then
    local c = DT.mk({ rank = '10', suit = 'D', kind = 'basic', is_synthetic = true })
    st.deck:assignUid(c)
    self:replaceCard('player', 2, c)
  end
  if self:hasRelic('jackpot_two') then
    local c1 = st.player.hand[1]
    if c1 and st.player.hand[2] and c1.rank ~= st.player.hand[2].rank then
      local c = DT.mk({ rank = c1.rank, suit = 'C', kind = 'basic', is_synthetic = true })
      st.deck:assignUid(c)
      self:replaceCard('player', 2, c)
    end
  end
  if self:hasRelic('always_10_on_third') and #st.player.hand >= 3 and not BJ.isTenValue(st.player.hand[3]) then
    local c = DT.mk({ rank = '10', suit = 'C', kind = 'basic', is_synthetic = true })
    st.deck:assignUid(c)
    self:replaceCard('player', 3, c)
  end
  if self:hasRelic('pair_to_21') and BJ.isPair(st.player.hand) then
    local c = self:drawCard('player')
    if c then self:pushHand('player', c) end
  end
  self:refreshPlayer()
end

function GS:hookBetPre()
  local st = self.state
  if self:hasRelic('bet_minimizer') then
    local min = self:betLimits()
    st.bet = math.max(50, min)
  end
  if self:hasRelic('bet_syndicate') then
    local inst = self:relicById('bet_syndicate')
    if inst and not inst._usedThisGame then
      inst._usedThisGame = true
      self.specials.double_bet(self, inst, nil)
    end
  end
end

function GS:hookPlayerHit()
  local st = self.state
  local p = st.player
  local hand = p.hand
  local n = #hand
  if n == 0 then return end
  local just = hand[n]
  -- 偏好取牌
  local function prefer(match)
    local card = st.deck:drawWhere(match)
    if card then
      hand[n] = card
      st.deck:toDiscard(just)
      self:emit({ kind = 'deal', target = 'player', card = card, index = n })
      self:refreshPlayer()
      return true
    end
    return false
  end
  if self:hasRelic('ace_magnet') and not BJ.isAce(just) and self:rchance(0.12) then
    prefer(function(card) return BJ.isAce(card) end)
  elseif self:hasRelic('soft_hand_magnet') and not BJ.isAce(just) and self:rchance(0.25) then
    prefer(function(card) return BJ.isAce(card) end)
  elseif self:hasRelic('ten_magnet') and not BJ.isTenValue(just) and self:rchance(0.12) then
    prefer(function(card) return BJ.isTenValue(card) end)
  elseif self:hasRelic('peek_and_chase') and not BJ.isTenValue(just) and self:rchance(0.30) then
    prefer(function(card) return BJ.isTenValue(card) and not BJ.isAce(card) end)
  end
  -- 首击保护
  if self:hasRelic('first_hit_safe') and not st.flags.firstHitUsed then
    st.flags.firstHitUsed = true
    if p.busted then
      local removed = table.remove(hand)
      if removed then st.deck:toDiscard(removed) end
      self:refreshPlayer()
      self:msg('首击保护：撤销爆牌。', 'info')
    end
  end
  -- 16 自动停牌
  if self:hasRelic('auto_surrender_16') and p.total >= 16 and not p.busted then
    p.stood = true
  end
  if self:hasRelic('hit_to_20') and p.total < 20 and not p.busted then
    -- 自动继续（限手牌未满）
    if #p.hand < GS.HAND_MAX then
      self:pushHand('player', self:drawCard('player'))
      self:refreshPlayer()
      return self:hookPlayerHit()
    end
  end
end

function GS:hookDealerHit() end
function GS:hookStageStart()
  local st = self.state
  if self:hasRelic('debt_collector') then self.specials.debt_borrow(self, self:relicById('debt_collector')) end
end

-- ===================== 遗物使用 =====================

function GS:findRelic(arg)
  if type(arg) == 'number' then return self:activeRelics()[arg] end
  if type(arg) == 'string' then return self:relicById(arg) end
  if type(arg) == 'table' and arg.id then return self:relicById(arg.id) end
  return nil
end

function GS:consumeRelic(id)
  local inst = self:relicById(id)
  if not inst then return false end
  if inst._forged then return true end
  if inst._consumable then
    inst._usesLeft = (inst._usesLeft or 1) - 1
    if inst._usesLeft <= 0 then inst._expired = true end
  else
    inst._usedOnce = true
  end
  self:syncRelicAliases()
  return true
end

function GS:markRelicActive(id)
  local inst = self:relicById(id)
  if inst then inst._active = true end
  return true
end

function GS:activateRelic(inst)
  if not inst then return false, 'invalid_arg' end
  if inst._expired then return false, 'action_unavailable' end
  local d = inst.def or inst
  local fn = self.specials[d.special]
  if fn then
    local ok, err = pcall(fn, self, inst, nil)
    if not ok then return self:fail('relic_error') end
  end
  if inst._consumable then
    inst._usesLeft = (inst._usesLeft or 1) - 1
    if inst._usesLeft <= 0 then inst._expired = true end
  end
  self:syncRelicAliases()
  return true
end

function GS:use_relic(arg)
  local st = self.state
  if st.state ~= 'player' and st.state ~= 'bet' then return self:fail('action_unavailable') end
  local inst = self:findRelic(arg)
  if not inst then return self:fail('invalid_arg') end
  if st.flags.relicUsedThisRound then return self:fail('action_unavailable') end
  st.flags.relicUsedThisRound = true
  return self:activateRelic(inst)
end

function GS:toggle_relic(arg)
  local inst = self:findRelic(arg)
  if not inst then return self:fail('invalid_arg') end
  inst._active = not inst._active
  if inst._active then
    local fn = self.specials[inst.def and inst.def.special]
    if fn then pcall(fn, self, inst, nil) end
  end
  self:syncRelicAliases()
  return true
end

-- ===================== 情报 / 标记 / 钓具 =====================

function GS:revealShoeRange(a, b, tag)
  local st = self.state
  st.shoe.revealSlots = st.shoe.revealSlots or {}
  for i = a, b do
    st.shoe.revealSlots[i] = tag or true
  end
  self:refreshShoe()
end

function GS:refreshShoe()
  local st = self.state
  local deck = st.deck
  if not deck then return end
  local order = {}
  local reveal = st.shoe.revealSlots or {}
  local n = math.min(#deck.drawPile, 30)
  for i = 1, n do
    local card = deck.drawPile[i]
    local revealed = reveal[i] ~= nil or card.revealed == true
    if i <= (st.peekDepth or 0) then revealed = true end
    order[i] = { index = i, card = card, label = card.label or '?', revealed = revealed, marked = Marks.isMarked(card), kind = card.kind }
  end
  st.shoe.order = order
  st.shoe.remaining = #deck.drawPile
  st.shoe.discardCount = #deck.discardPile
  st.shoe.removedCount = #deck.removed
  -- 概率/成分使用完整抽牌堆（展示顺序带可截断到 30 张）
  local full = {}
  for i = 1, #deck.drawPile do full[#full + 1] = deck.drawPile[i] end
  st.shoe.composition = SI.rankComposition(full)
  st.shoe.known = full
  st.shoe.coverageGap = ''
  if st.shoeOpen then
    local ok, odds, info = pcall(SI.bustOdds, st.player.total or 0, full, { hand = st.player.hand })
    if ok and type(odds) == 'number' then
      st.shoe.nextBustOdds = odds; st.shoe.nextBustOddsInfo = info
    else
      st.shoe.nextBustOdds = nil
      st.shoe.nextBustOddsInfo = (type(info) == 'table' and info) or (type(odds) == 'table' and odds) or { reason = 'error', message = tostring(odds) }
    end
    local up = st.dealer.hand and st.dealer.hand[2]
    local holeRevealed = st.dealer.holeRevealed == true
    local pool = {}
    for i = 1, #full do pool[#pool + 1] = full[i] end
    if not holeRevealed and st.dealer.hand[1] then pool[#pool + 1] = st.dealer.hand[1] end
    local dotp = { cards = pool, playerTotal = st.player.total, holeUnknown = not holeRevealed,
                   holeCard = (holeRevealed and st.dealer.hand[1]) or nil }
    local ok2, dbust, dinfo = pcall(SI.dealerBustOdds, { up }, st.dealer.difficulty or 1, dotp)
    if ok2 and type(dbust) == 'number' then
      st.shoe.dealerBustOdds = dbust; st.shoe.dealerBustOddsInfo = dinfo
    else
      st.shoe.dealerBustOdds = nil
      st.shoe.dealerBustOddsInfo = (type(dinfo) == 'table' and dinfo) or (type(dbust) == 'table' and dbust) or { reason = 'error', message = tostring(dbust) }
    end
    local gaps = {}
    local function g(x) if x and x.coverageGap and x.coverageGap ~= '' then gaps[#gaps + 1] = x.coverageGap end end
    g(st.shoe.nextBustOddsInfo); g(st.shoe.dealerBustOddsInfo)
    st.shoe.coverageGap = table.concat(gaps, '; ')
  end
end

function GS:findCardByUid(uid)
  local st = self.state
  for _, list in ipairs({ st.deck.drawPile, st.deck.discardPile, st.deck.removed, st.player.hand, st.dealer.hand }) do
    for i = 1, #list do
      if list[i].uid == uid then return list[i], list, i end
    end
  end
  return nil
end

function GS:findCardInZone(zone, index)
  local st = self.state
  local list
  if zone == 'shoe' then list = st.deck.drawPile
  elseif zone == 'discard' then list = st.deck.discardPile
  elseif zone == 'player' then list = st.player.hand
  elseif zone == 'dealer' then list = st.dealer.hand
  end
  if not list then return nil end
  return list[index]
end

function GS:inkLimit()
  local consort = self:hasRelic('cheat_consort')
  return Marks.limitWith(consort)
end

-- 定位一张牌所在区域与下标
function GS:locateCard(card)
  local st = self.state
  if not card or not st.deck then return nil end
  local zones = {
    { 'shoe', st.deck.drawPile },
    { 'discard', st.deck.discardPile },
    { 'removed', st.deck.removed },
    { 'player', st.player.hand },
    { 'dealer', st.dealer.hand },
  }
  for _, z in ipairs(zones) do
    for i = 1, #z[2] do
      if z[2][i] == card then return z[1], z[2], i end
    end
  end
  return nil
end

-- 虚空标记：标记瞬间吸收它前面那张牌及其全部词条（前面没牌则不消耗次数）
function GS:applyVoidMark(card, held)
  local st = self.state
  local zone, list, idx = self:locateCard(card)
  if not list or idx <= 1 then
    self:msg('虚空标记：这张牌前面没有牌，未消耗次数。', 'warning')
    return false
  end
  local prev = table.remove(list, idx - 1)
  st.deck:toDiscard(prev)
  local traits = { 'is_multiplier','mult_bonus','is_rps','rps_symbol','is_67','s67_rank',
                   'is_cage','is_chip','chip_value','is_dice','dice_sides','is_remove','is_champion' }
  for _, k in ipairs(traits) do
    if prev[k] ~= nil then card[k] = prev[k] end
  end
  card.absorbed_from = prev.uid
  Marks.newSpecial(card, held.id)
  st.flags.specialMarkUsedThisRound = true
  Marks.consumeSpecial(st)
  self:emit({ kind = 'mark_fx', markId = 'mark_void', anchor = zone, card = card })
  self:emit({ kind = 'card_discard', card = prev, from = zone })
  self:refreshPlayer()
  self:refreshDealer()
  self:refreshShoe()
  self:msg('虚空标记：吸收前一张牌的词条。', 'success')
  return true
end

function GS:markCard(card, explicitUnmark)
  local st = self.state
  if not card then return self:fail('invalid_arg') end
  if st.mode == 'bar' then return self:fail('action_unavailable') end
  if Marks.isMarked(card) then
    Marks.remove(card)
    self:refreshShoe()
    return true
  end
  if explicitUnmark then return true end
  -- 特种标记优先
  local held = st.specialMarks and st.specialMarks.held
  if held and not st.flags.specialMarkUsedThisRound then
    if held.id == 'mark_void' then
      return self:applyVoidMark(card, held)
    end
    Marks.newSpecial(card, held.id)
    st.flags.specialMarkUsedThisRound = true
    Marks.consumeSpecial(st)
    self:refreshShoe()
    self:msg('特种标记已放置。', 'success')
    return true
  end
  local count = Marks.countInk(st)
  if count >= self:inkLimit() then return self:fail('mark_limit') end
  local price = Marks.inkPrice(st.stage, self:hasRelic('ink_thief'))
  if st.chips < price then return self:fail('not_enough_chips') end
  st.chips = st.chips - price
  Marks.newInk(card, { by = 'player', price = price, stage = st.stage, reveal = self:hasRelic('reveal_ink') })
  self:refreshShoe()
  return true
end

function GS:mark_card(arg)
  arg = arg or {}
  if arg.uid then return self:markCard(self:findCardByUid(arg.uid)) end
  return self:markCard(self:findCardInZone(arg.zone or 'shoe', arg.index or 1))
end

function GS:unmark_card(arg)
  arg = arg or {}
  local card = arg.uid and self:findCardByUid(arg.uid) or self:findCardInZone(arg.zone or 'shoe', arg.index or 1)
  if card and Marks.isMarked(card) then Marks.remove(card); self:refreshShoe() end
  return true
end

-- 钓具：把标记牌移到想要的深度
function GS:rod_pick(arg)
  local st = self.state
  local uid = arg and arg.uid
  if not uid then return self:fail('invalid_arg') end
  st.rodSelection = uid
  if st.rodMode == 'swap' then
    if st.rodFirst then
      self:rodSwap(st.rodFirst, uid)
      st.rodFirst = nil; st.rodSelection = nil
    else
      st.rodFirst = uid
    end
    return true
  end
  return true
end

function GS:rod_confirm()
  local st = self.state
  if not st.rodSelection then return self:fail('invalid_arg') end
  if st.rodMode == 'swap' then
    if not st.rodFirst then return self:fail('invalid_arg') end
    self:rodSwap(st.rodFirst, st.rodSelection)
    st.rodFirst = nil
  else
    self:rodApply(st.rodMode, st.rodSelection)
  end
  st.rodSelection = nil
  self:refreshShoe()
  return true
end

function GS:rodSwap(uid1, uid2)
  local st = self.state
  local c1, l1, i1 = self:findCardByUid(uid1)
  local c2, l2, i2 = self:findCardByUid(uid2)
  if c1 and c2 and l1 and l2 then l1[i1], l2[i2] = l2[i2], l1[i1] end
end

function GS:rodApply(mode, uid)
  local st = self.state
  local card, list, idx = self:findCardByUid(uid)
  if not card or list ~= st.deck.drawPile then return end
  table.remove(list, idx)
  if mode == 'deep' then
    table.insert(list, 1, card)
  elseif mode == 'trawl' then
    local pos = math.max(1, idx - 3)
    table.insert(list, pos, card)
  elseif mode == 'rogue' then
    table.insert(list, self:rint(1, #list + 1), card)
  elseif mode == 'lost' then
    table.insert(st.deck.discardPile, card)
  elseif mode == 'golden' then
    table.insert(list, 1, card)
  elseif mode == 'standard' then
    table.insert(list, 1, card)
  else
    table.insert(list, 1, card)
  end
end

-- ===================== 商店 =====================

local DECK_KEYS = { 'decimal', 'negative', 'multiplier', 's67', 'rps', 'remove', 'blackhole', 'cage', 'chip', 'dice6', 'dice20', 'champion' }
local DECK_SIZES = { 'small', 'medium', 'large' }

-- GDD §16.2：开局三选一排除商店专属六个组（特种标记 / 钓具 / 揭示 / 弃牌堆 / 职阶残卷 / 显影墨水）。
-- 揭示组与显影墨水共用 group='info'，因此按 id 前缀 reveal_ 判定，其余按组判定。
local SHOP_ONLY_GROUPS = { mark = true, rod = true, discard = true, shard = true }
function GS:isShopOnlyRelic(d)
  if not d then return false end
  if d.shopOnly == true then return true end
  if SHOP_ONLY_GROUPS[d.group] then return true end
  if type(d.id) == 'string' and d.id:sub(1, 7) == 'reveal_' then return true end
  return false
end

-- 「删除牌组」会移除固有 52 张里的若干张；两助手用于底线保护。
-- 固有牌堆 = 阶段标准套数 × 52；已删数 = 已购删除牌组的累计移除量。
function GS:inherentDeckTotal()
  local cfg = self:stageCfg(self.state.stage)
  return (cfg.decks or 1) * 52
end

function GS:removedBasicCount()
  local st = self.state
  local n = 0
  for i = 1, #st.removedDeckIds do
    local it = st.removedDeckIds[i]
    n = n + DT.removedDecks(it.key, it.size)
  end
  return n
end

function GS:rollShopSlot(kind, discount)
  local st = self.state
  if kind == 'relic' then
    local rarity = self:rweighted(GS.RARITY_WEIGHTS)
    local pool = {}
    for i = 1, #Relics.LIST do
      local d = Relics.LIST[i]
      if d.rarity == rarity and not Relics.isPoolExcluded(d) and not self:hasRelic(d.id) then
        pool[#pool + 1] = d
      end
    end
    if #pool == 0 then return nil end
    local d = pool[self:rint(1, #pool)]
    local price = Relics.price(d, st.stage)
    if discount then price = math.floor(price * discount) end
    return { kind = 'relic', def = d, id = d.id, name = d.name, desc = d.desc, rarity = d.rarity, price = price, sold = false }
  else
    local cfg = self:stageCfg(st.stage)
    local remaining = self:inherentDeckTotal() - self:removedBasicCount()
    local keys = {}
    for i = 1, #DECK_KEYS do
      local k = DECK_KEYS[i]
      local allowed = true
      if k == 'remove' then
        -- GDD §16.2：固有套数 ≤1 时剔除删除牌组；已删到只剩 1 张时也不再提供。
        if (cfg.decks or 1) <= 1 or remaining <= 1 then allowed = false end
      end
      if allowed then keys[#keys + 1] = k end
    end
    if #keys == 0 then keys[1] = 'decimal' end
    local key = self:rpick(keys)
    local size = self:rpick(DECK_SIZES)
    if key == 'champion' then size = 'small' end
    if key == 'dice6' or key == 'dice20' then size = 'x' end
    local price = DT.price(key, size, st.stage)
    if discount then price = math.floor(price * discount) end
    local info = DT.info(key)
    return { kind = 'deck', key = key, size = size, name = info and info.name or key, desc = info and info.desc or '', price = price, sold = false }
  end
end

function GS:openShop()
  local st = self.state
  local allDecks = self:rchance(0.02)
  local discountIndex, discountFactor = 0, nil
  if self:rchance(0.5) then
    discountIndex = self:rint(1, 5)
    discountFactor = 0.2 + self:rfloat() * 0.7
  end
  if self:hasRelic('deck_weight_low') then allDecks = false end
  local shelves = {}
  for i = 1, 5 do
    local kind = (allDecks or i == 5) and 'deck' or 'relic'
    local disc = (i == discountIndex) and discountFactor or nil
    shelves[i] = self:rollShopSlot(kind, disc)
  end
  local forgeOffer = nil
  if st.stage >= 2 and self:rchance(0.2) then forgeOffer = self:forgeCandidates() end
  st.shop = {
    shelves = shelves, rerollCost = GS.REROLL_BASE, rerolls = 0,
    discountIndex = discountIndex, discountFactor = discountFactor,
    forgeOffer = forgeOffer, forgeUsed = false, forgeOpen = false, forgeSel = nil,
    allDecks = allDecks,
  }
  self:setState('shop')
  self:msg('进入商店。', 'info')
  return true
end

function GS:forgeCandidates()
  local out = {}
  for i = 1, #self:activeRelics() do
    local r = self:activeRelics()[i]
    if r._consumable and not r._forged then out[#out + 1] = { kind = 'relic', id = r.id, name = r.name, index = i } end
  end
  local held = self.state.specialMarks and self.state.specialMarks.held
  if held and not held.forged then out[#out + 1] = { kind = 'mark', id = held.id, name = held.name } end
  return out
end

function GS:shopRerollCost()
  local st = self.state
  if not st.shop then return GS.REROLL_BASE end
  return st.shop.rerollCost
end

function GS:buy_relic(slot)
  local st = self.state
  if st.state ~= 'shop' or not st.shop then return self:fail('action_unavailable') end
  local s = st.shop.shelves[slot or 0]
  if not s or s.sold or s.kind ~= 'relic' then return self:fail('invalid_arg') end
  if st.chips < s.price then return self:fail('not_enough_chips') end
  -- GDD §16.5 / §12.2：带 markDot 的特种标记商品不占遗物栏，直接进专属单格库存；
  -- 同时只能持有一枚，重复购买直接替换旧持有的。
  if s.def and (s.def.markDot == true or s.def.group == 'mark') then
    st.chips = st.chips - s.price
    Marks.gainSpecial(st, s.def.id)
    s.sold = true
    self:msg('获得特种标记：' .. s.name, 'success')
    return true
  end
  if #self:activeRelics() >= st.relicSlotMax then return self:fail('relic_slots_full') end
  st.chips = st.chips - s.price
  self:addRelic(s.def)
  s.sold = true
  self:msg('购入遗物：' .. s.name, 'success')
  return true
end

function GS:buy_deck(slot)
  local st = self.state
  if st.state ~= 'shop' or not st.shop then return self:fail('action_unavailable') end
  local s = st.shop.shelves[slot or 0]
  if not s or s.sold or s.kind ~= 'deck' then return self:fail('invalid_arg') end
  if st.chips < s.price then return self:fail('not_enough_chips') end
  if s.key == 'remove' then
    -- GDD §16.5：删除牌组在固有牌堆将归零时被拒绝（含已购删除牌组叠加）。
    local amount = DT.removedDecks(s.key, s.size)
    local remaining = self:inherentDeckTotal() - self:removedBasicCount()
    if remaining - amount <= 0 then
      self:msg('固有牌组已空，不能再删！', 'warn')
      return self:fail('empty_deck')
    end
    st.removedDeckIds[#st.removedDeckIds + 1] = { key = s.key, size = s.size }
  else
    st.deckItems[#st.deckItems + 1] = { key = s.key, size = s.size }
    if s.key == 'champion' and #st.championCards < 36 then
      st.championCards = Champion.randomPick(self.rng)
    end
  end
  st.chips = st.chips - s.price
  s.sold = true
  self:buildShoe()
  self:msg('购入牌组：' .. s.name, 'success')
  return true
end

function GS:reroll()
  local st = self.state
  if st.state ~= 'shop' or not st.shop then return self:fail('action_unavailable') end
  local cost = st.shop.rerollCost
  if st.chips < cost then return self:fail('not_enough_chips') end
  st.chips = st.chips - cost
  st.shop.rerollCost = cost * 2
  st.shop.rerolls = st.shop.rerolls + 1
  for i = 1, 5 do
    local old = st.shop.shelves[i]
    if old and not old.sold then
      local disc = (i == st.shop.discountIndex) and st.shop.discountFactor or nil
      st.shop.shelves[i] = self:rollShopSlot(old.kind, disc)
    end
  end
  return true
end

function GS:open_forge()
  local st = self.state
  if st.state ~= 'shop' or not st.shop then return self:fail('action_unavailable') end
  if not st.shop.forgeOffer or st.shop.forgeUsed then return self:fail('action_unavailable') end
  st.shop.forgeOpen = true
  return true
end

function GS:cancel_forge()
  if self.state.shop then self.state.shop.forgeOpen = false end
  return true
end

function GS:forge_select(arg)
  arg = arg or {}
  if self.state.shop then self.state.shop.forgeSel = arg end
  return true
end

function GS:confirm_forge()
  local st = self.state
  if not st.shop or not st.shop.forgeOpen or st.shop.forgeUsed then return self:fail('action_unavailable') end
  if st.chips < GS.FORGE_PRICE then return self:fail('not_enough_chips') end
  local sel = st.shop.forgeSel
  if not sel or not sel.kind then return self:fail('invalid_arg') end
  st.chips = st.chips - GS.FORGE_PRICE
  if sel.kind == 'mark' then
    local held = st.specialMarks and st.specialMarks.held
    if held then held.forged = true; held.usesLeft = nil end
  else
    local inst = self:findRelic(sel.id or sel.index)
    if inst then
      inst._forged = true
      inst._consumable = false
      inst._usesLeft = nil
      inst._expired = false
    end
  end
  st.shop.forgeUsed = true
  st.shop.forgeOpen = false
  self:syncRelicAliases()
  self:emit({ kind = 'sfx', name = 'forge' })
  self:msg('铸造完成。', 'success')
  return true
end

function GS:leave_shop()
  local st = self.state
  if st.state ~= 'shop' then return self:fail('action_unavailable') end
  st.shop = nil
  self:beginBet()
  return true
end

-- ===================== 职阶 =====================

function GS:rollClassCandidates()
  local out = {}
  local seen = {}
  local guard = 0
  while #out < 3 and guard < 50 do
    guard = guard + 1
    local id = self:rpick(Classes.ORDER)
    if id and not seen[id] then
      seen[id] = true
      local d = Classes.get(id)
      out[#out + 1] = { id = id, name = d and d.name or id, desc = d and d.desc or '', kind = 'class' }
    end
  end
  return out
end

function GS:rollShardOffer()
  local pool = {}
  for i = 1, #Classes.ORDER do
    local id = Classes.ORDER[i]
    local shardId = 'class_' .. id .. '_shard'
    local d = Relics.byId(shardId)
    if d and not self:hasRelic(shardId) then
      pool[#pool + 1] = { kind = 'relic', id = shardId, name = d.name, desc = d.desc, def = d, rarity = d.rarity }
    end
  end
  local caster = Relics.byId('caster_relic')
  if caster then pool[#pool + 1] = { kind = 'relic', id = caster.id, name = caster.name, desc = caster.desc, def = caster, rarity = caster.rarity } end
  local out = {}
  while #out < 3 and #pool > 0 do
    out[#out + 1] = table.remove(pool, self:rint(1, #pool))
  end
  return out
end

function GS:choose_class(id)
  local st = self.state
  if st.state ~= 'classSelect' then return self:fail('action_unavailable') end
  local d = Classes.get(id)
  if not d then return self:fail('invalid_arg') end
  st.playerClass = Classes.getRuntime(id)
  st.class = st.playerClass
  st.classOffer = { mode = 'classOffer', candidates = self:rollShardOffer() }
  self:setState('classOffer')
  return true
end

function GS:finishClassFlow()
  local st = self.state
  st.classOffer = nil
  self:applyStage(3)
  self:hookStageStart()
  if st.mode == 'hard' then st.dealerClass = Classes.dealerRuntime(self:rpick(Classes.ORDER)) end
  self:buildShoe()
  self:beginBet()
  self:msg('进入 ' .. st.stageName, 'info')
end

function GS:take_class_offer(index)
  local st = self.state
  if st.state ~= 'classOffer' or not st.classOffer then return self:fail('action_unavailable') end
  local cand = st.classOffer.candidates[index or 0]
  if not cand then return self:fail('invalid_arg') end
  if cand.def then self:addRelic(cand.def) end
  self:finishClassFlow()
  return true
end

function GS:skip_class_offer()
  local st = self.state
  if st.state ~= 'classOffer' then return self:fail('action_unavailable') end
  self:finishClassFlow()
  return true
end

-- ===================== 酒吧模式 =====================

function GS:barStart()
  local st = self.state
  st.mode = 'bar'
  st.stage = 1
  st.chips = 0
  st.bar = Bar.newState()
  local deck = Deck.new({ rng = self.rng })
  deck:addCards(Bar.buildDeck(), 'bar')
  deck:shuffle()
  st.deck = deck
  st.barDeck = deck
  self:setState('bar_brief')
  self:msg('酒吧周目：100 局，攒满 6 杯。', 'info')
  return true
end

function GS:bar_begin()
  if self.state.state ~= 'bar_brief' then return self:fail('action_unavailable') end
  local b = self.state.bar
  b.round = 0
  self:barBeginRound()
  return true
end

function GS:barBeginRound()
  local st = self.state
  local b = st.bar
  if not b then return self:fail('action_unavailable') end
  if b.finished then return self:barEnding() end
  if b.round >= Bar.ROUNDS then b.finished = true; return self:barEnding() end
  b.round = b.round + 1
  b.usedAbilityThisRound = false
  b.abilitiesUsed = {}
  if not Bar.cupsFull(b) then
    local forced = Bar.isPityRound(b.round)
    local byChance = self:rchance(Bar.giftChance(b))
    if forced or byChance then
      local cand = Bar.giftCandidates(b, 3)
      if #cand > 0 then
        b.pendingGift = cand
        b.pendingPity = forced
        self:setState('bar_gift')
        return true
      end
    end
  end
  return self:barDeal()
end

function GS:bar_gift_pick(index)
  local st = self.state
  local b = st.bar
  if st.state ~= 'bar_gift' or not b.pendingGift then return self:fail('action_unavailable') end
  local c = b.pendingGift[index or 0]
  if not c then return self:fail('invalid_arg') end
  Bar.addCup(b, c.def)
  b.pendingGift = nil
  b.pendingPity = false
  self:msg('获得新酒：' .. c.name, 'success')
  return self:barDeal()
end

function GS:barDeal()
  local st = self.state
  if st.barDeck then self:recycleHands(st.barDeck) end
  st.player = newPlayer()
  st.dealer = newDealer()
  st.dealer.difficulty = 2
  st.bet = 0
  st.bustBet = { on = false, amount = 0, odds = nil, hit = false, locked = true }
  st.player.hand = {}
  st.dealer.hand = {}
  local deck = st.barDeck
  if #deck.drawPile < 4 then
    deck:addCards(Bar.buildDeck(), 'bar')
    deck:shuffle()
  end
  self:pushHand('player', self:drawCard('player'))
  self:pushHand('player', self:drawCard('player'))
  self:pushHand('dealer', self:drawCard('dealer'))
  self:pushHand('dealer', self:drawCard('dealer'))
  st.dealer.holeRevealed = false
  self:refreshPlayer(); self:refreshDealer()
  self:refreshShoe()
  self:setState('player')
  self:msg('酒吧第 ' .. st.bar.round .. ' 局', 'info')
  return true
end

function GS:barFindCupIndex(cupOrId)
  local st = self.state
  if type(cupOrId) == 'number' then
    if st.bar.cups[cupOrId] then return cupOrId end
    return nil
  end
  for i = 1, #st.bar.cups do
    if st.bar.cups[i].drink == cupOrId then return i end
  end
  return nil
end

function GS:bar_drink(cup)
  local st = self.state
  if not st.bar then return self:fail('action_unavailable') end
  local i = self:barFindCupIndex(cup)
  if not i then return self:fail('invalid_arg') end
  local c = Bar.drink(st.bar, i)
  if not c then return self:fail('action_unavailable') end
  self:emit({ kind = 'sfx', name = 'chip' })
  return true
end

function GS:barAfterRound()
  local st = self.state
  local b = st.bar
  local outcome = st.result and st.result.outcome
  if outcome == 'player' then
    b.wins = b.wins + 1
    b.giftChance = math.min(1, b.giftChance + Bar.GIFT_STEP)
  elseif outcome == 'dealer' then
    b.losses = b.losses + 1
    b.giftChance = Bar.GIFT_BASE
    local cups = Bar.activeCups(b)
    if #cups == 0 then
      b.finished = true
      b.ending = 'fail'
      return 'bar_ending'
    end
    local pick = cups[self:rint(1, #cups)]
    Bar.drink(b, self:barFindCupIndex(pick.drink))
    self:msg('输了，罚喝一口：' .. pick.name, 'warning')
  end
  local expired = Bar.tickBuffs(b)
  if #expired > 0 then
    b.hangover = Bar.hangoverColor(expired)
    b.hangoverNames = {}
    for i = 1, #expired do b.hangoverNames[#b.hangoverNames + 1] = expired[i].name end
  end
  if b.round >= Bar.ROUNDS then
    b.finished = true
    return 'bar_ending'
  end
  return 'bar_next'
end

function GS:barEnding()
  local st = self.state
  local b = st.bar
  if not b then return self:fail('action_unavailable') end
  b.finished = true
  local ending, total = Bar.classify(b)
  b.ending = ending
  b.endingTotal = total
  self:setState('bar_ending')
  local texts = { date = '约会成功', fish = '养鱼成功', buddies = '好酒友', fail = '宿醉倒下' }
  self:msg('酒吧结局：' .. (texts[ending] or ending), ending == 'fail' and 'warning' or 'success')
  return true
end

function GS:bar_ability(arg)
  local st = self.state
  if not st.bar then return self:fail('action_unavailable') end
  if st.state ~= 'player' then return self:fail('action_unavailable') end
  if st.bar.usedAbilityThisRound then return self:fail('action_unavailable') end
  arg = arg or {}
  local id = arg.id or arg.drink
  local idx = self:barFindCupIndex(id)
  if not idx then return self:fail('invalid_arg') end
  local cup = st.bar.cups[idx]
  if (cup.buffLeft or 0) <= 0 then return self:fail('action_unavailable') end
  local special = cup.ability and cup.ability.special
  if not special then return self:fail('action_unavailable') end
  st.bar.usedAbilityThisRound = true
  st.bar.abilitiesUsed[cup.drink] = true
  local ok = pcall(self.barApplyAbility, self, special, arg)
  if not ok then return self:fail('relic_error') end
  return true
end

function GS:barApplyAbility(special, arg)
  local st = self.state
  local p, d = st.player, st.dealer
  local function addHand(rank, suit)
    local card = DT.mk({ rank = tostring(rank), suit = suit or 'S', kind = 'basic', is_synthetic = true })
    st.deck:assignUid(card)
    if #p.hand < GS.HAND_MAX then p.hand[#p.hand + 1] = card; self:emit({ kind = 'deal', target = 'player', card = card, index = #p.hand }) end
  end
  local function dealerDraw(n)
    for i = 1, (n or 1) do
      local c = self:drawCard('dealer')
      if c then self:pushHand('dealer', c) end
    end
  end
  if special == 'redraw_hand' then
    for i = 1, #p.hand do st.deck:toDiscard(p.hand[i]) end
    p.hand = {}
    self:pushHand('player', self:drawCard('player'))
    self:pushHand('player', self:drawCard('player'))
  elseif special == 'swap_hand_card' then
    local i = tonumber(arg.target) or 1
    if p.hand[i] then st.deck:toDiscard(p.hand[i]); p.hand[i] = self:drawCard('player') end
  elseif special == 'peek_sink_pick' then
    self:revealShoeRange(1, 3, 'bar')
  elseif special == 'burn_half' then
    local n = math.floor(#p.hand / 2)
    for i = 1, n do local card = table.remove(p.hand); if card then st.deck:toDiscard(card) end end
  elseif special == 'duplicate_lowest' then
    local lo, li = nil, nil
    for i = 1, #p.hand do local v = BJ.cardValue(p.hand[i]); if not lo or v < lo then lo, li = v, i end end
    if li then local cp = DT.clone(p.hand[li]); cp.is_synthetic = true; cp._synthCounted = nil; st.deck:assignUid(cp); table.insert(p.hand, cp) end
  elseif special == 'dealer_stop' then
    d.forcedStand = true
  elseif special == 'discard_highest' then
    local hi, li = nil, nil
    for i = 1, #p.hand do local v = BJ.cardValue(p.hand[i]); if not hi or v > hi then hi, li = v, i end end
    if li then st.deck:toDiscard(table.remove(p.hand, li)) end
  elseif special == 'swap_with_dealer' then
    local i = tonumber(arg.target) or 1
    if p.hand[i] and d.hand[2] then p.hand[i], d.hand[2] = d.hand[2], p.hand[i] end
  elseif special == 'discard_random' then
    if #p.hand > 0 then st.deck:toDiscard(table.remove(p.hand, self:rint(1, #p.hand))) end
  elseif special == 'pick_from_champion' then
    local pool = st.championCards
    if not pool or #pool == 0 then pool = Champion.randomPick(self.rng); st.championCards = pool end
    if pool and #pool > 0 then local card = DT.clone(pool[self:rint(1, #pool)]); card.is_synthetic = true; card._synthCounted = nil; st.deck:assignUid(card); if #p.hand < GS.HAND_MAX then p.hand[#p.hand + 1] = card end end
  elseif special == 'take_dealer_highest_sink' then
    local hi, li = nil, nil
    for i = 1, #d.hand do local v = BJ.cardValue(d.hand[i]); if not hi or v > hi then hi, li = v, i end end
    if li then local card = table.remove(d.hand, li); table.insert(st.deck.drawPile, 1, card) end
  elseif special == 'give_lowest_to_dealer' then
    local lo, li = nil, nil
    for i = 1, #p.hand do local v = BJ.cardValue(p.hand[i]); if not lo or v < lo then lo, li = v, i end end
    if li then local card = table.remove(p.hand, li); d.hand[#d.hand + 1] = card end
  elseif special == 'dealer_last_sink_draw' then
    if #d.hand > 0 then local card = table.remove(d.hand); table.insert(st.deck.drawPile, 1, card) end
  elseif special == 'dealer_extra_up' then
    dealerDraw(1)
  elseif special == 'dealer_lowest_sink_draw' then
    local lo, li = nil, nil
    for i = 1, #d.hand do local v = BJ.cardValue(d.hand[i]); if not lo or v < lo then lo, li = v, i end end
    if li then local card = table.remove(d.hand, li); table.insert(st.deck.drawPile, 1, card) end
  elseif special == 'dealer_fill_to_2' then
    while #d.hand < 2 do dealerDraw(1) end
  elseif special == 'dealer_fill_to_3' then
    while #d.hand < 3 do dealerDraw(1) end
  elseif special == 'dealer_draw_1' then dealerDraw(1)
  elseif special == 'dealer_draw_2' then dealerDraw(2)
  elseif special == 'dealer_draw_3' then dealerDraw(3)
  elseif special == 'dealer_copy_last' then
    if #d.hand > 0 then local cp = DT.clone(d.hand[#d.hand]); cp.is_synthetic = true; cp._synthCounted = nil; st.deck:assignUid(cp); d.hand[#d.hand + 1] = cp end
  elseif special == 'dealer_draw_2_stop' then
    dealerDraw(2); d.forcedStand = true
  elseif special == 'deck_sort_asc' then
    table.sort(st.deck.drawPile, function(a, b) return BJ.cardValue(a) < BJ.cardValue(b) end)
  elseif special == 'sink_top_5' then
    for i = 1, 5 do local card = st.deck:draw(); if card then table.insert(st.deck.drawPile, #st.deck.drawPile + 1, card) end end
  elseif special == 'deck_rebuild_shuffle' then
    st.deck:shuffle()
  elseif special == 'dealer_draw_1_give_random' then
    dealerDraw(1)
    if #d.hand > 0 then local card = table.remove(d.hand, self:rint(1, #d.hand)); p.hand[#p.hand + 1] = card end
  elseif special == 'swap_dealer_lowest_with_draw' then
    local lo, li = nil, nil
    for i = 1, #d.hand do local v = BJ.cardValue(d.hand[i]); if not lo or v < lo then lo, li = v, i end end
    if li then d.hand[li] = self:drawCard('dealer') end
  elseif special == 'deck_remove_random_10' then
    for i = 1, 10 do
      local idx = self:rint(1, math.max(1, #st.deck.drawPile))
      local card = table.remove(st.deck.drawPile, idx)
      if card then st.deck:toRemoved(card) end
    end
  elseif special == 'dealer_draw_highest' then
    if #d.hand > 0 then d.hand[1] = self:drawCard('dealer') end
  elseif special == 'dealer_draw_until_21' then
    while BJ.handTotal(d.hand) < 21 and #d.hand < GS.HAND_MAX do dealerDraw(1) end
  elseif special == 'deck_insert_5_tens' then
    for i = 1, 5 do
      local card = DT.mk({ rank = '10', suit = 'S', kind = 'basic', is_synthetic = true })
      st.deck:assignUid(card)
      table.insert(st.deck.drawPile, self:rint(1, #st.deck.drawPile + 1), card)
    end
  elseif special == 'dealer_fill_to_player_count' then
    while #d.hand < #p.hand do dealerDraw(1) end
  elseif special == 'dealer_duplicate_ups' then
    local ups = {}
    for i = 2, #d.hand do ups[#ups + 1] = d.hand[i] end
    for i = 1, #ups do local cp = DT.clone(ups[i]); cp.is_synthetic = true; cp._synthCounted = nil; st.deck:assignUid(cp); d.hand[#d.hand + 1] = cp end
  elseif special == 'deck_compress_top_half' then
    local n = math.floor(#st.deck.drawPile / 2)
    for i = 1, n do local card = table.remove(st.deck.drawPile, 1); if card then table.insert(st.deck.drawPile, #st.deck.drawPile + 1, card) end end
  end
  addHand()
  self:refreshPlayer(); self:refreshDealer(); self:refreshShoe()
end

-- ===================== 教程 =====================

function GS:start_tutorial()
  local st = self.state
  self:resetState()
  st.mode = 'normal'
  st.tutorial = Tutorial.new()
  st.stage = 1
  st.chips = Tutorial.START_CHIPS
  self:applyStage(1)
  st.chips = Tutorial.START_CHIPS
  st.state = 'bet'
  self:beginBet()
  self:msg('教程开始。', 'info')
  return true
end

function GS:tutorial_advance()
  local st = self.state
  if not st.tutorial then return true end
  local ok, res, hint = st.tutorial:advance(st.lastAction or 'manual')
  st.lastAction = nil
  if ok == false and res == 'require_action' then
    return false, 'tutorial_action_required'
  end
  if st.tutorial:isDone() then st.tutorial = nil end
  return true
end

function GS:tutorialNotify(name)
  if self.state.tutorial then
    self.state.lastAction = name
    self.state.tutorial:notify(name)
    if self.state.tutorial:isDone() then self.state.tutorial = nil end
  end
end

-- ===================== 冠军牌组编辑器 =====================

function GS:open_deck_editor()
  local st = self.state
  st.deckEditor = {
    chips = st.championCards or {},
    saved = self.persist:readCollection(),
    filter = 'all', selected = {},
  }
  if #st.deckEditor.chips == 0 then
    st.deckEditor.chips = Champion.randomPick(self.rng)
  end
  self:setState('deckEditor')
  return true
end

function GS:close_deck_editor()
  self.state.deckEditor = nil
  self:setState('title')
  return true
end

function GS:champion_toggle(index)
  local ed = self.state.deckEditor
  if not ed then return self:fail('action_unavailable') end
  local card = ed.chips[index or 0]
  if not card then return self:fail('invalid_arg') end
  ed.selected[index] = not ed.selected[index]
  return true
end

function GS:champion_clear()
  if self.state.deckEditor then self.state.deckEditor.selected = {} end
  return true
end

function GS:champion_filter(key)
  if self.state.deckEditor then self.state.deckEditor.filter = key or 'all' end
  return true
end

function GS:champion_save()
  local ed = self.state.deckEditor
  if not ed then return self:fail('action_unavailable') end
  local chosen = {}
  for i = 1, #ed.chips do if ed.selected[i] then chosen[#chosen + 1] = ed.chips[i] end end
  if #chosen ~= Champion.SIZE then return self:fail('champion_need_36') end
  self.state.championCards = chosen
  self.persist:writeCollection({ version = 1, cards = chosen, size = 'small', savedAt = os.time and os.time() or 0 })
  self:msg('冠军牌组已保存。', 'success')
  return true
end

-- ===================== 动作分发 =====================

GS.ALIASES = {
  hitPlayer = 'hit', standPlayer = 'stand', doubleDown = 'double', surrenderPlayer = 'surrender',
  accuseDealer = 'accuse', skipRound = 'skip_round', toggleRelicActive = 'toggle_relic',
  useRelicPassive = 'use_relic', buyRelic = 'buy_relic', buyDeck = 'buy_deck',
  rerollShop = 'reroll', leaveShop = 'leave_shop', openShop = 'open_shop_early',
  markCardAt = 'mark_card', markHandCard = 'mark_card', markDiscardAt = 'mark_card',
  chooseClass = 'choose_class', takeClassOffer = 'take_class_offer',
  barDrink = 'bar_drink', barUseAbility = 'bar_ability',
  openDeckEditor = 'open_deck_editor', championToggle = 'champion_toggle',
  openShoeInfo = 'open_shoe', openDeckOverview = 'open_deck',
  placeBet = 'bet_confirm',
}

function GS:action(name, arg)
  if type(name) ~= 'string' then return self:fail('invalid_arg') end
  name = GS.ALIASES[name] or name
  self.state.lastActionName = name
  local st = self.state
  local ok, res
  if name == 'close_top' then return self:closeTop()
  elseif name == 'continue' then return self:continue()
  elseif name == 'set_setting' then return self:setSetting(arg)
  elseif name == 'toggle_setting' then return self:toggleSetting(arg)
  elseif name == 'reset_progress' then return self:resetProgress()
  elseif name == 'dismiss' then st.dismissed = true; return true
  elseif name == 'select_mode' then return self:start(arg, st.seed)
  elseif name == 'pick_relic' then ok, res = self:pick_relic(arg)
  elseif name == 'start_tutorial' then ok, res = self:start_tutorial()
  elseif name == 'tutorial_advance' then return self:tutorial_advance()
  elseif name == 'choose_class' then ok, res = self:choose_class(arg)
  elseif name == 'take_class_offer' then ok, res = self:take_class_offer(arg)
  elseif name == 'skip_class_offer' then ok, res = self:skip_class_offer()
  elseif name == 'bet_preset' then ok, res = self:bet_preset(arg)
  elseif name == 'bet_set' then ok, res = self:bet_set(arg)
  elseif name == 'bet_adjust' then ok, res = self:bet_adjust(arg)
  elseif name == 'bet_confirm' then ok, res = self:bet_confirm()
  elseif name == 'toggle_bust_bet' then ok, res = self:toggle_bust_bet()
  elseif name == 'skip_round' then ok, res = self:skip_round()
  elseif name == 'toggle_relic' then ok, res = self:toggle_relic(arg)
  elseif name == 'use_relic' then ok, res = self:use_relic(arg)
  elseif name == 'open_shop_early' then return self:openShopEarly()
  elseif name == 'hit' then ok, res = self:playerHit()
  elseif name == 'stand' then ok, res = self:playerStand()
  elseif name == 'double' then ok, res = self:playerDouble()
  elseif name == 'surrender' then ok, res = self:playerSurrender()
  elseif name == 'accuse' then ok, res = self:accuse()
  elseif name == 'mark_card' then ok, res = self:mark_card(arg)
  elseif name == 'unmark_card' then ok, res = self:unmark_card(arg)
  elseif name == 'rod_pick' then ok, res = self:rod_pick(arg)
  elseif name == 'rod_confirm' then ok, res = self:rod_confirm()
  elseif name == 'open_shoe' then st.shoeOpen = true; self:refreshShoe(); return true
  elseif name == 'close_shoe' then st.shoeOpen = false; return true
  elseif name == 'shoe_scroll' then st.shoeScroll = (st.shoeScroll or 0) + (tonumber(arg) or 0); return true
  elseif name == 'shoe_tab' then st.shoeTab = arg; return true
  elseif name == 'open_deck' then st.deckOpen = true; return true
  elseif name == 'close_deck' then st.deckOpen = false; return true
  elseif name == 'deck_scroll' then st.deckScroll = (st.deckScroll or 0) + (tonumber(arg) or 0); return true
  elseif name == 'buy_relic' then ok, res = self:buy_relic(arg)
  elseif name == 'buy_deck' then ok, res = self:buy_deck(arg)
  elseif name == 'reroll' then ok, res = self:reroll()
  elseif name == 'open_forge' then ok, res = self:open_forge()
  elseif name == 'forge_select' then ok, res = self:forge_select(arg)
  elseif name == 'confirm_forge' then ok, res = self:confirm_forge()
  elseif name == 'cancel_forge' then ok, res = self:cancel_forge()
  elseif name == 'leave_shop' then ok, res = self:leave_shop()
  elseif name == 'bar_begin' then ok, res = self:bar_begin()
  elseif name == 'bar_gift_pick' then ok, res = self:bar_gift_pick(arg)
  elseif name == 'bar_drink' then ok, res = self:bar_drink(arg)
  elseif name == 'bar_ability' then ok, res = self:bar_ability(arg)
  elseif name == 'bar_pick' then
    if self.bar_pick then ok, res = self:bar_pick(arg) else st.barPick = arg; return true end
  elseif name == 'bar_confirm' then
    if self.bar_confirm then ok, res = self:bar_confirm() else return true end
  elseif name == 'open_deck_editor' then ok, res = self:open_deck_editor()
  elseif name == 'close_deck_editor' then ok, res = self:close_deck_editor()
  elseif name == 'champion_toggle' then ok, res = self:champion_toggle(arg)
  elseif name == 'champion_clear' then ok, res = self:champion_clear()
  elseif name == 'champion_filter' then ok, res = self:champion_filter(arg)
  elseif name == 'champion_save' then ok, res = self:champion_save()
  else return self:fail('unknown_action')
  end
  if ok == false then return self:fail(res or 'action_unavailable') end
  self:tutorialNotify(name)
  return true
end

function GS:openShopEarly()
  local st = self.state
  if st.state ~= 'player' and st.state ~= 'bet' then return self:fail('action_unavailable') end
  if not self:hasRelic('mobile_network') then return self:fail('action_unavailable') end
  st.roundsSinceShop = 0
  self:openShop()
  return true
end

function GS:closeTop()
  local st = self.state
  if st.shop and st.shop.forgeOpen then st.shop.forgeOpen = false; return true end
  if st.shop then return self:leave_shop() end
  if st.shoeOpen then st.shoeOpen = false; return true end
  if st.deckOpen then st.deckOpen = false; return true end
  if st.deckEditor then return self:close_deck_editor() end
  if st.state == 'result' or st.state == 'stageClear' or st.state == 'victory' or st.state == 'forceExit' or st.state == 'bar_ending' then return self:continue() end
  if st.state == 'classSelect' or st.state == 'classOffer' then return self:skip_class_offer() end
  if st.state == 'title' then return true end
  return true
end

function GS:setSetting(arg)
  arg = arg or {}
  local key = arg.key
  if key == nil then return self:fail('invalid_arg') end
  if key == 'bankruptAutoEnd' then key = 'autoEndOnBroke' end
  if key == 'autoEndOnBroke' then self.settings.autoEndOnBroke = arg.value ~= false
  elseif key == 'volume' then self.settings.volume = math.max(0, math.min(1, tonumber(arg.value) or 0))
  elseif key == 'resolution' then self.settings.resolution = tostring(arg.value or '1280x720')
  elseif key == 'fullscreen' then self.settings.fullscreen = arg.value == true
  else return self:fail('invalid_arg') end
  self:saveProgress()
  return true
end

function GS:toggleSetting(key)
  if key == 'fullscreen' then
    self.settings.fullscreen = not self.settings.fullscreen
  elseif key == 'autoEndOnBroke' or key == 'bankruptAutoEnd' then
    self.settings.autoEndOnBroke = not self.settings.autoEndOnBroke
  else
    return self:fail('invalid_arg')
  end
  self:saveProgress()
  return true
end

function GS:resetProgress()
  if self.persist then self.persist:resetProgress() end
  self.progress = self.persist and self.persist:readProgress() or { meta = {} }
  self:resetState()
  return true
end

function GS:can(action)
  local st = self.state
  if action == 'hit' or action == 'stand' then return st.state == 'player' and not st.player.stood and not st.player.busted end
  if action == 'double' then return st.state == 'player' and #st.player.hand == 2 and not st.player.blackjack and not st.player.is67 and st.chips >= st.bet end
  if action == 'accuse' then return (st.state == 'player' or st.state == 'dealer') and not st.flags.accusedThisRound end
  if action == 'bet_confirm' then return st.state == 'bet' and st.bet >= 1 end
  if action == 'hit' then return st.state == 'player' end
  return true
end

function GS:getView()
  return self.state
end

GS.methodAliases = GS.ALIASES

-- Production modules are mandatory. Keep meta last so tutorial gates wrap final actions.
require('src.bar_actions').install(GS)
require('src.relic_actions').install(GS)
require('src.class_actions').install(GS)
require('src.meta_actions').install(GS)

return GS
