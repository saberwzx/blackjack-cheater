-- src/relic_actions.lua — 遗物行为独立实现（只读核心，不修改 game_state.lua）
-- 由父代理在 game_state 底部 require 后 install(GS)；推荐安装顺序 bar -> relic -> class -> meta，
-- 但本模块对顺序宽容：若 class_actions 之后又覆盖了 skip_round，可调用 postInstall(GS) 重新接管。
-- 职责：覆盖 registerSpecials / hookBetPre / hookRoundStart / hookDealAfter / hookPlayerHit /
--       toggle_relic / use_relic / activateRelic / markCard / mark_card / rod_* / playerHit /
--       refreshPlayer / openShopEarly / leave_shop / accuse / finalizeRound，把 139 件遗物中
--       真正缺失或条件错误的行为补齐。只在效果真实生效时扣次。
local BJ = require('src.blackjack')
local DT = require('src.deck_types')
local Marks = require('src.marks')

local M = {}
M.VERSION = 1

-- 本小局需重新点亮的遗物（激活状态每小局重置；与 GDD「本小局」一致）
local ROUND_ACTIVE = {
  black_hole = true,
  class_rider_shard = true, class_archer_shard = true, class_lancer_shard = true,
  class_assassin_shard = true, class_saber_shard = true, class_berserker_shard = true,
}

-- 点亮即生效（即发型）；activation 直接执行 special，扣次由 special 自身决定
local INSTANT = {
  peek = true, burn = true, reveal = true, rod = true,
  discard_rinse = true, discard_backflow = true, discard_salvager = true,
  gain_mark = true, shard_rider = true, open_shop_early = true,
}

local SUITS = { 'S', 'H', 'D', 'C' }
local TEN_RANKS = { '10', 'J', 'Q', 'K' }

local function rndSuit(gs) return SUITS[gs:rint(1, #SUITS)] end
local function isTenRank(r) return r == '10' or r == 'J' or r == 'Q' or r == 'K' end

local function handValueA1(hand)
  local s = 0
  for i = 1, #hand do
    local c = hand[i]
    if BJ.isAce(c) then s = s + 1 else s = s + (BJ.cardValue(c) or 0) end
  end
  return s
end

local function handHasRank(hand, rank)
  for i = 1, #hand do if hand[i].rank == rank then return true end end
  return false
end

local function findRelic(gs, arg)
  if type(arg) == 'number' then return gs:activeRelics()[arg] end
  if type(arg) == 'string' then return gs:relicById(arg) end
  if type(arg) == 'table' then
    if arg.id then return gs:relicById(arg.id) end
    if arg.index then return gs:activeRelics()[arg.index] end
  end
  return nil
end

local function mkCard(gs, rank, suit)
  local c = DT.mk({ rank = tostring(rank), suit = suit or rndSuit(gs), kind = 'basic', is_basic = false, is_synthetic = true })
  gs.state.deck:assignUid(c)
  gs.state.syntheticCount = (gs.state.syntheticCount or 0) + 1
  return c
end

local function replaceLast(gs, card)
  local hand = gs.state.player.hand
  local old = table.remove(hand, #hand)
  if old then gs.state.deck:toDiscard(old) end
  gs:pushHand('player', card)
end

local function drawMatching(gs, pred, fallbackRank, fallbackSuit)
  local c = gs.state.deck:drawWhere(pred)
  if c then return c end
  return mkCard(gs, fallbackRank, fallbackSuit)
end

local function consumeRod(gs)
  local st = gs.state
  if st.rodRelicId then gs:consumeRelic(st.rodRelicId) end
  st.rodMode = nil; st.rodRelicId = nil; st.rodFirst = nil; st.rodSelection = nil
end

function M.install(GS)
  if not GS then return false, 'no_gs' end
  if GS.__relicActionsV1 then return true end
  GS.__relicActionsV1 = true

  local orig = {
    registerSpecials = GS.registerSpecials,
    hookBetPre = GS.hookBetPre,
    hookRoundStart = GS.hookRoundStart,
    hookDealAfter = GS.hookDealAfter,
    hookPlayerHit = GS.hookPlayerHit,
    toggle_relic = GS.toggle_relic,
    use_relic = GS.use_relic,
    activateRelic = GS.activateRelic,
    markCard = GS.markCard,
    mark_card = GS.mark_card,
    rod_pick = GS.rod_pick,
    rod_confirm = GS.rod_confirm,
    playerHit = GS.playerHit,
    playerSurrender = GS.playerSurrender,
    refreshPlayer = GS.refreshPlayer,
    openShopEarly = GS.openShopEarly,
    leave_shop = GS.leave_shop,
    bet_set = GS.bet_set,
    bet_confirm = GS.bet_confirm,
    accuse = GS.accuse,
    finalizeRound = GS.finalizeRound,
    drawCard = GS.drawCard,
  }
  local function O(name, self, ...)
    local f = orig[name]
    if f then return f(self, ...) end
  end

  -- ===================== 结算期 special（scoreHandlers） =====================

  GS.registerSpecials = function(self)
    O('registerSpecials', self)
    local S = self.specials
    local H = self.scoreHandlers

    H.stage_win = function(ctx)
      if ctx.player and ctx.player.total == 21 then
        local gs = ctx.gs
        local gst = gs.state
        gst.supremeClear = true
        local reward = gst.stageTarget or 0
        ctx.score.chips = (ctx.score.chips or 0) + reward
        ctx.score.breakdown[#ctx.score.breakdown + 1] = { label = '21 至尊', kind = 'chips', value = reward }
        if (gst.roundsInStage or 0) > 0 then gst.roundsInStage = gst.roundsInStage - 1 end
        gs:consumeRelic('twentyone_supreme')
        gs:msg('21 至尊：阶段目标达成！', 'success')
      end
    end
    H.first_hit_safe = function() end
    -- 软 22 = 含 A 且按 A=11 计恰好 22。BJ.isSoft 只在 total<=21 时可能为真，
    -- total==22 时 BJ.isSoft 恒为 false，故不能拿它判定软 22（否则该遗物永不生效）。
    local function isSoft22(h) return BJ.hasAce(h) and BJ.handRawTotal(h) == 22 end
    H.soft_22_safe = function(ctx)
      if ctx.player and ctx.player.total == 22 and isSoft22(ctx.player.hand) then
        ctx.player.busted = false
        if ctx.outcome == 'dealer' then ctx.outcome = 'push'; ctx.forceResult = 'push' end
        if ctx.gs then ctx.gs:consumeRelic('soft_22_safe') end
      end
    end
    H.soft_22_win = function(ctx)
      if ctx.player and ctx.player.total == 22 and isSoft22(ctx.player.hand) then
        ctx.player.busted = false
        ctx.forceResult = 'player'
        if ctx.gs then ctx.gs:consumeRelic('soft_bust_shield') end
      end
    end
    H.last_card_save = function() end  -- on_hit 处理，见 hookPlayerHit
    H.ace_revolution = function(ctx)
      local h = ctx.player.hand
      if ctx.player.is67 or BJ.has67(h) then
        ctx.player.is67 = true; ctx.player.busted = false
        ctx.outcome = 'player'; ctx.forceResult = 'player'
        return
      end
      ctx.player.total = BJ.handRawTotal(h)
      ctx.player.busted = ctx.player.total > 21
      ctx.outcome = BJ.compare(ctx.player.total, ctx.dealer.total, ctx.player.busted, ctx.dealer.busted)
    end
    H.shard_saber = function(ctx)
      local gs = ctx.gs
      local inst = gs and gs:relicById('class_saber_shard')
      if not inst or inst._expired or not inst._active then return end
      if gs.state.playerClass and gs.state.playerClass.id == 'saber' then return end  -- 不叠加
      local CA = gs.classActions
      if not (CA and CA.saberSlash) then return end
      local ok, info = CA.saberSlash(gs, 'dealer')
      if ok then
        gs:consumeRelic('class_saber_shard')
        gs:emit({ kind = 'class_fx', fx = 'saber_slash', side = 'dealer', card = info and info.card, source = 'shard' })
      end
    end
    H.shard_berserker = function(ctx)
      local gs = ctx.gs
      local inst = gs and gs:relicById('class_berserker_shard')
      if not inst or inst._expired or not inst._active then return end
      local p, d = ctx.player, ctx.dealer
      if p.is67 or BJ.has67(p.hand) then return end
      if p.total >= 22 and p.total <= 25 then
        p.busted = false
        ctx.outcome = (p.total > d.total) and 'player' or 'dealer'  -- GDD：比庄家大才判胜
        gs:consumeRelic('class_berserker_shard')
      end
    end

    -- ---- 无特殊逻辑的 on_hit/被动（行为在 hookPlayerHit / 核心内联）----
    local noop = { 'card_pack', 'give_card', 'eight_ball', 'third_ten', 'always_10_on_third',
      'black_hole_absorb', 'hit_to_20', 'pair_to_21', 'auto_stand_next', 'ace_magnet',
      'ten_magnet', 'chase_ten', 'chase_ace', 'auto_stand_16', 'first_hit_safe',
      'dealer_fatigue', 'dealer_blind', 'anti_cheat', 'dealer_magnet', 'no_face_dealer',
      'suppress_distractor', 'cheat_force_bust', 'halve_cheat', 'mind_memory', 'ink_half',
      'mark_limit_up', 'sharp_family', 'hedge_fund', 'iron_evidence', 'accuse_bonus',
      'credit', 'late_surrender', 'reveal_ink', 'shard_saber', 'shard_berserker',
      'shard_caster', 'excluded' }
    for _, k in ipairs(noop) do if S[k] == nil then S[k] = function() end end end

    -- ---- 情报/牌库类即发 ----
    S.peek = function(gs, inst)
      local st = gs.state
      local base = inst.def.param1 or 1
      local bonus = gs:hasRelic('mind_memory') and 1 or 0
      local depth = base + bonus
      if #st.deck.drawPile == 0 then return false end
      if depth > #st.deck.drawPile then depth = #st.deck.drawPile end
      if depth <= 0 then return false end
      gs:revealShoeRange(1, depth, 'peek')
      st.shoeOpen = true
      if bonus > 0 and depth > base then gs:consumeRelic('mind_memory') end
      gs:consumeRelic(inst.id)
      gs:msg('窥牌：亮明牌靴前 ' .. depth .. ' 张。', 'info')
      return true
    end
    S.peek_auto = function(gs) return gs:relicApplyPeekAuto() end
    S.burn = function(gs, inst)
      local st = gs.state
      local n = inst.def.param1 or 1
      local moved = 0
      for _ = 1, n do
        local c = st.deck:draw()
        if not c then break end
        st.deck:toDiscard(c)
        moved = moved + 1
      end
      if moved == 0 then return false end
      gs:refreshShoe()
      gs:consumeRelic(inst.id)
      gs:msg('焚牌：' .. moved .. ' 张入弃牌堆。', 'info')
      return true
    end
    S.reveal = function(gs, inst)
      if #gs.state.deck.drawPile == 0 then return false end
      local a = inst.def.param1 or 1
      local b = inst.def.param2 or a
      gs:revealShoeRange(a, b, 'reveal')
      gs.state.shoeOpen = true
      gs:consumeRelic(inst.id)
      return true
    end
    S.rod = function(gs, inst)
      local st = gs.state
      st.rodMode = inst.def.param1
      st.rodRelicId = inst.id
      st.rodSelection = nil
      st.rodFirst = nil
      st.shoeOpen = true
      if st.shoeTab == nil then st.shoeTab = 'order' end
      gs:refreshShoe()
      gs:msg('钓具就绪：点击一张已标记牌选择目标。', 'info')
      return true
    end
    S.discard_rinse = function(gs, inst)
      local st = gs.state
      if #st.deck.discardPile == 0 then return false end
      st.deck:shuffleDiscardIn()
      gs:refreshShoe()
      gs:consumeRelic(inst.id)
      gs:msg('淘洗：弃牌堆洗回牌库。', 'info')
      return true
    end
    S.discard_backflow = function(gs, inst)
      local st = gs.state
      local n = inst.def.param1 or 3
      local moved = 0
      for _ = 1, n do
        if #st.deck.discardPile == 0 then break end
        local c = table.remove(st.deck.discardPile, #st.deck.discardPile)
        st.deck:addToDraw(c, 1)
        moved = moved + 1
      end
      if moved == 0 then return false end
      gs:refreshShoe()
      gs:consumeRelic(inst.id)
      return true
    end
    S.discard_salvager = function(gs, inst)
      local st = gs.state
      if #st.deck.discardPile == 0 then return false end
      st.salvageRelicId = inst.id
      st.salvagePending = true
      st.shoeOpen = true
      st.shoeTab = 'discard'
      gs:refreshShoe()
      gs:msg('打捞：在弃牌堆点选一张牌，下次要牌打出它。', 'info')
      return true
    end
    S.gain_mark = function(gs, inst)
      local id = inst.def.param1
      if not id or not Marks.SPECIAL[id] then return false end
      if not Marks.gainSpecial(gs.state, id) then return false end
      gs.state.specialMarkSource = inst.id
      gs:msg('获得特种标记：' .. tostring(Marks.SPECIAL[id].name), 'info')
      return true
    end
    S.open_shop_early = function(gs) return gs:openShopEarly() end

    -- ---- 残卷 ----
    S.shard_rider = function(gs, inst)
      -- 点亮即扣次（GDD）；最后一件被移除后仍靠本小局旗标生效
      gs.state.shardRiderArmed = true
      gs.state.flags.riderUsedThisRound = false
      gs:consumeRelic(inst.id)
      gs:msg('骑之残卷：本小局可跳过一局（R）。', 'info')
      return true
    end
    S.shard_archer = function(gs, inst)
      gs.state.shardArcherArmed = true
      gs:msg('弓之残卷：本小局发牌时预览第一张。', 'info')
      return true
    end
    S.shard_lancer = function(gs, inst)
      gs.state.shardLancerArmed = true
      gs:msg('枪之残卷：本小局开局三张（第三张保证不爆）。', 'info')
      return true
    end
    S.shard_assassin = function(gs, inst)
      gs.state.shardAssassinArmed = true
      gs:msg('杀之残卷：本小局庄家看不到你的牌。', 'info')
      return true
    end
    return true
  end

  -- 算牌师自动窥视（每小局），depth=1（+过目不忘则 +1）
  GS.relicApplyPeekAuto = function(self)
    local st = self.state
    local inst = self:relicById('peek_auto')
    if not inst or inst._expired then return false end
    local base = inst.def.param1 or 1
    local bonus = self:hasRelic('mind_memory') and 1 or 0
    st.peekDepth = math.max(st.peekDepth or 0, base + bonus)
    self:refreshShoe()
    if bonus > 0 then self:consumeRelic('mind_memory') end
    self:consumeRelic(inst.id)
    return true
  end

  -- ===================== 回合/下注钩子 =====================

  GS.hookBetPre = function(self)
    local st = self.state
    -- 每小局重置点亮态
    for i = 1, #st.relics do
      local r = st.relics[i]
      if r.def.trigger == 'active' or ROUND_ACTIVE[r.id] then r._active = false end
      r._roundActive = false
    end
    st.flags.riderUsedThisRound = nil
    st.flags.betDoubledThisRound = false
    st.flags.doubleBetUsed = false
    st._shopReturnState = nil
    st.shardRiderArmed = nil; st.shardArcherArmed = nil; st.shardLancerArmed = nil; st.shardAssassinArmed = nil
    st.salvagePending = nil; st.salvageCard = nil
    -- 下注集团每小局恢复（核心 _usedThisGame 不会重置）
    local bsy = self:relicById('bet_syndicate')
    if bsy then bsy._usedThisGame = nil end
    self:relicApplyPeekAuto()
    if orig.hookBetPre then orig.hookBetPre(self) end
    return true
  end

  GS.hookRoundStart = function(self)
    local st = self.state
    st.flags.doubleBetUsed = false
    st.flags.assassinSuppress = false
    st.casterBoost = false
    return true
  end

  -- ===================== 发牌后遗物 =====================

  GS.hookDealAfter = function(self)
    local st = self.state
    local p = st.player
    if not p or #p.hand < 2 then return end
    local function swap(index, rank, suit)
      local c = mkCard(self, rank, suit)
      self:replaceCard('player', index, c)
      return c
    end
    -- A 之保证：第一张总是 A♠
    if self:hasRelic('ace_guarantee') and not BJ.isAce(p.hand[1]) then swap(1, 'A', 'S') end
    -- 10 点保证：第二张总是 10/J/Q/K（随机）
    if self:hasRelic('ten_guarantee') and not isTenRank(p.hand[2] and p.hand[2].rank) then
      swap(2, TEN_RANKS[self:rint(1, #TEN_RANKS)], nil)
    end
    -- JQK 配对：第一张是 J/Q/K 时第二张也换成 J/Q/K
    if self:hasRelic('jackpot_two') and p.hand[1] and isTenRank(p.hand[1].rank)
       and not isTenRank(p.hand[2] and p.hand[2].rank) then
      swap(2, TEN_RANKS[self:rint(1, #TEN_RANKS)], nil)
    end
    -- 第二张 A：发牌后 40% -> A♣
    if self:hasRelic('second_ace') and not BJ.isAce(p.hand[2]) and self:rchance(0.40) then
      swap(2, 'A', 'C')
    end
    -- 枪之残卷：开局第三张，保证不爆
    if st.shardLancerArmed then
      st.shardLancerArmed = nil
      local inst = self:relicById('class_lancer_shard')
      if inst and inst._active then
        local c = self:drawCard('player')
        if c then
          self:pushHand('player', c)
          if BJ.handTotal(p.hand) > 21 then
            table.remove(p.hand, #p.hand)
            st.deck:toDiscard(c)
          end
        end
        self:consumeRelic('class_lancer_shard')
      end
    end
    -- 弓之残卷：预览第一张
    if st.shardArcherArmed then
      st.shardArcherArmed = nil
      local inst = self:relicById('class_archer_shard')
      if inst and inst._active then
        local c = p.hand[1]
        if c then
          c._peek = true
          p._archerPeek = true
          st.classPreview = st.classPreview or {}
          st.classPreview.player = { card = c, label = BJ.cardLabel(c) }
        end
        self:consumeRelic('class_archer_shard')
      end
    end
    -- 杀之残卷：若确实屏蔽了看牌千术才扣次
    if st.shardAssassinArmed then
      st.shardAssassinArmed = nil
      local inst = self:relicById('class_assassin_shard')
      if inst and inst._active and st.cheatIntent and st.cheatIntent.shielded then
        self:consumeRelic('class_assassin_shard')
      end
    end
    self:refreshPlayer()
    self:refreshDealer()
  end

  -- ===================== 要牌后遗物（on_hit） =====================

  GS.playerHit = function(self, ...)
    local st = self.state
    local p = st.player
    st._preHit = p and { total = p.total, len = #p.hand, pair = BJ.isPair(p.hand), has8 = handHasRank(p.hand, '8') } or nil
    local ok, err = O('playerHit', self, ...)
    st._preHit = nil
    return ok, err
  end

  GS.hookPlayerHit = function(self)
    local st = self.state
    local p = st.player
    local n = #p.hand
    if n == 0 then return end
    local pre = st._preHit or { total = 0, len = n - 1, pair = false, has8 = false }
    local function curTotal() return BJ.handTotal(p.hand) end

    -- 1) 打捞：下次要牌改为打出寄存的弃牌
    if st.salvageCard then
      local card = st.salvageCard
      st.salvageCard = nil
      local zone, list, idx = self:locateCard(card)
      if zone and list and idx then table.remove(list, idx) end
      replaceLast(self, card)
      self:consumeRelic('discard_salvager')
      self:emit({ kind = 'relic_fx', fx = 'salvage', card = card })
      self:refreshPlayer()
      return
    end

    -- 2) 卡包：空则寄存，有则取出
    if self:hasRelic('card_pack') then
      if st.cardPack then
        local card = st.cardPack
        st.cardPack = nil
        replaceLast(self, card)
        self:msg('卡包：取出寄存的 ' .. BJ.cardLabel(card), 'info')
      else
        local last = table.remove(p.hand, #p.hand)
        if last then st.cardPack = last; p.cardPack = last end
        self:msg('卡包：寄存 ' .. tostring(last and BJ.cardLabel(last) or '?'), 'info')
      end
      self:refreshPlayer()
      return
    end

    -- 3) 黑洞（本小局点亮后，下一次要牌吸收第一张）
    local bh = self:relicById('black_hole')
    if bh and not bh._expired and bh._active then
      bh._active = false
      if n >= 2 then
        local first = table.remove(p.hand, 1)
        st.deck:toDiscard(first)
        local drawn = p.hand[#p.hand]
        local traits = { 'is_multiplier', 'mult_bonus', 'is_rps', 'rps_symbol', 'is_67', 's67_rank',
                         'is_cage', 'is_chip', 'chip_value', 'is_dice', 'dice_sides', 'is_remove', 'is_champion' }
        for _, k in ipairs(traits) do if first[k] ~= nil then drawn[k] = first[k] end end
        drawn.absorbed_from = first.uid
        self:emit({ kind = 'card_discard', card = first, from = 'player' })
        self:emit({ kind = 'mark_fx', markId = 'black_hole', anchor = 'player', card = drawn })
        self:msg('黑洞：吸收手牌第一张。', 'info')
      end
      self:refreshPlayer()
      return
    end

    -- 4) 给牌组 2..8（2×）：强制点数
    for rank = 2, 8 do
      local id = 'give_card_' .. rank
      local inst = self:relicById(id)
      if inst and not inst._expired then
        replaceLast(self, mkCard(self, rank, nil))
        self:consumeRelic(id)
        self:msg('给牌：强制 ' .. rank .. ' 点。', 'info')
        self:refreshPlayer()
        return
      end
    end

    -- 5) 第三张必 10
    if self:hasRelic('always_10_on_third') and pre.len == 2 then
      replaceLast(self, mkCard(self, '10', 'C'))
      self:refreshPlayer()
      return
    end

    -- 6) 凑 20 为止（<20 且 ≤3 张）：给恰好到 20 的牌
    if self:hasRelic('hit_to_20') and pre.total < 20 and pre.len <= 3 and curTotal() ~= 20 and curTotal() <= 21 then
      local want = 20 - pre.total
      local rank = (want >= 10) and '10' or (want <= 1 and 'A' or tostring(want))
      replaceLast(self, mkCard(self, rank, nil))
      self:refreshPlayer()
      return
    end

    -- 7) 对子凑 21：有对子时给尽量到 21 的牌（太低只加 10）
    if self:hasRelic('pair_to_21') and pre.pair and curTotal() ~= 21 then
      local want = 21 - pre.total
      if want > 10 then want = 10 end
      local rank = (want >= 10) and '10' or (want <= 1 and 'A' or tostring(want))
      replaceLast(self, mkCard(self, rank, nil))
      self:refreshPlayer()
      return
    end

    -- 8) 八球幸运：手牌有 8 -> 下次要牌必给 10
    if self:hasRelic('eight_ball') and pre.has8 then
      replaceLast(self, drawMatching(self, function(c) return BJ.isTenValue(c) end, '10', nil))
      self:refreshPlayer()
      return
    end

    -- 9) 第一次要牌安全（只在真的避免爆牌时扣次）
    if self:hasRelic('first_hit_safe') and not st.flags.firstHitUsed then
      st.flags.firstHitUsed = true
      if curTotal() > 21 then
        replaceLast(self, mkCard(self, 'A', 'S'))
        self:consumeRelic('first_hit_safe')
        self:msg('第一次要牌安全：已避免爆牌。', 'warning')
        self:refreshPlayer()
        return
      end
    end

    -- 10) 最后一张救命（已 21 不干预，这里不可能；真实避免爆牌才扣次）
    local lcs = self:relicById('last_card_save')
    if lcs and not lcs._expired and curTotal() > 21 then
      replaceLast(self, mkCard(self, 'A', 'S'))
      self:consumeRelic('last_card_save')
      self:msg('最后一张救命：换成安全牌。', 'warning')
      self:refreshPlayer()
      return
    end

    -- 11) 概率磁铁
    local magnets = {
      { id = 'ten_magnet', p = 0.38, pred = function(c) return BJ.isTenValue(c) end, rank = '10' },
      { id = 'peek_and_chase', p = 0.30, pred = function(c) return BJ.isTenValue(c) end, rank = '10' },
      { id = 'ace_magnet', p = 0.12, pred = function(c) return BJ.isAce(c) end, rank = 'A' },
      { id = 'soft_hand_magnet', p = 0.25, pred = function(c) return BJ.isAce(c) end, rank = 'A' },
    }
    for _, mg in ipairs(magnets) do
      local inst = self:relicById(mg.id)
      if inst and not inst._expired then
        local prob = inst.def.param1 or mg.p
        if self:rchance(prob) then
          replaceLast(self, drawMatching(self, mg.pred, mg.rank, nil))
          self:emit({ kind = 'relic_fx', fx = 'magnet', id = mg.id })
          self:refreshPlayer()
          return
        end
      end
    end
    self:refreshPlayer()
  end

  -- ===================== 激活动作 =====================

  GS.activateRelic = function(self, inst)
    if not inst then return self:fail('invalid_arg') end
    if inst._expired then return self:fail('relic_expired') end
    local d = inst.def
    local fn = d.special and self.specials[d.special]
    if not fn then return true end
    local ok, res = pcall(fn, self, inst, nil)
    if not ok then
      self:msg('遗物执行失败：' .. tostring(res), 'error')
      return self:fail('relic_error')
    end
    if res == false then return self:fail('effect_failed') end
    self:syncRelicAliases()
    return true
  end

  GS.use_relic = function(self, arg)
    local st = self.state
    if st.state ~= 'player' and st.state ~= 'bet' then return self:fail('action_unavailable') end
    local inst = findRelic(self, arg)
    if not inst then return self:fail('invalid_arg') end
    return self:activateRelic(inst)
  end

  GS.toggle_relic = function(self, arg)
    local inst = findRelic(self, arg)
    if not inst then return self:fail('invalid_arg') end
    if inst._expired then return self:fail('relic_expired') end
    local d = inst.def
    if d.special and INSTANT[d.special] then return self:use_relic(arg) end
    if d.trigger ~= 'active' and not ROUND_ACTIVE[inst.id] then
      return self:fail('not_toggleable')
    end
    inst._active = not inst._active
    self:syncRelicAliases()
    if inst._active then
      self:msg(tostring(inst.name or inst.id) .. '：本小局已点亮。', 'info')
    else
      self:msg(tostring(inst.name or inst.id) .. '：已熄灭。', 'info')
    end
    return true
  end

  -- 玩家 Berserker 残卷：25 内不爆
  GS.refreshPlayer = function(self, ...)
    local p = O('refreshPlayer', self, ...)
    local shard = self:relicById('class_berserker_shard')
    if p and shard and not shard._expired and shard._active then
      p.busted = p.total > 25
      if p.is67 or BJ.has67(p.hand) then p.is67 = true; p.busted = false end
    end
    return p
  end

  -- ===================== 下注 =====================

  GS.bet_set = function(self, amount)
    if self:hasRelic('bet_minimizer') then
      local min, max = self:betLimits()
      local v = 50
      if v > max then v = max end
      if v < min then v = min end
      return O('bet_set', self, v)
    end
    return O('bet_set', self, amount)
  end

  GS.bet_confirm = function(self)
    local st = self.state
    if self:hasRelic('bet_syndicate') and st.state == 'bet' and not st.flags.betDoubledThisRound then
      local _, max = self:betLimits()
      local nb = (st.bet or 0) * 2
      if nb > max then nb = max end
      st.bet = nb
      st.flags.betDoubledThisRound = true
    end
    return O('bet_confirm', self)
  end

  -- ===================== 跳过（正确消耗残卷，去掉 rod_lost 误判） =====================

  local function relicSkipRound(self)
    local st = self.state
    if st.state ~= 'bet' and st.state ~= 'player' then return self:fail('action_unavailable') end
    local rider = st.playerClass and st.playerClass.id == 'rider' and (st.playerClass.usesLeft or 0) > 0
    local shardReady = st.shardRiderArmed == true and not st.flags.riderUsedThisRound
    if not (rider or shardReady) then return self:fail('action_unavailable') end
    if st.state == 'player' then
      if (st.bet or 0) > 0 then st.chips = st.chips + st.bet end
      if st.bustBet and st.bustBet.on and (st.bustBet.amount or 0) > 0 then
        st.chips = st.chips + st.bustBet.amount
        st.bustBet.amount = 0; st.bustBet.on = false; st.bustBet.locked = false; st.bustBet.hit = false
      end
    end
    if rider then st.playerClass.usesLeft = (st.playerClass.usesLeft or 0) - 1 end
    if shardReady then st.shardRiderArmed = nil end
    st.flags.riderUsedThisRound = true
    st.result = { outcome = 'push', bet = st.bet, netChange = 0, skipped = true,
                  skippedBy = rider and 'rider_class' or 'rider_shard' }
    self:setState('result')
    self:scheduleAfterRound()
    self:emit({ kind = 'class_fx', fx = 'rider_skip', side = 'player', source = shardReady and 'shard' or 'class' })
    self:msg('跳过本小局，下注已归还。', 'info')
    return true
  end

  GS.skip_round = relicSkipRound
  M._relicSkipRound = relicSkipRound

  -- ===================== 指认（反作弊陷阱） =====================

  GS.accuse = function(self, ...)
    local st = self.state
    local ok, err = O('accuse', self, ...)
    if st.accuseCorrect and self:hasRelic('cheat_trap') then
      st.flags.autoStandNext = true
      self:emit({ kind = 'relic_fx', fx = 'auto_stand_next' })
    end
    return ok, err
  end

  -- ===================== 商店 =====================

  GS.openShopEarly = function(self)
    local st = self.state
    if st.state ~= 'player' and st.state ~= 'bet' then return self:fail('action_unavailable') end
    local inst = self:relicById('mobile_network')
    if not inst or inst._expired then return self:fail('action_unavailable') end
    st._shopReturnState = st.state
    self:consumeRelic('mobile_network')
    self:openShop()
    return true
  end

  GS.leave_shop = function(self, ...)
    local st = self.state
    local ret = st._shopReturnState
    st._shopReturnState = nil
    if ret then
      st.shop = nil
      self:setState(ret)
      return true
    end
    return O('leave_shop', self, ...)
  end

  -- ===================== 标记 =====================

  GS.markCard = function(self, card, explicitUnmark)
    local beforeInk = card and card.marked and card.marked.markId or nil
    local ok, err = O('markCard', self, card, explicitUnmark)
    if ok and card and card.marked then
      local mid = card.marked.markId
      if mid == 'ink' and beforeInk ~= 'ink' then
        local zone = select(1, self:locateCard(card))
        if self:hasRelic('ink_thief') then self:consumeRelic('ink_thief') end
        if self:hasRelic('reveal_ink') and zone ~= 'discard' and zone ~= 'player' then
          self:consumeRelic('reveal_ink')
        end
      elseif card.marked.special then
        local src = self.state.specialMarkSource
        if src then
          self:consumeRelic(src)
          self.state.specialMarkSource = nil
        end
      end
    end
    return ok, err
  end

  GS.mark_card = function(self, arg)
    local st = self.state
    -- 打捞点选
    if st.salvagePending then
      local card = (arg and arg.uid) and self:findCardByUid(arg.uid)
        or (arg and self:findCardInZone(arg.zone or 'discard', arg.index or 1))
      if card then
        local zone = select(1, self:locateCard(card))
        if zone == 'discard' then
          st.salvagePending = false
          st.salvageCard = card
          st.shoeOpen = false
          self:msg('打捞目标已锁定，下次要牌将打出它。', 'info')
          return true
        end
      end
    end
    -- 钓具点选
    if st.rodMode and st.rodRelicId then
      local card = (arg and arg.uid) and self:findCardByUid(arg.uid)
        or (arg and self:findCardInZone(arg.zone or 'shoe', arg.index or 1))
      if card then
        if not card.marked then
          self:msg('钓具只能选择已标记的牌。', 'warning')
          return true
        end
        self:rod_pick({ uid = card.uid })
        if st.rodMode ~= 'swap' then self:rod_confirm() end
        return true
      end
    end
    return O('mark_card', self, arg)
  end

  -- ===================== 钓具 =====================

  local function allMarked(gs)
    local st = gs.state
    local out = {}
    local function scan(list, zone)
      for i = 1, #list do
        if list[i].marked then out[#out + 1] = { card = list[i], zone = zone, index = i } end
      end
    end
    scan(st.deck.drawPile, 'draw'); scan(st.deck.discardPile, 'discard'); scan(st.deck.removed, 'removed')
    scan(st.player.hand, 'player'); scan(st.dealer.hand, 'dealer')
    return out
  end

  local function removeFromZone(gs, card)
    local zone, list, idx = gs:locateCard(card)
    if zone and list and idx then table.remove(list, idx); return zone end
    return nil
  end

  local function applyRod(gs, mode, uid)
    local st = gs.state
    local deck = st.deck
    if mode == 'lost' or mode == 'golden' or mode == 'rogue' then
      local filtered = {}
      for _, it in ipairs(allMarked(gs)) do
        if mode == 'lost' then if it.zone == 'discard' then filtered[#filtered + 1] = it end
        elseif mode == 'golden' then if it.zone == 'draw' then filtered[#filtered + 1] = it end
        else filtered[#filtered + 1] = it end
      end
      if #filtered == 0 then return false, 'no_marked' end
      if mode == 'golden' then
        table.sort(filtered, function(a, b)
          local ao = (a.card.marked and a.card.marked.order) or 99
          local bo = (b.card.marked and b.card.marked.order) or 99
          if ao == bo then return tostring(a.card.uid) < tostring(b.card.uid) end
          return ao < bo
        end)
      end
      for _, it in ipairs(filtered) do removeFromZone(gs, it.card) end
      if mode == 'rogue' then
        for _, it in ipairs(filtered) do
          deck:addToDraw(it.card, gs:rint(1, math.max(1, #deck.drawPile + 1)))
        end
      elseif mode == 'lost' then
        -- 越晚弃的越靠顶：按弃牌堆顺序依次插到顶，最后一张落在 index 1
        for i = 1, #filtered do deck:addToDraw(filtered[i].card, 1) end
      else
        for k = 1, #filtered do deck:addToDraw(filtered[k].card, k) end
      end
      gs:refreshShoe()
      return true
    end
    local card = uid and gs:findCardByUid(uid) or nil
    if not card or not card.marked then return false, 'not_marked' end
    local zone = removeFromZone(gs, card)
    if not zone then return false, 'not_found' end
    if mode == 'deep' then
      deck:addToDraw(card, 'bottom')
    elseif mode == 'standard' then
      deck:addToDraw(card, 1)
    elseif mode == 'trawl' then
      local from = 1
      if zone == 'draw' then
        for i = 1, #deck.drawPile do if deck.drawPile[i] == card then from = i end end
      end
      deck:addToDraw(card, math.max(1, from - 3))
    else
      deck:addToDraw(card, 1)
    end
    gs:refreshShoe()
    return true
  end

  GS.rod_pick = function(self, arg)
    local st = self.state
    local uid = arg and (arg.uid or arg)
    if not uid then return self:fail('invalid_arg') end
    local card = self:findCardByUid(uid)
    if not card or not card.marked then return self:fail('not_marked') end
    if st.rodMode == 'swap' then
      if st.rodFirst then
        local a = self:findCardByUid(st.rodFirst)
        if a and card then
          local _, l1, i1 = self:locateCard(a)
          local _, l2, i2 = self:locateCard(card)
          if l1 and l2 and i1 and i2 then l1[i1] = card; l2[i2] = a end
        end
        st.rodFirst = nil; st.rodSelection = nil
        self:refreshShoe()
        consumeRod(self)
        self:msg('换位钓具：交换完成。', 'info')
        return true
      end
      st.rodFirst = uid
      st.rodSelection = uid
      self:msg('换位钓具：请选择第二张已标记牌。', 'info')
      return true
    end
    st.rodSelection = uid
    return true
  end

  GS.rod_confirm = function(self)
    local st = self.state
    if not st.rodSelection then return self:fail('invalid_arg') end
    if st.rodMode == 'swap' then
      if not st.rodFirst then return self:fail('invalid_arg') end
      return self:rod_pick({ uid = st.rodSelection })
    end
    local ok, err = applyRod(self, st.rodMode, st.rodSelection)
    if not ok then return self:fail(err or 'invalid_arg') end
    consumeRod(self)
    return true
  end

  -- ===================== 回合末 =====================

  GS.finalizeRound = function(self, result, forced)
    local st = self.state
    local r = O('finalizeRound', self, result, forced)
    -- 对冲基金：真实生效才扣次
    if result and st.bustBet and st.bustBet.on and (st.bustBet.amount or 0) > 0 then
      local bb = result.bustBet
      if bb and ((bb.hit) or ((bb.payout or 0) > 0)) and self:hasRelic('hedge_fund') then
        self:consumeRelic('hedge_fund')
      end
    end
    -- 术之残卷：连胜 3 触发替换自身
    local cs = self:relicById('class_caster_shard')
    if cs and not cs._expired and (st.streak or 0) > 0 and (st.streak % 3 == 0) and not st.classOffer then
      local CA = self.classActions
      if CA and CA.openCasterOffer then
        -- 不在此扣次：class_actions 会以 replaceId='class_caster_shard' 用新遗物替换自身；
        -- 若玩家放弃替换，则效果未生效、不扣次。避免“先扣次置 _expired 导致替换查不到目标”。
        CA.openCasterOffer(self, 'caster_shard')
      end
    end
    return r
  end

  GS.relicActions = M
  return true
end

-- 顺序兜底：若 class_actions 在 relic_actions 之后安装并覆盖了 skip_round，调用本函数重新接管。
function M.postInstall(GS)
  if not GS or not M._relicSkipRound then return false end
  GS.skip_round = M._relicSkipRound
  return true
end

return M
