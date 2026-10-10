-- tools/class_acceptance.lua
-- 职阶独立验收：玩家 7 职阶 + 困难模式庄家 7 职阶。
-- 全部走真实动作/真实刷新；注入内存文件系统与确定性 RNG，不碰正式存档。
-- 运行：python tools/run_lua.py tools/class_acceptance.lua
local Game = require('src.game')
local GS = require('src.game_state')
local AC = require('src.class_actions')
local Classes = require('src.classes')
local Relics = require('src.relics')
local Deck = require('src.deck')
local DT = require('src.deck_types')
local BJ = require('src.blackjack')

local pass, failures = 0, {}
local function check(name, fn)
  local ok, err = pcall(fn)
  if ok then
    pass = pass + 1
    print('PASS ' .. name)
  else
    failures[#failures + 1] = name .. ': ' .. tostring(err)
    print('FAIL ' .. failures[#failures])
  end
end
local function eq(a, b, msg)
  assert(a == b, tostring(msg or '') .. ' expected=' .. tostring(b) .. ' got=' .. tostring(a))
end
local function is_true(v, msg) assert(v == true, tostring(msg or '') .. ' expected true got ' .. tostring(v)) end
local function is_false(v, msg) assert(v == false, tostring(msg or '') .. ' expected false got ' .. tostring(v)) end
local function not_nil(v, msg) assert(v ~= nil, tostring(msg or '') .. ' is nil') end

local function memfs()
  local files = {}
  return files, {
    read = function(p) return files[p] end,
    write = function(p, v) files[p] = v; return true end,
    mkdir = function() return true end,
    getInfo = function(p) return files[p] and { type = 'file' } or nil end,
  }
end

local function makeRng(seed)
  local s = seed or 20240617
  return function(a, b)
    s = (s * 1103515245 + 12345) % 2147483648
    local v = s / 2147483648
    if a ~= nil then
      b = b or a
      return a + math.floor(v * (b - a + 1))
    end
    return v
  end
end

local function S(g) return g._g.state end
local function mk(rank, suit) return DT.mk({ rank = rank, suit = suit, kind = 'basic', is_basic = true }) end
local function mk67(rank) return DT.mk({ rank = rank, suit = 'C', kind = 's67', is_67 = true, s67_rank = rank }) end

-- 安装一次（幂等），之后所有游戏共享
is_true(AC.install(GS), 'install')

-- 开局到困难模式（会进入 relic_select）；由调用者接管阶段与职阶
local function freshGame(seed)
  local _, fs = memfs()
  local g = Game.new({ filesystem = fs, rng = makeRng(seed or 424242) })
  g:action('select_mode', 'hard')
  return g
end

-- 构造可控对局：设定阶段/双方职阶后真实 beginBet（进入 bet）
local function round(pc, dc, stage, seed)
  local g = freshGame(seed)
  local st = S(g)
  st.stage = stage or 1
  st.playerClass = pc and Classes.getRuntime(pc) or nil
  st.class = st.playerClass
  st.dealerClass = dc and Classes.dealerRuntime(dc) or nil
  g:beginBet()
  return g, st
end

-- 替换牌靴为可控牌序（drawPile[1] 为顶）
local function setDeck(st, cards)
  local d = Deck.new()
  d.drawPile = cards
  st.deck = d
  return d
end

local function clearHand(hand)
  for i = #hand, 1, -1 do hand[i] = nil end
end

-- 直接摆牌并刷新
local function setHands(g, st, pSpecs, dSpecs)
  clearHand(st.player.hand)
  clearHand(st.dealer.hand)
  for i, s in ipairs(pSpecs or {}) do st.player.hand[i] = mk(s[1], s[2]) end
  for i, s in ipairs(dSpecs or {}) do st.dealer.hand[i] = mk(s[1], s[2]) end
  g:refreshPlayer(); g:refreshDealer()
end

-- ===================== 剑阶 Saber =====================
check('saber(player): 结算前斩庄家最小牌(A=1)+真实弃牌+只斩一次', function()
  local g, st = round('saber', nil, 1)
  setDeck(st, {})
  setHands(g, st, { { '9', 'C' }, { '8', 'D' } }, { { '10', 'H' }, { '6', 'S' } })
  local before = #st.deck.discardPile
  local outcome = g:collectFinalResult()
  eq(outcome, 'player', '斩掉6后玩家胜')
  eq(#st.dealer.hand, 1, '庄家剩1张')
  eq(BJ.cardValue(st.dealer.hand[1]), 10, '庄家剩10')
  eq(#st.deck.discardPile, before + 1, '弃牌堆+1')
  eq(st.deck.discardPile[#st.deck.discardPile].rank, '6', '弃掉的是6')
  is_true(st.classEffect.saberPlayer, '本回合已斩标记')
  g:collectFinalResult()
  eq(#st.dealer.hand, 1, '第二次结算不重复斩')
end)

check('saber(player): A 记 1 为最小牌被斩', function()
  local g, st = round('saber', nil, 1)
  setDeck(st, {})
  setHands(g, st, { { '10', 'C' }, { '10', 'D' } }, { { 'A', 'H' }, { 'K', 'S' } })
  local outcome = g:collectFinalResult()
  eq(outcome, 'player', '庄家A被斩后仅K')
  eq(#st.dealer.hand, 1, '庄家1张')
  eq(st.dealer.hand[1].rank, 'K', '留下K')
end)

check('saber(dealer): 庄家剑阶斩玩家最小牌', function()
  local g, st = round(nil, 'saber', 1)
  setDeck(st, {})
  setHands(g, st, { { '5', 'C' }, { '10', 'D' } }, { { '10', 'H' }, { '9', 'S' } })
  local outcome = g:collectFinalResult()
  eq(outcome, 'dealer', '玩家被斩后10<19')
  eq(#st.player.hand, 1, '玩家1张')
  eq(st.deck.discardPile[#st.deck.discardPile].rank, '5', '弃掉5')
  is_true(st.classEffect.saberDealer, '庄家斩标记')
end)

-- ===================== 弓阶 Archer =====================
check('archer(player): 预览牌靴顶不抽牌/不动牌靴/不消耗随机数', function()
  local g, st = round(nil, nil, 1)
  local top = mk('7', 'H')
  setDeck(st, { top, mk('9', 'S') })
  local n = #st.deck.drawPile
  local calls = 0
  local oldRng = g.rng
  g.rng = function(...) calls = calls + 1; return oldRng(...) end
  local c = AC.archerPreview(g, 'class')
  g.rng = oldRng
  eq(calls, 0, '预览不消耗随机数')
  is_true(c == top, '返回顶牌')
  eq(#st.deck.drawPile, n, '牌靴未减少')
  is_true(st.deck.drawPile[1] == top, '顶牌仍在原位')
  eq(st.classPreview.player.card, top, '写入预览信息')
end)

check('archer(player): 发牌后第一张带 _peek 且与预览一致', function()
  local g, st = round('archer', nil, 1)
  local p1 = mk('5', 'H')
  setDeck(st, { p1, mk('9', 'S'), mk('10', 'D'), mk('6', 'C'), mk('2', 'H') })
  g:dealInitial()
  is_true(st.player.hand[1] == p1, '第一张就是预览牌')
  is_true(p1._peek == true, '标记 _peek')
  is_true(st.player._archerPeek == true, '玩家预览已揭示')
end)

check('archer(dealer): 庄家用读玩家点数的 AI=3 且看到玩家首牌', function()
  local g, st = round(nil, 'archer', 1)
  eq(st.dealer.difficulty, 3, '庄家弓 AI=3')
  local p1 = mk('8', 'H')
  setDeck(st, { p1, mk('9', 'S'), mk('10', 'D'), mk('6', 'C') })
  g:dealInitial()
  is_true(st.dealer._archerPreview == st.player.hand[1], '庄家看到玩家首牌')
end)

-- ===================== 术阶 Caster =====================
local function pickSeedRelic()
  for _, d in ipairs(Relics.all()) do
    if not Relics.isPoolExcluded(d) and not Classes.isShard(d.id) then return d end
  end
  return Relics.all()[1]
end

check('caster(player): 3 连胜开启 3 选 1，两阶段替换且槽位数不变', function()
  local g, st = round('caster', nil, 1)
  local seedDef = pickSeedRelic()
  is_true(g:addRelic(seedDef), '预置一件遗物')
  local slots = #g:activeRelics()
  st.streak = 2 -- 本局胜利后累计到 3
  st.chips = 2500
  st.roundsInStage = 0
  st.roundsSinceShop = 0
  st.state = 'result'
  g:finalizeRound({ outcome = 'player', bet = 10, netChange = 0, winnings = 0 })
  eq(st.state, 'classOffer', '进入术阶弹层')
  eq(st.classOffer.purpose, 'caster_replace', '用途')
  eq(#st.classOffer.candidates, 3, '3 个候选')
  -- pick 阶段
  is_true(g:action('take_class_offer', 1), '选择候选')
  eq(st.classOffer.phase, 'target', '进入目标阶段')
  eq(#st.classOffer.candidates, slots, '候选改为可替换遗物')
  -- target 阶段（同一动作名，index 即目标槽位）
  is_true(g:action('take_class_offer', 1), '选择替换目标')
  eq(st.state, 'result', '替换后回到 result')
  eq(st.classOffer, nil, '弹层关闭')
  eq(#g:activeRelics(), slots, '槽位数不变')
end)

check('caster(player): 候选互不重复且跳过回到原状态', function()
  local g, st = round('caster', nil, 1)
  is_true(g:addRelic(pickSeedRelic()), '预置遗物')
  st.streak = 2 -- 本局胜利后累计到 3
  st.state = 'result'
  g:finalizeRound({ outcome = 'player', bet = 10, netChange = 0, winnings = 0 })
  eq(st.state, 'classOffer')
  local seen = {}
  for _, c in ipairs(st.classOffer.candidates) do
    is_false(seen[c.id] == true, '候选不重复 ' .. tostring(c.id))
    seen[c.id] = true
  end
  is_true(g:action('skip_class_offer'), '跳过')
  eq(st.state, 'result', '跳过回到 result')
  eq(st.classOffer, nil, '弹层关闭')
end)

check('caster(dealer): 每 3 连胜夺 1 件、上限 5、玩家 -n 庄家 +floor(n/2)', function()
  local g, st = round(nil, 'caster', 1)
  st.chips = 2500
  st.roundsInStage = 0
  st.roundsSinceShop = 0
  st.state = 'result'
  for _ = 1, 3 do
    g:finalizeRound({ outcome = 'dealer', bet = 0, netChange = 0, winnings = 0 })
  end
  eq(#st.dealerClass.relics, 1, '3 连败给庄家术阶 1 件')
  for _ = 1, 8 do AC.dealerCasterGain(g) end
  eq(#st.dealerClass.relics, AC.CASTER_DEALER_CAP, '封顶 5 件')
  setHands(g, st, { { '10', 'C' }, { '10', 'D' } }, { { '10', 'S' }, { '10', 'H' } })
  st.classEffect = { casterDebuff = 2 }
  g:refreshPlayer(); g:refreshDealer()
  eq(st.player.total, 18, '玩家 -2')
  eq(st.dealer.total, 21, '庄家 +1')
end)

check('caster(dealer): 玩家点数最低钳制到 2 点（GDD 1745）', function()
  local g, st = round(nil, 'caster', 1)
  setHands(g, st, { { 'A', 'C' }, { '2', 'D' } }, { { '10', 'S' }, { '10', 'H' } })
  local before = st.player.total
  is_true(before > 2, '基线大于 2')
  st.classEffect = { casterDebuff = 100 }
  g:refreshPlayer()
  eq(st.player.total, 2, '无论 debuff 多大，玩家点数不低于 2')
end)

-- ===================== 骑阶 Rider =====================
check('rider: player 状态跳过归还注码+边注并消耗一次', function()
  local g, st = round('rider', nil, 1)
  eq(st.playerClass.usesLeft, 3, '初始 3 次')
  st.state = 'player'
  st.bet = 100
  st.chips = 2350
  st.bustBet.on = true; st.bustBet.amount = 50; st.bustBet.locked = true
  is_true(g:skip_round(), '跳过成功')
  eq(st.chips, 2500, '2350+100+50 全额归还')
  eq(st.playerClass.usesLeft, 2, '消耗一次')
  eq(st.state, 'result', '进入结算')
  is_true(st.result.skipped, '标记跳过')
  is_false(st.bustBet.on, '边注关闭')
end)

check('rider: bet 状态跳过不产生幻影归还但消耗次数', function()
  local g, st = round('rider', nil, 1)
  eq(st.state, 'bet', '处于下注阶段')
  local chips0 = st.chips
  is_true(g:skip_round(), '跳过成功')
  eq(st.chips, chips0, '未扣注不得归还')
  eq(st.playerClass.usesLeft, 2, '跳过本局消耗次数')
  eq(st.state, 'result')
end)

check('rider: 次数耗尽后不可再跳', function()
  local g, st = round('rider', nil, 1)
  st.playerClass.usesLeft = 0
  is_false(g:skip_round(), '无次数则失败')
end)

check('rider 残卷: 未点亮不可跳过（必须 st.shardRiderArmed，不凭持有遗物）', function()
  local g, st = round(nil, nil, 1)
  is_true(g:addRelic(Relics.byId('class_rider_shard')), '加入骑之残卷')
  is_false(g:skip_round(), 'st.shardRiderArmed 未置时不可跳')
end)

check('rider 残卷: relic 点亮置 st.shardRiderArmed；跳成功清 nil 且本模块不扣次', function()
  local g, st = round(nil, nil, 1)
  is_true(g:addRelic(Relics.byId('class_rider_shard')), '加入骑之残卷')
  local inst = g:relicById('class_rider_shard')
  local uses0 = inst._usesLeft
  -- relic_actions 点亮时：consumeRelic 已扣一次，并置 st.shardRiderArmed=true
  st.shardRiderArmed = true
  is_true(g:skip_round(), 'arm 后可跳')
  eq(st.result.skippedBy, 'rider_shard', '来源为残卷')
  eq(st.shardRiderArmed, nil, '跳成功清空 arm')
  eq(inst._usesLeft, uses0, '本模块不重复扣次（点亮时 relic 已扣）')
  is_false(g:skip_round(), '同一小局第二次跳失败')
end)

check('rod_lost 不再允许 R 跳过（GDD §12.4：只移动已标记牌）', function()
  local g, st = round(nil, nil, 1)
  is_true(g:addRelic(Relics.byId('rod_lost')), '加入遗弃钓具')
  is_false(g:skip_round(), 'rod_lost 不提供跳过')
end)

-- ===================== 枪阶 Lancer =====================
check('lancer(player): 第三张会爆时收回顶牌、真实不爆', function()
  local g, st = round('lancer', nil, 1)
  local c5 = mk('5', 'H')
  setDeck(st, { mk('10', 'H'), mk('10', 'S'), mk('6', 'D'), mk('6', 'C'), c5 })
  g:dealInitial()
  eq(#st.player.hand, 2, '爆牌第三张被收回')
  eq(st.player.total, 20, '收回后不爆')
  is_true(st.deck.drawPile[1] == c5, '收回的牌回到牌靴顶')
end)

check('lancer(player): 第三张不爆时保留为 3 张', function()
  local g, st = round('lancer', nil, 1)
  setDeck(st, { mk('10', 'H'), mk('9', 'S'), mk('6', 'D'), mk('6', 'C'), mk('2', 'H') })
  g:dealInitial()
  eq(#st.player.hand, 3, '保留第三张')
  eq(st.player.total, 21, '合计 21')
end)

check('lancer(dealer): 第三张爆牌被弃、22~25 不算爆', function()
  local g, st = round(nil, 'lancer', 1)
  local c5 = mk('5', 'C')
  setDeck(st, { mk('5', 'H'), mk('5', 'S'), mk('10', 'H'), mk('10', 'S'), c5 })
  g:dealInitial()
  eq(#st.dealer.hand, 2, '庄家第三张爆牌被处理')
  is_true(st.deck.discardPile[#st.deck.discardPile] == c5, '爆牌进弃牌堆')
  clearHand(st.dealer.hand)
  st.dealer.hand[1] = mk('10', 'H'); st.dealer.hand[2] = mk('10', 'S'); st.dealer.hand[3] = mk('5', 'C')
  g:refreshDealer()
  eq(st.dealer.total, 25, '庄家 25')
  is_false(st.dealer.busted, '枪阶 25 不爆')
end)

-- ===================== 狂阶 Berserker =====================
check('berserker(player): 25 内不爆且比庄家大判胜', function()
  local g, st = round('berserker', nil, 1)
  setHands(g, st, { { '10', 'C' }, { '10', 'D' }, { '5', 'H' } }, { { '10', 'S' }, { '10', 'H' } })
  eq(st.player.total, 25, '玩家 25')
  is_false(st.player.busted, '狂阶 25 不爆')
  eq(g:collectFinalResult(), 'player', '25>=20 判玩家胜')
end)

check('berserker(player): 22 vs 23 判庄家、22 vs Lancer 22 保留基础 push', function()
  local g, st = round('berserker', nil, 1)
  setHands(g, st, { { '10', 'C' }, { '10', 'D' }, { '2', 'H' } }, { { '10', 'S' }, { '10', 'H' }, { '3', 'C' } })
  eq(st.player.total, 22); eq(st.dealer.total, 23)
  eq(g:collectFinalResult(), 'dealer', '22<23 判庄家')
  -- 同点要成立需要庄家不爆：普通庄家 22 已爆（基础判玩家），改用可容忍 22~25 的 Lancer
  st.dealerClass = Classes.dealerRuntime('lancer')
  clearHand(st.dealer.hand)
  st.dealer.hand[1] = mk('10', 'S'); st.dealer.hand[2] = mk('10', 'H'); st.dealer.hand[3] = mk('2', 'C')
  g:refreshDealer()
  eq(st.dealer.total, 22); is_false(st.dealer.busted, 'Lancer 22 不爆')
  eq(g:collectFinalResult(), 'push', '22=22 同点保留基础 push（严格比庄家大才胜）')
end)

check('berserker(player): 严格「比庄家大」才胜；庄家狂强制平赢除外', function()
  local g, st = round('berserker', nil, 1)
  -- 玩家 24 vs 普通庄家 23 → 玩家胜
  setHands(g, st, { { '10', 'C' }, { '10', 'D' }, { '4', 'H' } }, { { '10', 'S' }, { '10', 'H' }, { '3', 'C' } })
  eq(st.player.total, 24); eq(st.dealer.total, 23)
  eq(g:collectFinalResult(), 'player', '24>23 判玩家')
  -- 玩家 24 vs 庄家 Lancer 24（Lancer 可容忍 22~25 不爆）→ 同点 push
  st.dealerClass = Classes.dealerRuntime('lancer')
  clearHand(st.dealer.hand)
  st.dealer.hand[1] = mk('10', 'S'); st.dealer.hand[2] = mk('10', 'H'); st.dealer.hand[3] = mk('4', 'C')
  g:refreshDealer()
  eq(st.dealer.total, 24); is_false(st.dealer.busted, 'Lancer 24 不爆')
  eq(g:collectFinalResult(), 'push', '24=24 同点保留 push')
  -- 玩家 24 vs 庄家 Berserker 24 → 庄家狂「不比玩家小即庄家」
  st.dealerClass = Classes.dealerRuntime('berserker')
  g:refreshDealer()
  eq(g:collectFinalResult(), 'dealer', '庄家狂平局强制庄家')
end)

check('berserker(player): 67 优先于庄家狂阶强制', function()
  local g, st = round('berserker', 'berserker', 1)
  clearHand(st.player.hand)
  st.player.hand[1] = mk67('6'); st.player.hand[2] = mk67('7'); st.player.hand[3] = mk('10', 'H')
  clearHand(st.dealer.hand)
  st.dealer.hand[1] = mk('10', 'S'); st.dealer.hand[2] = mk('10', 'H'); st.dealer.hand[3] = mk('5', 'C')
  g:refreshPlayer(); g:refreshDealer()
  is_true(st.player.is67, '识别 67')
  eq(g:collectFinalResult(), 'player', '67 强制玩家胜')
end)

check('berserker(dealer): 22~25 不小于玩家即判庄家（含平局）', function()
  local g, st = round(nil, 'berserker', 1)
  setHands(g, st, { { '10', 'C' }, { '10', 'D' } }, { { '10', 'S' }, { '10', 'H' }, { '5', 'C' } })
  eq(st.dealer.total, 25); is_false(st.dealer.busted, '庄家狂阶 25 不爆')
  eq(g:collectFinalResult(), 'dealer', '20<25 庄家胜')
  setHands(g, st, { { '10', 'C' }, { '10', 'D' }, { '5', 'H' } }, { { '10', 'S' }, { '10', 'H' }, { '5', 'C' } })
  eq(st.player.total, 25); eq(st.dealer.total, 25)
  eq(g:collectFinalResult(), 'dealer', '平局 25 判庄家（不比玩家小）')
end)

-- ===================== 杀阶 Assassin =====================
check('assassin: 屏蔽 A/E 读牌千招', function()
  local g, st = round('assassin', nil, 2)
  is_true(g:isCheatShielded(), '杀阶免疫')
  local oldR, oldW = g.rchance, g.rweighted
  g.rchance = function() return true end
  g.rweighted = function() return 'A' end
  local intent = g:decideCheat()
  g.rchance = oldR; g.rweighted = oldW
  is_true(intent.shielded, 'A 被屏蔽')
  eq(intent.move, nil, '未执行')
  eq(st.cheatTrace, nil, '无痕迹')
  g.rchance = function() return true end
  g.rweighted = function() return 'E' end
  local intent2 = g:decideCheat()
  g.rchance = oldR; g.rweighted = oldW
  is_true(intent2.shielded, 'E 被屏蔽')
end)

check('assassin: 仅普通职阶不免疫；无职阶不免疫', function()
  local g = freshGame(777)
  local st = S(g)
  st.playerClass = Classes.getRuntime('saber'); st.class = st.playerClass
  is_false(g:isCheatShielded(), 'Saber 不免疫')
end)

-- ===================== 残卷查询 helper =====================
check('残卷 helper: anyPlayerClass 识别点亮残卷，isPlayerClass 只认职阶', function()
  local g = freshGame(888)
  local st = S(g)
  st.playerClass = nil; st.class = nil
  is_true(g:addRelic(Relics.byId('class_saber_shard')), '获得剑之残卷')
  g:relicById('class_saber_shard')._active = true
  is_true(AC.anyPlayerClass(g, 'saber'), '残卷点亮可查询')
  is_false(AC.isPlayerClass(g, 'saber'), '但内部效果不认残卷')
end)

-- ===================== 庄家职阶：开局/换阶段 =====================
check('hard 开局：阶段 1 也有庄家职阶', function()
  local g = freshGame(2024)
  local dc = S(g).dealerClass
  not_nil(dc, '庄家职阶')
  not_nil(dc.id, '职阶 id')
end)

check('dealerClassForStage：永远不同于上一个', function()
  local g = freshGame(555)
  local prevs = { nil, 'saber', 'lancer', 'archer', 'rider', 'caster', 'assassin', 'berserker' }
  for _, prev in ipairs(prevs) do
    for _ = 1, 40 do
      local dc = AC.dealerClassForStage(g, prev)
      not_nil(dc, '返回职阶')
      if prev then is_false(dc.id == prev, '不能与上一个相同') end
    end
  end
end)

check('advanceStage 1->2：庄家职阶换成不同职阶', function()
  local g = freshGame(333)
  local st = S(g)
  st.stage = 1
  st.playerClass = Classes.getRuntime('saber'); st.class = st.playerClass
  local prev = st.dealerClass.id
  g:advanceStage()
  eq(st.stage, 2, '进入阶段 2')
  is_false(st.dealerClass.id == prev, '庄家职阶必须不同')
end)

check('finishClassFlow 2->3：庄家职阶不同于阶段 2 并进入下注', function()
  local g = freshGame(444)
  local st = S(g)
  st.stage = 2
  st.playerClass = Classes.getRuntime('caster'); st.class = st.playerClass
  st.dealerClass = Classes.dealerRuntime('saber')
  st.classOffer = { mode = 'classOffer', purpose = 'caster_replace', phase = 'pick', candidates = {}, resumeState = 'result' }
  g:finishClassFlow()
  eq(st.stage, 3, '进入阶段 3')
  eq(st.state, 'bet', '进入下注')
  is_false(st.dealerClass.id == 'saber', '庄家职阶不同')
  eq(st.classOffer, nil, '清空弹层')
end)

-- ===================== 安装/兼容 =====================
check('install 幂等且导出 GS.classActions', function()
  is_true(AC.install(GS), '重复安装返回 true')
  is_true(GS.__classActionsV1, '安装守卫')
  is_true(GS.classActions == AC, '导出模块')
end)

check('职阶 helper 基础行为', function()
  local g, st = round('saber', 'berserker', 1)
  is_true(AC.isPlayerClass(g, 'saber'))
  is_true(AC.isDealerClass(g, 'berserker'))
  is_false(AC.isPlayerClass(g, 'archer'))
  eq(AC.playerClassId(g), 'saber')
  eq(AC.dealerClassId(g), 'berserker')
  is_true(AC.anyDealerClass(g, 'berserker'))
end)

print('')
print('class_acceptance: ' .. pass .. ' passed, ' .. #failures .. ' failed')
if #failures > 0 then
  for _, f in ipairs(failures) do print('  ' .. f) end
  error('class_acceptance failures: ' .. #failures)
end
