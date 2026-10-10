-- tests/shop_acceptance.lua : 商店 / 经济 / 阶段基础边界验收
-- 契约：require('tests.shop_acceptance') 返回 { run = function() -> report { pass, fail, errors } }
-- 不依赖任何被委派的扩展模块（bar/class/meta/relic_actions），模块安装前后都可跑。
local Game = require('src.game')
local DT = require('src.deck_types')
local Relics = require('src.relics')

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
-- 用固定返回值控制商店里的 rchance 分支（allDecks / 折扣 / 铸造）
local function forceRchance(gs, f) gs.rchance = function(_, p) return f(p) end end
local function priceBase(slot, stage)
  if slot.kind == 'relic' then return Relics.price(slot.def, stage) end
  return DT.price(slot.key, slot.size, stage)
end
local function firstRelic(shelves)
  for i = 1, 4 do
    local s = shelves[i]
    if s and s.kind == 'relic' then return i, s end
  end
  return nil, nil
end

local function build()
  R = { pass = 0, fail = 0, errors = {} }

  -- ============ 开店时机 ============
  check('shop: 每 5 轮开店并归零计数', function()
    local g = started('normal'); local gs = g._g; local st = g.state
    gs:buildShoe()
    st.roundsSinceShop = 5; st.roundsInStage = 1; st.chips = 2500; st.supremeClear = false; st.state = 'result'
    gs:scheduleAfterRound()
    eq(st.afterResult, 'shop')
    gs:continue()
    eq(st.state, 'shop')
    eq(st.roundsSinceShop, 0)
  end)

  check('shop: 恰好 21 额外 +1 且可累加到开店', function()
    local g = started('normal'); local gs = g._g; local st = g.state
    gs:buildShoe()
    st.roundsSinceShop = 0; st.supremeClear = false
    st.player.total = 21; st.player.busted = false
    local r = { outcome = 'player', winnings = 0, netChange = 0, bet = 0 }
    for i = 1, 4 do
      st.roundsInStage = 1; st.state = 'result'
      gs:finalizeRound(r, false)
      eq(st.roundsSinceShop, i)
    end
    st.roundsInStage = 1; st.state = 'result'
    gs:finalizeRound(r, false)
    eq(st.roundsSinceShop, 5)
    eq(st.afterResult, 'shop')
  end)

  check('shop: 酒吧模式 21 不计入', function()
    local g = started('normal'); local gs = g._g; local st = g.state
    gs:buildShoe()
    st.mode = 'bar'; st.roundsSinceShop = 2
    st.player.total = 21; st.player.busted = false
    gs.barAfterRound = function() return 'result' end
    st.state = 'result'
    gs:finalizeRound({ outcome = 'player', winnings = 0, netChange = 0, bet = 0 }, false)
    eq(st.roundsSinceShop, 2)
  end)

  check('shop: 移动网络立刻开店且不结算、离店回原 state', function()
    local g = started('normal'); local gs = g._g; local st = g.state
    gs:buildShoe()
    truthy(gs:addRelic(Relics.byId('mobile_network')), 'add mobile_network')
    st.state = 'player'; st.roundsSinceShop = 3; st.roundsInStage = 4
    truthy(gs.specials.open_shop_early(gs), 'openShopEarly failed: ' .. tostring(st.lastError))
    eq(st.state, 'shop')
    eq(st._shopReturnState, 'player')
    eq(st.roundsSinceShop, 3)   -- 立刻开店不结算，计数不动
    eq(st.roundsInStage, 4)
    truthy(st.shop, 'shop opened')
    truthy(gs:leave_shop(), 'leave_shop')
    eq(st.state, 'player')
    eq(st.shop, nil)
  end)

  -- ============ 货架结构 / 折扣 ============
  check('shop: 1-4 遗物 5 牌组且默认非全牌组', function()
    local g = started('normal'); local gs = g._g
    forceRchance(gs, function() return false end)
    gs:openShop()
    local sh = g.state.shop
    eq(sh.allDecks, false)
    local n = 0
    for i = 1, 4 do truthy(sh.shelves[i], 'shelf ' .. i); eq(sh.shelves[i].kind, 'relic'); n = n + 1 end
    eq(n, 4)
    eq(sh.shelves[5].kind, 'deck')
  end)

  check('shop: 2% 命中时 5 格全牌组', function()
    local g = started('normal'); local gs = g._g
    forceRchance(gs, function(p) return p == 0.02 end)
    gs:openShop()
    local sh = g.state.shop
    eq(sh.allDecks, true)
    for i = 1, 5 do truthy(sh.shelves[i], 'shelf ' .. i); eq(sh.shelves[i].kind, 'deck') end
  end)

  check('shop: 折扣 0.2~0.9 且跟位置不跟商品', function()
    local g = started('normal'); local gs = g._g; local st = g.state
    forceRchance(gs, function(p) return p == 0.5 end)
    gs:openShop()
    local sh = st.shop
    truthy(sh.discountIndex >= 1 and sh.discountIndex <= 5, 'discountIndex')
    truthy(sh.discountFactor >= 0.2 and sh.discountFactor <= 0.9, 'discountFactor=' .. tostring(sh.discountFactor))
    local idx = sh.discountIndex
    local slot = sh.shelves[idx]
    truthy(slot, 'discounted shelf')
    eq(slot.price, math.floor(priceBase(slot, st.stage) * sh.discountFactor))
    st.chips = 500000
    gs:reroll()
    local slot2 = st.shop.shelves[idx]
    truthy(slot2, 'discounted shelf after reroll')
    eq(slot2.price, math.floor(priceBase(slot2, st.stage) * st.shop.discountFactor))
  end)

  -- ============ 刷新 / 购买约束 ============
  check('shop: reroll 200 倍增且售出位保留', function()
    local g = started('normal'); local gs = g._g; local st = g.state
    forceRchance(gs, function() return false end)
    gs:openShop()
    st.chips = 500000
    eq(st.shop.rerollCost, 200)
    local idx = firstRelic(st.shop.shelves)
    truthy(idx, 'relic shelf')
    truthy(gs:buy_relic(idx))
    local boughtId = st.shop.shelves[idx].id
    gs:reroll()
    eq(st.shop.rerollCost, 400)
    eq(st.shop.shelves[idx].sold, true)
    eq(st.shop.shelves[idx].id, boughtId)
    gs:reroll()
    eq(st.shop.rerollCost, 800)
  end)

  check('shop: 重复购买不重复扣款', function()
    local g = started('normal'); local gs = g._g; local st = g.state
    forceRchance(gs, function() return false end)
    gs:openShop()
    st.chips = 500000
    local idx = firstRelic(st.shop.shelves)
    truthy(gs:buy_relic(idx))
    local after = st.chips
    truthy(gs:buy_relic(idx) == false, 'second buy rejected')
    eq(st.chips, after)
  end)

  check('shop: 买不起时状态不变', function()
    local g = started('normal'); local gs = g._g; local st = g.state
    forceRchance(gs, function() return false end)
    gs:openShop()
    st.chips = 0
    local idx = firstRelic(st.shop.shelves)
    truthy(gs:buy_relic(idx) == false)
    eq(st.chips, 0)
    eq(st.shop.shelves[idx].sold, false)
    truthy(gs:buy_deck(5) == false)
    eq(st.shop.shelves[5].sold, false)
  end)

  -- ============ 铸造 ============
  check('shop: 熔炉阶段 1 不出现', function()
    local g = started('normal'); local gs = g._g; local st = g.state
    gs:addRelic(Relics.byId('first_hit_safe'))
    forceRchance(gs, function(p) return p == 0.2 end)
    gs:openShop()
    eq(st.stage, 1)
    eq(st.shop.forgeOffer, nil)
  end)

  check('shop: 熔炉阶段 2 出现一次且列出可铸造目标', function()
    local g = started('normal'); local gs = g._g; local st = g.state
    st.stage = 2
    gs:addRelic(Relics.byId('first_hit_safe'))
    forceRchance(gs, function(p) return p == 0.2 end)
    gs:openShop()
    local fo = st.shop.forgeOffer
    truthy(fo ~= nil and #fo >= 1, 'forgeOffer')
    local found = false
    for i = 1, #fo do if fo[i].id == 'first_hit_safe' and fo[i].kind == 'relic' then found = true end end
    truthy(found, 'consumable relic in forge candidates')
  end)

  check('shop: 熔炉 <10000 拒付且不消耗次数', function()
    local g = started('normal'); local gs = g._g; local st = g.state
    st.stage = 2
    gs:addRelic(Relics.byId('first_hit_safe'))
    forceRchance(gs, function(p) return p == 0.2 end)
    gs:openShop()
    st.chips = 9999
    truthy(gs:open_forge())
    gs:forge_select({ kind = 'relic', id = 'first_hit_safe' })
    truthy(gs:confirm_forge() == false)
    eq(st.shop.forgeUsed, false)
    eq(st.chips, 9999)
    eq(gs:findRelic('first_hit_safe')._forged, false)
  end)

  check('shop: 熔炉消耗遗物永久化且每店一次', function()
    local g = started('normal'); local gs = g._g; local st = g.state
    st.stage = 2
    gs:addRelic(Relics.byId('first_hit_safe'))
    forceRchance(gs, function(p) return p == 0.2 end)
    gs:openShop()
    st.chips = 500000
    truthy(gs:open_forge())
    gs:forge_select({ kind = 'relic', id = 'first_hit_safe' })
    truthy(gs:confirm_forge())
    local inst = gs:findRelic('first_hit_safe')
    eq(inst._forged, true)
    eq(inst._consumable, false)
    eq(inst._usesLeft, nil)
    eq(st.shop.forgeUsed, true)
    local chipsAfter = st.chips
    eq(chipsAfter, 500000 - 10000)
    truthy(gs:confirm_forge() == false)
    eq(st.chips, chipsAfter)
  end)

  check('shop: 熔炉特种标记永久化', function()
    local g = started('normal'); local gs = g._g; local st = g.state
    st.stage = 2
    st.specialMarks.held = { id = 'mark_vanish', name = '消失标记', forged = false, usesLeft = 3, special = true }
    forceRchance(gs, function(p) return p == 0.2 end)
    gs:openShop()
    st.chips = 500000
    truthy(gs:open_forge())
    gs:forge_select({ kind = 'mark' })
    truthy(gs:confirm_forge())
    eq(st.specialMarks.held.forged, true)
    eq(st.specialMarks.held.usesLeft, nil)
  end)

  -- ============ 信用 / 负筹码 ============
  check('shop: 信用额度 = 2× 筹码', function()
    local g = started('normal'); local gs = g._g; local st = g.state
    gs:addRelic(Relics.byId('credit_line'))
    st.chips = 100
    local _, max, credit = gs:betLimits()
    eq(credit, 200); eq(max, 300)
  end)

  check('shop: 赌徒信条 = 3× 筹码', function()
    local g = started('normal'); local gs = g._g; local st = g.state
    gs:addRelic(Relics.byId('all_in_fanatic_rel'))
    st.chips = 100
    local _, max, credit = gs:betLimits()
    eq(credit, 300); eq(max, 400)
  end)

  check('shop: 豪客特权固定 +5000', function()
    local g = started('normal'); local gs = g._g; local st = g.state
    gs:addRelic(Relics.byId('high_roller'))
    st.chips = 100
    local _, max, credit = gs:betLimits()
    eq(credit, 5000); eq(max, 5100)
  end)

  check('shop: 多件信用取最大不叠加', function()
    local g = started('normal'); local gs = g._g; local st = g.state
    gs:addRelic(Relics.byId('credit_line'))
    gs:addRelic(Relics.byId('high_roller'))
    st.chips = 100
    local _, max, credit = gs:betLimits()
    eq(credit, 5000); eq(max, 5100)
  end)

  check('shop: 负筹码与 autoEndOnBroke', function()
    local g = started('normal'); local gs = g._g; local st = g.state
    st.chips = -500
    local _, max = gs:betLimits()
    eq(max, 1)
    st.roundsInStage = 1; st.roundsSinceShop = 0; st.supremeClear = false; st.stage = 1; st.state = 'result'
    gs.settings.autoEndOnBroke = true
    gs:scheduleAfterRound(); eq(st.afterResult, 'forceExit')
    gs.settings.autoEndOnBroke = false
    gs:scheduleAfterRound(); eq(st.afterResult, 'result')
  end)

  -- ============ 阶段边界 ============
  check('stage: 21 至尊奖励等于阶段目标且不占本局计数', function()
    local g = started('normal'); local gs = g._g; local st = g.state
    st.roundsInStage = 3
    local ctx = { gs = gs, player = { total = 21 }, score = { chips = 0, breakdown = {} } }
    gs.scoreHandlers.stage_win(ctx)
    eq(st.supremeClear, true)
    eq(ctx.score.chips, st.stageTarget)
    eq(st.roundsInStage, 2)
  end)

  check('stage: 阶段 1/2 未跑满不晋级（即使筹码达标）', function()
    local g = started('normal'); local gs = g._g; local st = g.state
    st.chips = 9999999; st.roundsInStage = 1; st.roundsSinceShop = 0; st.supremeClear = false
    st.stage = 1; st.state = 'result'
    gs:scheduleAfterRound()
    eq(st.afterResult, 'result')
  end)

  check('stage: 跑满 15 局且达标则晋级', function()
    local g = started('normal'); local gs = g._g; local st = g.state
    st.chips = st.stageTarget; st.roundsInStage = 15; st.roundsSinceShop = 0; st.supremeClear = false
    st.stage = 1; st.state = 'result'
    gs:scheduleAfterRound()
    eq(st.afterResult, 'stageClear')
  end)

  check('stage: 跑满 15 局未达标则退出', function()
    local g = started('normal'); local gs = g._g; local st = g.state
    st.chips = 100; st.roundsInStage = 15; st.roundsSinceShop = 0; st.supremeClear = false
    st.stage = 1; st.state = 'result'
    gs:scheduleAfterRound()
    eq(st.afterResult, 'forceExit')
  end)

  check('stage: 阶段 3 即时达标并通关', function()
    local g = started('normal'); local gs = g._g; local st = g.state
    st.stage = 3; st.stageTarget = 2000000; st.chips = 2000000
    st.roundsInStage = 1; st.roundsSinceShop = 0; st.supremeClear = false; st.state = 'result'
    gs:scheduleAfterRound()
    eq(st.afterResult, 'stageClear')
    gs:continue(); eq(st.state, 'stageClear')
    gs:continue(); eq(st.state, 'victory')
  end)
  -- ============ 删除牌组底线保护（GDD §16.2 / §16.5） ============
  check('deck: 固有牌堆 = 阶段套数 × 52', function()
    local g = started('normal'); local gs = g._g; local st = g.state
    st.stage = 1; eq(gs:inherentDeckTotal(), 52)
    st.stage = 2; eq(gs:inherentDeckTotal(), 104)
    st.stage = 3; eq(gs:inherentDeckTotal(), 156)
  end)

  check('deck: 阶段 1（固有 1 套）不提供删除牌组', function()
    local g = started('normal'); local gs = g._g; local st = g.state
    st.stage = 1
    for i = 1, 200 do
      local s = gs:rollShopSlot('deck')
      truthy(s and s.kind == 'deck', 'deck slot')
      if s.key == 'remove' then error('stage1 offered remove') end
    end
  end)

  check('deck: 已删到剩 1 张时不再提供且购买被拒绝（含叠加与新店）', function()
    local g = started('normal'); local gs = g._g; local st = g.state
    st.stage = 2
    gs:buildShoe()
    st.removedDeckIds = {}
    for i = 1, 34 do st.removedDeckIds[#st.removedDeckIds + 1] = { key = 'remove', size = 'large' } end
    eq(gs:removedBasicCount(), 102)   -- 104 - 102 = 剩 2 张
    -- 确定性检查池过滤：让 rpick 优先返回 remove（仅当它在池中时）
    local oldPick = gs.rpick
    gs.rpick = function(_, list) for i = 1, #list do if list[i] == 'remove' then return 'remove' end end return list[1] end
    eq(gs:rollShopSlot('deck').key, 'remove', 'remaining 2 should still offer remove')
    st.state = 'shop'; st.chips = 1000
    st.shop = { shelves = { { kind = 'deck', key = 'remove', size = 'small', name = '删除牌组', price = 10, sold = false } }, rerollCost = 200 }
    truthy(gs:buy_deck(1))
    eq(gs:removedBasicCount(), 103)   -- 剩 1 张
    st.shop.shelves[1] = { kind = 'deck', key = 'remove', size = 'small', name = '删除牌组', price = 10, sold = false }
    eq(gs:buy_deck(1), false)
    eq(st.lastError, 'empty_deck')
    eq(gs:removedBasicCount(), 103)
    eq(st.chips, 990)
    local s1 = gs:rollShopSlot('deck')
    truthy(s1 and s1.key ~= 'remove', 'remaining 1 should not offer remove')
    gs.rpick = oldPick
  end)

  -- ============ 特种标记商品（markDot）不占遗物栏（GDD §12.2 / §16.5） ============
  check('markDot: 买特种标记进单格库存、不占遗物栏且满栏可买、重复购买替换', function()
    local g = started('normal'); local gs = g._g; local st = g.state
    gs:buildShoe()
    st.relics = {}; st.relicSlotMax = 5
    local filler = { 'stage_survivor', 'debt_collector', 'mind_memory', 'sharp_family', 'hedge_fund' }
    for i = 1, 5 do truthy(gs:addRelic(Relics.byId(filler[i])), 'filler ' .. filler[i]) end
    eq(#gs:activeRelics(), 5)
    local flame = Relics.byId('mark_flame')
    st.state = 'shop'; st.chips = 10000
    st.shop = { shelves = { { kind = 'relic', def = flame, id = flame.id, name = flame.name, price = Relics.price(flame, st.stage), sold = false } }, rerollCost = 200 }
    truthy(gs:buy_relic(1))
    truthy(st.specialMarks and st.specialMarks.held, 'held mark')
    eq(st.specialMarks.held.id, 'mark_flame')
    eq(st.specialMarks.held.usesLeft, 3)
    eq(#gs:activeRelics(), 5)   -- 未占用遗物栏
    eq(st.chips, 10000 - Relics.price(flame, st.stage))
    local void = Relics.byId('mark_void')
    st.shop.shelves[1] = { kind = 'relic', def = void, id = void.id, name = void.name, price = Relics.price(void, st.stage), sold = false }
    truthy(gs:buy_relic(1))
    eq(st.specialMarks.held.id, 'mark_void')   -- 同时只持一枚：直接替换
    eq(#gs:activeRelics(), 5)
  end)

  check('markDot: 普通遗物满栏时仍拒绝（不误伤原规则）', function()
    local g = started('normal'); local gs = g._g; local st = g.state
    gs:buildShoe()
    st.relics = {}; st.relicSlotMax = 5
    local filler = { 'stage_survivor', 'debt_collector', 'mind_memory', 'sharp_family', 'hedge_fund' }
    for i = 1, 5 do gs:addRelic(Relics.byId(filler[i])) end
    local normal = Relics.byId('ink_thief')
    st.state = 'shop'; st.chips = 10000
    st.shop = { shelves = { { kind = 'relic', def = normal, id = normal.id, name = normal.name, price = Relics.price(normal, st.stage), sold = false } }, rerollCost = 200 }
    eq(gs:buy_relic(1), false)
    eq(st.lastError, 'relic_slots_full')
    eq(st.chips, 10000)
  end)

  check('markDot: 开局三选一池排除商店专属六个组', function()
    local g = started('normal'); local gs = g._g
    local out = gs:rollRelicChoices(20, true)
    for i = 1, #out do
      truthy(not gs:isShopOnlyRelic(out[i].def), 'shop-only leaked: ' .. tostring(out[i].def and out[i].def.id))
    end
  end)

  return R
end

local modname = ...
if modname == nil then
  local rep = build()
  print(string.format('shop_acceptance: PASS=%d FAIL=%d', rep.pass, rep.fail))
  if rep.fail > 0 then
    for i = 1, #rep.errors do print('  FAIL ' .. rep.errors[i]) end
    error('shop_acceptance failed: ' .. rep.fail)
  end
end
return { run = build }
