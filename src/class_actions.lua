-- src/class_actions.lua
-- 职阶独立实现（玩家 7 职阶 + 困难模式庄家 7 职阶）。
-- 由 src/game_state.lua 底部 pcall require 后 install(GS)；不改 game_state/classes/relics。
-- 设计：只包裹必要方法，全部保留原实现作为内层调用（wrap），并保持公共 API 兼容。
--   require('src.class_actions').install(GS)
-- 残卷（class_*_shard）的 special 效果归 src/relic_actions.lua；本模块只提供可复用 helper：
--   M.saberSlash / M.archerPreview / M.lancerThirdCard / M.replaceRelic / M.replaceRelicById /
--   M.openCasterOffer / M.dealerCasterGain / M.anyPlayerClass / M.anyDealerClass
local Classes = require('src.classes')
local Relics = require('src.relics')
local BJ = require('src.blackjack')

local M = {}
M.VERSION = 1
M.CASTER_DEALER_CAP = 5          -- 庄家术阶最多 5 件遗物
M.STREAK_EVERY = 3               -- 连胜 3 触发
M.SABER_MIN_CARDS = 2            -- 至少 2 张才可斩
M.ARCHER_DEALER_AI = 3           -- 庄家弓：使用读玩家点数的 AI

-- ===================== 查询 helper =====================

local function activeShard(gs, id)
  local inst = gs:relicById('class_' .. tostring(id) .. '_shard')
  if inst and inst._active and not inst._expired then return inst end
  return nil
end

function M.activeShard(gs, id) return activeShard(gs, id) end

function M.playerClassId(gs)
  local pc = gs.state.playerClass
  return pc and pc.id or nil
end

function M.dealerClassId(gs)
  local dc = gs.state.dealerClass
  return dc and dc.id or nil
end

-- 仅玩家职阶（残卷不参与，避免与 relic_actions 双重生效）
function M.isPlayerClass(gs, id)
  local pc = gs.state.playerClass
  return pc ~= nil and pc.id == id
end

function M.isDealerClass(gs, id)
  local dc = gs.state.dealerClass
  return dc ~= nil and dc.id == id
end

-- 职阶或点亮中的残卷（供 relic_actions / UI 查询，本模块内部效果只认职阶）
function M.anyPlayerClass(gs, id)
  if M.isPlayerClass(gs, id) then return true end
  return activeShard(gs, id) ~= nil
end

function M.anyDealerClass(gs, id)
  return M.isDealerClass(gs, id)
end

-- ===================== 结算/斩牌 helper =====================

-- 斩断某一方点数最小的一张牌（A 已由 BJ.cardValue 记 1），真实进弃牌堆。
function M.saberSlash(gs, side)
  local st = gs.state
  local hand = (side == 'player') and st.player.hand or st.dealer.hand
  if not hand or #hand < M.SABER_MIN_CARDS then return false, 'too_few_cards' end
  local idx, best = nil, nil
  for i = 1, #hand do
    local v = BJ.cardValue(hand[i]) or 0
    if best == nil or v < best then best = v; idx = i end
  end
  if not idx then return false, 'no_card' end
  local card = table.remove(hand, idx)
  if st.deck then st.deck:toDiscard(card) end
  if side == 'player' then gs:refreshPlayer() else gs:refreshDealer() end
  local label = BJ.cardLabel(card)
  gs:msg((side == 'dealer') and ('剑阶斩断庄家一张 ' .. label) or ('庄家剑阶斩断你的一张 ' .. label), 'warning')
  return true, { side = side, card = card, value = BJ.cardValue(card), index = idx, label = label }
end

-- ===================== 弓 helper =====================

-- 下注时窥视牌靴顶（不抽牌、不动牌靴、不消耗随机数）。
function M.archerPreview(gs, source)
  local st = gs.state
  local deck = st.deck
  if not deck or not deck.drawPile or #deck.drawPile == 0 then return nil end
  local c = deck.drawPile[1]
  st.classPreview = st.classPreview or {}
  st.classPreview.player = {
    card = c, label = BJ.cardLabel(c), rank = c.rank, suit = c.suit,
    source = source or 'class', round = st.round,
  }
  if st.player then st.player._archerPreview = c end
  gs:emit({ kind = 'class_fx', fx = 'archer_preview', card = c, source = source or 'class' })
  return c
end

-- ===================== 枪 helper =====================

-- 窥视式第三张：发到后若爆则不真发（有吸收词的牌无法还原，改入弃牌堆）。
function M.lancerThirdCard(gs, side)
  local st = gs.state
  local hand = (side == 'player') and st.player.hand or st.dealer.hand
  if not hand or #hand < 3 then return false, 'not_dealt' end
  if BJ.handTotal(hand) <= 21 then return true, 'safe' end
  local c = table.remove(hand, #hand)
  if c and st.deck then
    if c.absorbed_from then st.deck:toDiscard(c) else st.deck:addToDraw(c) end
  end
  if side == 'player' then gs:refreshPlayer() else gs:refreshDealer() end
  gs:emit({ kind = 'class_fx', fx = 'lancer_peek', side = side, card = c, returned = true })
  return true, 'returned'
end

-- ===================== 术阶 helper =====================

function M.relicTargetEntries(list)
  local out = {}
  for i = 1, #list do
    local r = list[i]
    out[#out + 1] = {
      kind = 'relic', id = r.id, name = r.name or r.id, desc = r.desc or '',
      rarity = r.rarity, price = r.price, relic = r, def = r.def,
    }
  end
  return out
end

-- 3 个随机候选（优先未持有；不足则允许重复持有）
function M.rollCasterCandidates(gs, n)
  n = n or 3
  local held = {}
  for _, r in ipairs(gs:activeRelics()) do held[r.id] = true end
  local function gather(allowHeld)
    local pool = {}
    for i = 1, #Relics.LIST do
      local d = Relics.LIST[i]
      if not Relics.isPoolExcluded(d) and (allowHeld or not held[d.id]) then pool[#pool + 1] = d end
    end
    return pool
  end
  local pool = gather(false)
  if #pool < n then pool = gather(true) end
  local out = {}
  while #out < n and #pool > 0 do
    local d = table.remove(pool, gs:rint(1, #pool))
    out[#out + 1] = { kind = 'relic', id = d.id, name = d.name, desc = d.desc, rarity = d.rarity, price = d.price, def = d }
  end
  return out
end

-- 用新遗物替换 activeRelics 中第 activeIndex 件（保持槽位数量与顺序）。
function M.replaceRelic(gs, activeIndex, newDef)
  if not newDef then return false, 'invalid_arg' end
  local st = gs.state
  local inst = gs:activeRelics()[tonumber(activeIndex) or 0]
  if not inst then return false, 'invalid_arg' end
  for i = 1, #st.relics do
    if st.relics[i] == inst then
      local gained = gs:makeRelicInstance(newDef)
      st.relics[i] = gained
      gs:syncRelicAliases()
      gs:hookRelicGained(gained)
      gs:emit({ kind = 'class_fx', fx = 'caster_replace', removed = inst.id, gained = newDef.id })
      gs:msg('术阶：以 ' .. tostring(newDef.name or newDef.id) .. ' 替换 ' .. tostring(inst.name or inst.id) .. '。', 'success')
      return true, gained
    end
  end
  return false, 'invalid_arg'
end

-- 按 id 替换（术之残卷自我替换）。
function M.replaceRelicById(gs, id, newDef)
  if not id or not newDef then return false, 'invalid_arg' end
  local st = gs.state
  for i = 1, #st.relics do
    local r = st.relics[i]
    if r.id == id and not r._expired then
      local gained = gs:makeRelicInstance(newDef)
      st.relics[i] = gained
      gs:syncRelicAliases()
      gs:hookRelicGained(gained)
      gs:emit({ kind = 'class_fx', fx = 'caster_replace', removed = r.id, gained = newDef.id })
      gs:msg('术阶：残卷化作 ' .. tostring(newDef.name or newDef.id) .. '。', 'success')
      return true, gained
    end
  end
  return false, 'invalid_arg'
end

-- 打开术阶替换弹层。source='caster'（玩家职阶）| 'caster_shard'（残卷，relic_actions 调用）。
function M.openCasterOffer(gs, source)
  local st = gs.state
  if st.classOffer then return false, 'offer_open' end
  local cands = M.rollCasterCandidates(gs, 3)
  if #cands == 0 then return false, 'no_candidate' end
  local purpose = (source == 'caster_shard') and 'caster_shard' or 'caster_replace'
  st.classOffer = {
    mode = 'classOffer',
    source = source or 'caster',
    purpose = purpose,
    phase = 'pick',
    candidates = cands,
    targetCandidates = nil,
    pending = nil,
    replaceId = (source == 'caster_shard') and 'class_caster_shard' or nil,
    resumeState = st.state,
  }
  gs:setState('classOffer')
  gs:emit({ kind = 'class_fx', fx = 'caster_offer', source = st.classOffer.source, count = #cands })
  gs:msg('术阶：连胜达成，选择一件遗物。', 'success')
  return true
end

local function resolveCasterOffer(gs, consumed)
  local st = gs.state
  local co = st.classOffer
  if not co then return false end
  local resume = co.resumeState or 'result'
  st.classOffer = nil
  gs:setState(resume)
  gs:emit({ kind = 'class_fx', fx = 'caster_resolved', consumed = consumed == true })
  return true
end
M.resolveCasterOffer = resolveCasterOffer

local function applyCasterReplace(gs, co, targetIndex)
  local cand = co.pending
  if not cand then return false, 'no_pending' end
  if co.purpose == 'caster_shard' then
    local ok = M.replaceRelicById(gs, co.replaceId, cand.def)
    if not ok then return false, 'invalid_arg' end
  else
    local ok = M.replaceRelic(gs, targetIndex, cand.def)
    if not ok then return false, 'invalid_arg' end
  end
  resolveCasterOffer(gs, true)
  return true
end

-- 庄家术阶每累计 3 连胜夺 1 件遗物（独立于玩家遗物，只记在 dealerClass.relics）。
function M.dealerCasterGain(gs)
  local st = gs.state
  local dc = st.dealerClass
  if not dc then return false, 'no_dealer_class' end
  dc.relics = dc.relics or {}
  if #dc.relics >= M.CASTER_DEALER_CAP then return false, 'cap' end
  local have = {}
  for _, r in ipairs(dc.relics) do have[r.id] = true end
  local pool = {}
  for i = 1, #Relics.LIST do
    local d = Relics.LIST[i]
    if not Relics.isPoolExcluded(d) and not have[d.id] then pool[#pool + 1] = d end
  end
  if #pool == 0 then return false, 'no_candidate' end
  local d = pool[gs:rint(1, #pool)]
  dc.relics[#dc.relics + 1] = gs:makeRelicInstance(d)
  gs:emit({ kind = 'class_fx', fx = 'dealer_caster_gain', relic = d.id, count = #dc.relics })
  gs:msg('庄家术阶夺得遗物（玩家 -1 / 庄家 +' .. tostring(math.floor(#dc.relics / 2)) .. '）。', 'warning')
  return true, d.id
end

-- 困难模式换阶段庄家职阶：必须与上一个不同。
function M.dealerClassForStage(gs, prev)
  local id = Classes.randomAnother(prev, function(a, b) return gs:rint(a, b) end)
  if not id then id = gs:rpick(Classes.ORDER) end
  return Classes.dealerRuntime(id)
end

-- ===================== install =====================

function M.install(GS)
  if not GS then return false, 'no_gs' end
  if GS.__classActionsV1 then return true end
  GS.__classActionsV1 = true

  local origStart = GS.start
  local origBeginBet = GS.beginBet
  local origDealInitial = GS.dealInitial
  local origDecideCheat = GS.decideCheat
  local origDealerStep = GS.dealerStep
  local origCollect = GS.collectFinalResult
  local origRefreshPlayer = GS.refreshPlayer
  local origRefreshDealer = GS.refreshDealer
  local origSettle = GS.settle
  local origFinalize = GS.finalizeRound
  local origTakeOffer = GS.take_class_offer
  local origSkipOffer = GS.skip_class_offer
  local origFinishClassFlow = GS.finishClassFlow

  -- ---- 开局：困难模式阶段 1 也要有庄家职阶 ----
  GS.start = function(self, mode, seed)
    local ok, err = origStart(self, mode, seed)
    if ok == false then return ok, err end
    local st = self.state
    if st.mode == 'hard' and not st.dealerClass then
      st.dealerClass = M.dealerClassForStage(self, nil)
      self:emit({ kind = 'class_fx', fx = 'dealer_class', id = st.dealerClass.id, stage = st.stage })
    end
    return ok, err
  end

  -- ---- 下注：重置职阶结算状态；庄家弓用读牌 AI；玩家弓预览 ----
  GS.beginBet = function(self, ...)
    local st = self.state
    st.classEffect = {}
    local r = origBeginBet(self, ...)
    -- 残卷每局重置（st.shardRiderArmed=false）由 relic_actions 的 hookBetPre 负责，本模块不重复管理
    if st.dealerClass and st.dealerClass.id == 'archer' then
      st.dealer.difficulty = M.ARCHER_DEALER_AI
    end
    if M.isPlayerClass(self, 'archer') then M.archerPreview(self, 'class') end
    return r
  end

  -- ---- 发牌：枪阶第三张窥视纠正；弓阶预览标记 ----
  GS.dealInitial = function(self, ...)
    local st = self.state
    local r = origDealInitial(self, ...)
    if M.isPlayerClass(self, 'lancer') then
      local p = st.player
      if #p.hand >= 3 and BJ.handTotal(p.hand) > 21 then M.lancerThirdCard(self, 'player') end
    end
    if M.isPlayerClass(self, 'archer') then
      local c = st.player.hand[1]
      if c then c._peek = true end
      st.player._archerPeek = true
    end
    if st.dealerClass and st.dealerClass.id == 'archer' then
      local c = st.player.hand[1]
      st.dealer._archerPreview = c
      if c then c._dealerSeen = true end
      self:emit({ kind = 'class_fx', fx = 'dealer_archer_preview', card = c })
    end
    return r
  end

  -- ---- 杀阶：屏蔽读牌类千招的分支打标 ----
  GS.decideCheat = function(self, ...)
    local intent = origDecideCheat(self, ...)
    if intent and intent.shielded then
      self.state.cheatTrace = nil
      self:emit({ kind = 'class_fx', fx = 'assassin_shield', source = 'class' })
    end
    return intent
  end

  -- ---- 庄家行动：Rider 跳过时补特效（核心已实现 50% 跳过）----
  GS.dealerStep = function(self, ...)
    local dc0 = self.state.dealerClass
    local before = (dc0 and dc0.id == 'rider') and (dc0.usesLeft or 0) or nil
    local r = origDealerStep(self, ...)
    local dc1 = self.state.dealerClass
    if before and dc1 and (dc1.usesLeft or 0) < before then
      self:emit({ kind = 'class_fx', fx = 'dealer_rider_skip', usesLeft = dc1.usesLeft })
    end
    return r
  end

  -- ---- 结算属性：术阶级差在结算前写入，refresh 幂等应用 ----
  GS.settle = function(self, ...)
    local st = self.state
    st.classEffect = st.classEffect or {}
    if st.dealerClass and st.dealerClass.id == 'caster' then
      st.classEffect.casterDebuff = #(st.dealerClass.relics or {})
    end
    return origSettle(self, ...)
  end

  -- ---- 刷新：术阶庄家 debuff 应用在最终点/爆点上 ----
  GS.refreshPlayer = function(self, ...)
    local p = origRefreshPlayer(self, ...)
    if not p then return p end
    local eff = self.state.classEffect
    local n = (eff and eff.casterDebuff) or 0
    if n > 0 then
      local before = p.total
      local applied = p.total - n
      if applied < 2 then applied = 2 end
      assert(applied >= 2, 'caster debuff must not reduce player below 2')
      p.total = applied
      p.rawTotal = p.total
      local tolerant = M.isPlayerClass(self, 'berserker')
      p.busted = p.total > (tolerant and 25 or 21)
      if p.is67 or BJ.has67(p.hand) then p.is67 = true; p.busted = false end
      if before > 21 and p.total <= 21 then p.casterRescued = true end
    end
    return p
  end

  GS.refreshDealer = function(self, ...)
    local d = origRefreshDealer(self, ...)
    if not d then return d end
    local eff = self.state.classEffect
    local n = (eff and eff.casterDebuff) or 0
    if n > 0 then
      d.total = d.total + math.floor(n / 2)
      d.rawTotal = d.total
      local tolerant = self.state.dealerClass and
        (self.state.dealerClass.id == 'lancer' or self.state.dealerClass.id == 'berserker')
      d.busted = (tolerant and d.total > 25) or ((not tolerant) and d.total > 21)
    end
    return d
  end

  -- ---- 比点：先斩牌（玩家剑→庄家，庄家剑→玩家），再按职阶修正胜负 ----
  GS.collectFinalResult = function(self, ...)
    local st = self.state
    st.classEffect = st.classEffect or {}
    if M.isPlayerClass(self, 'saber') and not st.classEffect.saberPlayer then
      local ok, info = M.saberSlash(self, 'dealer')
      if ok then
        st.classEffect.saberPlayer = true
        if st.playerClass then st.playerClass._saberUsed = true end
        self:emit({ kind = 'class_fx', fx = 'saber_slash', side = 'dealer', duration = 0.9,
                    card = info.card, value = info.value, source = 'class' })
      end
    end
    if M.isDealerClass(self, 'saber') and not st.classEffect.saberDealer then
      local ok, info = M.saberSlash(self, 'player')
      if ok then
        st.classEffect.saberDealer = true
        self:emit({ kind = 'class_fx', fx = 'saber_slash', side = 'player', duration = 0.9,
                    card = info.card, value = info.value, source = 'dealer_class' })
      end
    end

    local outcome = origCollect(self, ...)
    local p, d = st.player, st.dealer
    if p.is67 or BJ.has67(p.hand) then
      -- 67 优先，任何职阶不得覆盖
      p.is67 = true
      p.busted = false
      outcome = 'player'
    elseif p.isRps and d.isRps then
      -- 猜拳模式由核心判定，职阶不覆盖
    else
      if M.isPlayerClass(self, 'berserker') and not p.busted and p.total >= 22 and p.total <= 25 then
        -- GDD 1717: 未爆且「比庄家大」才判胜。核心对同点误判为玩家胜，这里纠回基础 push；
        -- 庄家狂阶「不比玩家小即庄家」的平局例外由下方分支覆盖。
        if p.total > d.total then
          outcome = 'player'
        elseif p.total == d.total and not d.busted then
          outcome = 'push'
        end
      end
      if M.isDealerClass(self, 'berserker') and not d.busted and d.total >= 22 and d.total <= 25 then
        if p.total <= d.total then outcome = 'dealer' end
      end
    end
    return outcome
  end

  -- ---- 回合末：术阶连胜计数/触发（玩家 3 连胜开替换；庄家 3 连胜夺遗物）----
  GS.finalizeRound = function(self, result, forced)
    local st = self.state
    local r = origFinalize(self, result, forced)
    local dc = st.dealerClass
    if dc and dc.id == 'caster' and result then
      if result.outcome == 'dealer' then
        dc.streak = (dc.streak or 0) + 1
        if dc.streak % M.STREAK_EVERY == 0 then M.dealerCasterGain(self) end
      elseif result.outcome == 'player' then
        dc.streak = 0
      end
    end
    if M.isPlayerClass(self, 'caster') and result and result.outcome == 'player' then
      local streak = st.streak or 0
      if streak > 0 and streak % M.STREAK_EVERY == 0 and not st.classOffer then
        M.openCasterOffer(self, 'caster')
      end
    end
    return r
  end

  -- ---- 骑阶：完全替换 skip_round（修正下注阶段幻影归还/次数不扣）----
  GS.skip_round = function(self)
    local st = self.state
    if st.state ~= 'bet' and st.state ~= 'player' then return self:fail('action_unavailable') end
    local rider = M.isPlayerClass(self, 'rider') and (st.playerClass.usesLeft or 0) > 0
    -- 残卷契约（relic_actions）：点亮 class_rider_shard 时置 st.shardRiderArmed=true 并已扣次；
    -- 本模块只判 arm，跳成功清 nil，不重复扣次、不判 hasRelic；hookBetPre 每局重置。
    local shardReady = st.shardRiderArmed == true
    if not (rider or shardReady) then return self:fail('action_unavailable') end
    -- 骑阶次数在任何可跳过状态（下注/玩家）都消耗一次
    if rider then st.playerClass.usesLeft = (st.playerClass.usesLeft or 0) - 1 end
    if st.state == 'player' then
      -- 仅在注码已被 bet_confirm 扣除时归还（下注阶段未扣，不归还）
      if (st.bet or 0) > 0 then st.chips = st.chips + st.bet end
      if st.bustBet and st.bustBet.on and (st.bustBet.amount or 0) > 0 then
        st.chips = st.chips + st.bustBet.amount
        st.bustBet.amount = 0
        st.bustBet.on = false
        st.bustBet.locked = false
        st.bustBet.hit = false
      end
    end
    st.flags.riderUsedThisRound = true
    if shardReady then st.shardRiderArmed = nil end
    st.result = {
      outcome = 'push', bet = st.bet, netChange = 0, skipped = true,
      skippedBy = rider and 'rider_class' or (shardReady and 'rider_shard' or nil),
    }
    self:setState('result')
    self:scheduleAfterRound()
    self:emit({ kind = 'class_fx', fx = 'rider_skip', side = 'player' })
    self:msg('跳过本小局，下注已归还。', 'info')
    return true
  end

  -- ---- 术阶替换弹层：两阶段（pick -> target），复用 candidates 字段以最小化 UI 改动 ----
  GS.take_class_offer = function(self, index, targetIndex)
    local st = self.state
    local co = st.classOffer
    if not co or (co.purpose ~= 'caster_replace' and co.purpose ~= 'caster_shard') then
      return origTakeOffer(self, index, targetIndex)
    end
    if co.phase == 'pick' or co.phase == nil then
      local cand = co.candidates[tonumber(index) or 0]
      if not cand or not cand.def then return self:fail('invalid_arg') end
      co.pending = cand
      co.phase = 'target'
      co.targetCandidates = self:activeRelics()
      co.candidates = M.relicTargetEntries(co.targetCandidates)
      self:emit({ kind = 'class_fx', fx = 'caster_pick', candidate = cand.id })
      self:msg('选择要替换的遗物（Esc 放弃）。', 'info')
      return true
    end
    local ti = tonumber(targetIndex) or tonumber(index)
    local ok, err = applyCasterReplace(self, co, ti)
    if not ok then return self:fail(err or 'invalid_arg') end
    return true
  end

  GS.skip_class_offer = function(self, ...)
    local co = self.state.classOffer
    if co and (co.purpose == 'caster_replace' or co.purpose == 'caster_shard') then
      local resume = co.resumeState or 'result'
      self.state.classOffer = nil
      self:setState(resume)
      self:msg('术阶：放弃替换。', 'info')
      return true
    end
    return origSkipOffer(self, ...)
  end

  -- ---- 阶段 3：庄家职阶必须与阶段 2 不同（完全替换，修正随机重复）----
  GS.finishClassFlow = function(self, ...)
    local st = self.state
    st.classOffer = nil
    self:applyStage(3)
    self:hookStageStart()
    if st.mode == 'hard' then
      local prev = st.dealerClass and st.dealerClass.id
      st.dealerClass = M.dealerClassForStage(self, prev)
      self:emit({ kind = 'class_fx', fx = 'dealer_class', id = st.dealerClass.id, stage = st.stage })
    end
    st.classEffect = {}
    self:buildShoe()
    self:beginBet()
    self:msg('进入 ' .. tostring(st.stageName), 'info')
    return true
  end

  GS.classActions = M
  return true
end

return M
