-- tools/probability_acceptance.lua
-- 概率情报模块独立验收（真期望值；不依赖 core game.lua）
-- 运行：python tools/run_lua.py tools/probability_acceptance.lua
local SI = require('src.shoe_info')
local BJ = require('src.blackjack')
local Deck = require('src.deck')

local pass, failures = 0, {}
local function check(name, fn)
  local ok, err = pcall(fn)
  if ok then pass = pass + 1; print('PASS ' .. name)
  else failures[#failures + 1] = name .. ': ' .. tostring(err); print('FAIL ' .. failures[#failures]) end
end
local function eq(a, b, label)
  if a ~= b then error((label or '') .. ' expected ' .. tostring(b) .. ' got ' .. tostring(a), 2) end
end
local function approx(a, b, label, eps)
  if type(a) ~= 'number' then error((label or '') .. ' expected number ' .. tostring(b) .. ' got ' .. tostring(a), 2) end
  if math.abs(a - b) > (eps or 1e-9) then error((label or '') .. ' expected ' .. tostring(b) .. ' got ' .. tostring(a), 2) end
end
local function card(rank, suit, value) return { rank = rank, suit = suit or 'S', value = value } end

-- ============ 1. 桶识别与公共 API ============
check('public API surface present', function()
  for _, n in ipairs({ 'bucketOf', 'bucketValue', 'rankComposition', 'orderBand', 'bustOdds', 'dealerBustOdds', 'cutShoe', 'standardCut' }) do
    assert(type(SI[n]) == 'function', 'missing ' .. n)
  end
  eq(SI.UNKNOWN, 'unknown')
end)

check('bucketOf standard ranks and values', function()
  eq(SI.bucketOf(card('A')), 'A'); eq(SI.bucketValue(card('A')), 11)
  eq(SI.bucketOf(card('K')), '10'); eq(SI.bucketOf(card('J')), '10')
  eq(SI.bucketOf(card('Q')), '10'); eq(SI.bucketOf(card('10')), '10')
  eq(SI.bucketValue(card('10')), 10)
  eq(SI.bucketOf(card('7')), '7'); eq(SI.bucketValue(card('7')), 7)
  eq(SI.bucketOf(card('2')), '2'); eq(SI.bucketValue(card('2')), 2)
end)

check('non-standard cards are not standard buckets', function()
  eq(SI.bucketOf(card('1')), 'unknown')                        -- 倍率 rank=1
  eq(SI.bucketValue(card('1')), nil)
  eq(SI.bucketOf(card('A', nil, 2.5)), 'unknown')              -- 带 value 的 A
  eq(SI.bucketOf(card('2.5', nil, 2.5)), 'unknown')            -- 小数
  eq(SI.bucketOf(card('-7', nil, -7)), 'unknown')              -- 负数
  eq(SI.bucketOf({ rank = '', kind = 'dice6' }), 'unknown')    -- 骰子
  eq(SI.bucketOf({ rank = 'rock', value = 0, is_rps = true }), 'unknown') -- RPS
  eq(SI.bucketOf(nil), 'unknown')
end)

-- ============ 2. 成分统计 ============
check('rankComposition merges JQK to 10 and separates unknown', function()
  local comp = SI.rankComposition({ card('A'), card('K'), card('Q'), card('7'),
    { rank = '', kind = 'dice6' }, card('A', nil, 2.5) })
  eq(comp.total, 6)
  eq(comp.buckets.A, 1); eq(comp.buckets['10'], 2); eq(comp.buckets['7'], 1)
  eq(comp.unknown, 2)  -- 骰子 + 带值 A
  eq(#comp.order, 10)
  assert(comp.coverageGap ~= '', 'coverageGap should not be empty')
  eq(comp.nonstandard.total, 2)
end)

check('coverageOf counts categories', function()
  local cov = SI.coverageOf({ card('A'), card('5'), card('3', nil, 3), { rank = '', kind = 'dice20' }, card('1') })
  eq(cov.total, 5); eq(cov.standard, 2); eq(cov.valued, 1)
  eq(cov.undetermined, 1); eq(cov.nonstandard, 1); eq(cov.unknown, 3)
end)

-- ============ 3. 下一张爆率：硬 / 软 A / unknown ============
check('bustOdds hard total exact', function()
  local hand16 = { card('10'), card('6') }
  local p, d = SI.bustOdds(16, { card('10'), card('10'), card('10') }, { hand = hand16 })
  approx(p, 1.0, 'all tens bust 16')
  eq(d.total, 3); eq(d.bust, 3); eq(d.needHand, false)

  local p2 = SI.bustOdds(20, { card('A'), card('9') }, { hand = { card('K'), card('Q') } })
  approx(p2, 0.5, 'A->21 not bust, 9->29 bust')
end)

check('bustOdds soft ace uses opts.hand (naive total would be wrong)', function()
  -- 软 17 (A+6)：加 5 -> 12，加 10 -> 17，均不爆
  local p, d = SI.bustOdds(17, { card('5'), card('10') }, { hand = { card('A'), card('6') } })
  approx(p, 0.0, 'soft 17 never busts here')
  eq(d.needHand, false)
  -- 不传 hand 只按硬点数：17+5=22、17+10=27 都爆（说明为何必须给 hand）
  local pn, dn = SI.bustOdds(17, { card('5'), card('10') })
  approx(pn, 1.0, 'hard-total fallback')
  eq(dn.needHand, true)
end)

check('bustOdds downgrades appended ace to 1 over 21', function()
  local a = SI.bustOdds(16, { card('A') }, { hand = { card('10'), card('6') } })
  approx(a, 0.0, 'A appended to hard 16 -> 17')
  local b = SI.bustOdds(16, { card('A') })
  approx(b, 0.0, '16 + 11 > 21 so ace=1 -> 17')
  -- 21 硬手再抽 A -> 22 爆
  local c = SI.bustOdds(21, { card('A') }, { hand = { card('10'), card('6'), card('5') } })
  approx(c, 1.0, '21 hard + A -> 22')
  local d = SI.bustOdds(21, { card('A') })
  approx(d, 1.0, '21 + A -> 22')
end)

check('bustOdds valued special cards use exact value', function()
  local hand = { card('10'), card('5') }
  approx(SI.bustOdds(15, { card('2.5', nil, 2.5) }, { hand = hand }), 0.0, '2.5 -> 17.5')
  approx(SI.bustOdds(15, { card('6.5', nil, 6.5) }, { hand = hand }), 1.0, '6.5 -> 21.5 bust')
  approx(SI.bustOdds(20, { card('-5', nil, -5) }, { hand = { card('K'), card('Q') } }), 0.0, '-5 -> 15')
end)

check('bustOdds unknown card returns nil + reason + coverage gap', function()
  local p, d = SI.bustOdds(15, { { rank = '', kind = 'dice6' } }, { hand = { card('10'), card('5') } })
  eq(p, nil); eq(d.reason, 'unknown_cards')
  assert(d.coverageGap ~= '' and string.find(d.coverageGap, 'dice', 1, true), d.coverageGap)
  local p2, d2 = SI.bustOdds(16, {}, { hand = { card('10'), card('6') } })
  eq(p2, nil); eq(d2.reason, 'no_known_cards')
end)

-- ============ 4. 庄家爆率：小桶手算 / 无放回 ============
check('dealerBustOdds known hand one-draw exact', function()
  -- 16 硬，难度 2 要牌；桶 {5:1, 10:1} -> 5 到 21 停、10 到 26 爆 => 0.5
  local p = SI.dealerBustOdds({ card('10'), card('6') }, 2,
    { useShoe = true, deck = { drawPile = { card('5'), card('10') } } })
  approx(p, 0.5, 'one draw 50% bust')
  -- 桶 {5:2, 10:1} -> 1/3
  local p2 = SI.dealerBustOdds({ card('10'), card('6') }, 2,
    { useShoe = true, deck = { drawPile = { card('5'), card('5'), card('10') } } })
  approx(p2, 1 / 3, 'two 5s and one 10')
end)

check('dealerBustOdds is no-replacement and memo uses bucket state', function()
  -- 手 {2,2}=4，难度 1；桶 {10:1, 8:2}
  --  10 支路(1/3)：14 -> 两张 8 都爆 => 1
  --  8  支路(2/3)：12 -> 桶{10,8}：10 爆(1/2)，8 到 20 停 => 0.5
  --  合计 2/3。若按“有放回”会得到 5/9，故可证无放回。
  local p = SI.dealerBustOdds({ card('2'), card('2') }, 1,
    { useShoe = true, deck = { drawPile = { card('10'), card('8'), card('8') } } })
  approx(p, 2 / 3, 'exact no-replacement recursion')
  assert(math.abs(p - 5 / 9) > 1e-6, 'must not match with-replacement 5/9')
end)

check('dealerBustOdds enumerates unknown hole from available buckets', function()
  -- 明牌 10，暗牌未知；桶 {10:1, 6:2}，难度 2
  --  hole=10 (1/3) -> 20 停；hole=6 (2/3) -> 16 要牌，剩 {10,6} 都爆 => 2/3
  local p, d = SI.dealerBustOdds({ card('10') }, 2,
    { useShoe = true, deck = { drawPile = { card('10'), card('6'), card('6') } } })
  approx(p, 2 / 3, 'hole averaged over buckets')
  eq(d.holeUnknown, true)
  -- 两张都已知（明+暗）：16 要牌，桶 {10,6} 都爆 => 1
  local p2 = SI.dealerBustOdds({ card('10'), card('6') }, 2,
    { useShoe = true, deck = { drawPile = { card('10'), card('6') } } })
  approx(p2, 1.0, 'known hole')
end)

check('dealerBustOdds respects dealer AI difficulty and stand opts', function()
  local shoe = { drawPile = { card('10'), card('10') } }
  -- 17 硬：难度 2 要牌 -> 抽 10 爆；standOn=17 则停
  approx(SI.dealerBustOdds({ card('10'), card('7') }, 2, { useShoe = true, deck = shoe }), 1.0, 'd2 hits 17')
  approx(SI.dealerBustOdds({ card('10'), card('7') }, 2, { useShoe = true, deck = shoe, standOn = 17 }), 0.0, 'standOn 17')
  -- 软 17：难度 1 要牌；standOnSoft17 则停
  local softShoe = { drawPile = { card('5'), card('10') } }
  approx(SI.dealerBustOdds({ card('A'), card('6') }, 1, { useShoe = true, deck = softShoe }), 0.5, 'soft17 hits -> 0.5')
  approx(SI.dealerBustOdds({ card('A'), card('6') }, 1, { useShoe = true, deck = softShoe, standOnSoft17 = true }), 0.0, 'stand on soft 17')
end)

check('dealerBustOdds honors 5-hit dealer cap', function()
  -- 手 {2,2}=4，难度 1，桶 {2:5, 10:1}
  -- 追加上限 5：只有 10 恰为第 5 张才爆 => 1/6
  -- hitCap=10：10 为第 5 或第 6 张都爆 => 2/6 = 1/3
  local shoe = { drawPile = { card('2'), card('2'), card('2'), card('2'), card('2'), card('10') } }
  local pDef = SI.dealerBustOdds({ card('2'), card('2') }, 1, { useShoe = true, deck = shoe })
  approx(pDef, 1 / 6, 'default hit cap 5')
  local pTen = SI.dealerBustOdds({ card('2'), card('2') }, 1, { useShoe = true, deck = shoe, hitCap = 10 })
  approx(pTen, 1 / 3, 'hitCap 10')
end)

-- ============ 5. 深度 / 预算 / 未知牌 ============
check('dealerBustOdds over depth/budget returns nil + reason (no partial number)', function()
  local shoe = { drawPile = { card('10'), card('8'), card('8') } }
  local p, d = SI.dealerBustOdds({ card('2'), card('2') }, 1, { useShoe = true, deck = shoe, maxDepth = 1 })
  eq(p, nil); eq(d.reason, 'depth_exceeded'); assert(d.nodes >= 1 and d.nodes > 0)
  local p2, d2 = SI.dealerBustOdds({ card('2'), card('2') }, 1, { useShoe = true, deck = shoe, budget = 1 })
  eq(p2, nil); eq(d2.reason, 'budget_exceeded')
  assert(string.find(d2.message, 'SI_BUDGET', 1, true) ~= nil)
  -- 默认护栏下同一场景应给出精确分数
  local ok = SI.dealerBustOdds({ card('2'), card('2') }, 1, { useShoe = true, deck = shoe })
  approx(ok, 2 / 3, 'default budget converges')
end)

check('dealerBustOdds unknown (dice/RPS) -> nil + coverage gap', function()
  local p, d = SI.dealerBustOdds({ card('10'), card('6') }, 2,
    { useShoe = true, deck = { drawPile = { card('10'), { rank = '', kind = 'dice6' } } } })
  eq(p, nil); eq(d.reason, 'unknown_cards')
  assert(d.coverageGap ~= '' and string.find(d.coverageGap, 'dice', 1, true), d.coverageGap)

  local p4, d4 = SI.dealerBustOdds({ card('10'), card('6') }, 2,
    { cards = { card('10'), { rank = 'rock', value = 0, is_rps = true } } })
  eq(p4, nil); eq(d4.reason, 'unknown_cards')

  local p3, d3 = SI.dealerBustOdds({ { rank = '', kind = 'dice6' } }, 2,
    { useShoe = true, deck = { drawPile = { card('10') } } })
  eq(p3, nil); eq(d3.reason, 'unknown_upcard')
  assert(d3.coverageGap ~= '')
end)

check('dealerBustOdds excludes valued cards + gap (GDD 11.1)', function()
  local p, d = SI.dealerBustOdds({ card('10'), card('6') }, 2, { cards = { card('10'), card('2.5', nil, 2.5) } })
  approx(p, 1.0, 'only the 10 remains -> bust')
  eq(d.basis, 'cards'); eq(d.valuedExcluded, 1)
  assert(d.coverageGap ~= '' and string.find(d.coverageGap, 'valued:2.5', 1, true), d.coverageGap)

  local p2, d2 = SI.dealerBustOdds({ card('2.5', nil, 2.5) }, 2, { cards = { card('10') } })
  approx(p2, 0.0, 'valued upcard counted exactly, no branch')
  eq(d2.reason, nil)

  local p3, d3 = SI.dealerBustOdds({ card('10'), card('6') }, 2, { cards = { card('2.5', nil, 2.5) } })
  eq(p3, nil); eq(d3.reason, 'no_standard_cards')
end)

check('dealerBustOdds honors core opts.cards (not silently standard52)', function()
  local p, d = SI.dealerBustOdds({ card('10'), card('6') }, 2, { cards = { card('10'), card('10'), card('10') } })
  approx(p, 1.0, 'all tens bust'); eq(d.basis, 'cards')
  local q = SI.dealerBustOdds({ card('10'), card('6') }, 2, { useShoe = true, deck = { drawPile = { card('5'), card('10') } } })
  local q2 = SI.dealerBustOdds({ card('10'), card('6') }, 2, { cards = { card('5'), card('10') } })
  approx(q, 0.5); approx(q2, q, 'cards == deck for same pool')
  local full = {}
  local ranks = { 'A', '2', '3', '4', '5', '6', '7', '8', '9', '10', 'J', 'Q', 'K' }
  local suits = { 'S', 'H', 'D', 'C' }
  for i = 1, #ranks do for s = 1, #suits do full[#full + 1] = card(ranks[i], suits[s]) end end
  local fp, fd = SI.dealerBustOdds({ card('10') }, 2, { cards = full })
  assert(type(fp) == 'number' and fp >= 0 and fp <= 1, 'realistic sample range')
  assert(fd.nodes > 0 and fd.holeUnknown == true)
end)

check('opts.holeUnknown overrides a passed holeCard', function()
  local p = SI.dealerBustOdds({ card('10') }, 2,
    { cards = { card('10'), card('6'), card('6') }, holeCard = card('6'), holeUnknown = true })
  approx(p, 2 / 3, 'hole still enumerated over buckets')
  local p2 = SI.dealerBustOdds({ card('10') }, 2,
    { cards = { card('10'), card('6'), card('6') }, holeCard = card('6') })
  approx(p2, 1.0, 'known hole 6 -> hard 16, remaining 10/6 both bust')
end)

check('dealerBustOdds missing upcard returns nil reason', function()
  local p, d = SI.dealerBustOdds({}, 2, { useShoe = true, deck = { drawPile = { card('10') } } })
  eq(p, nil); eq(d.reason, 'no_upcard')
end)

-- ============ 6. 委托最新 BJ.dealerShouldHitTotal ============
check('dealerBustOdds delegates to BJ.dealerShouldHitTotal with opts', function()
  local orig = BJ.dealerShouldHitTotal
  local captured = {}
  local okCall, err = pcall(function()
    BJ.dealerShouldHitTotal = function(t, s, d, pt, o)
      captured[#captured + 1] = { t = t, s = s, d = d, pt = pt, o = o }
      return false
    end
    local p = SI.dealerBustOdds({ card('10'), card('6') }, 2,
      { useShoe = true, deck = { drawPile = { card('10') } }, playerTotal = 18, standOn = 17, bustAt = 25 })
    approx(p, 0.0, 'stub always stands')
  end)
  BJ.dealerShouldHitTotal = orig
  if not okCall then error(err, 2) end
  assert(#captured > 0, 'BJ.dealerShouldHitTotal was not called')
  -- 首次判定：16 硬、难度 2、playerTotal 18，opts 透传
  local first = captured[1]
  eq(first.t, 16); eq(first.s, false); eq(first.d, 2); eq(first.pt, 18)
  eq(first.o.bustAt, 25); eq(first.o.standOn, 17)
end)

-- ============ 7. 无 RNG 消耗 + 确定性 ============
check('intel queries consume no RNG and are deterministic', function()
  local realMath = math.random
  local realLove = love and love.math and love.math.random
  local calls = 0
  math.random = function(...) calls = calls + 1; return realMath(...) end
  if love and love.math then love.math.random = function(...) calls = calls + 1; return realLove(...) end end
  local okRun, err = pcall(function()
    SI.bucketOf(card('A'))
    SI.rankComposition({ card('A'), card('K') })
    SI.bustOdds(16, { card('10') }, { hand = { card('10'), card('6') } })
    local q = SI.dealerBustOdds({ card('10'), card('6') }, 2,
      { useShoe = true, deck = { drawPile = { card('5'), card('10') } } })
    SI.orderBand({ drawPile = { card('2'), card('3') } }, { n = 2 })
    local q2 = SI.dealerBustOdds({ card('10'), card('6') }, 2,
      { useShoe = true, deck = { drawPile = { card('5'), card('10') } } })
    eq(q, q2, 'deterministic repeat')
    approx(q, 0.5)
  end)
  math.random = realMath
  if love and love.math then love.math.random = realLove end
  if not okRun then error(err, 2) end
  eq(calls, 0, 'RNG must not be consumed')
end)

-- ============ 8. 顺序带 / 切牌 / 标准切 ============
check('orderBand offset and reveal conditions', function()
  local deck = { drawPile = { card('2'), card('3'), card('4') } }
  local b = SI.orderBand(deck, { n = 2 })
  eq(#b, 2); eq(b[1].offset, 1); eq(b[1].card.rank, '2'); eq(b[1].revealed, false)
  local b2 = SI.orderBand(deck, { n = 2, offset = 1 })
  eq(b2[1].card.rank, '3'); eq(b2[1].offset, 2)
  local b3 = SI.orderBand(deck, { n = 3, revealDepth = 1 })
  eq(b3[1].revealed, true); eq(b3[2].revealed, false)
  local cA = card('2'); cA.uid = 7
  local b4 = SI.orderBand({ drawPile = { cA, card('3') } }, { n = 2, revealSet = { [7] = true } })
  eq(b4[1].revealed, true); eq(b4[2].revealed, false)
  local b5 = SI.orderBand(deck, { n = 1, revealAll = true })
  eq(b5[1].revealed, true)
end)

check('cutShoe rotates drawPile and standardCut range', function()
  local dk = Deck.new({ rng = function(a, b) return a end })
  dk.drawPile = { card('2'), card('3'), card('4'), card('5') }
  local ret = SI.cutShoe(dk, 3)
  eq(ret, dk)
  eq(dk.drawPile[1].rank, '4'); eq(dk.drawPile[2].rank, '5')
  eq(dk.drawPile[3].rank, '2'); eq(dk.drawPile[4].rank, '3')
  -- state 包装也接受
  local dk2 = Deck.new(); dk2.drawPile = { card('2'), card('3'), card('4') }
  SI.cutShoe({ deck = dk2 }, 2)
  eq(dk2.drawPile[1].rank, '3'); eq(dk2.drawPile[3].rank, '2')
  eq(SI.standardCut(function() return 0 end), 8)
  local hi = SI.standardCut(function() return 0.999999 end)
  assert(hi >= 8 and hi <= 25, 'cut range')
end)

-- ============ 9. 默认护栏基准 ============
check('standard52 fallback converges with nodes > 0', function()
  local p, d = SI.dealerBustOdds({ card('10'), card('6') }, 2, {})
  assert(type(p) == 'number' and p >= 0 and p <= 1, 'probability range')
  eq(d.basis, 'standard52'); assert(d.nodes > 0)
  local hp, hd = SI.dealerBustOdds({ card('10') }, 2, {})
  assert(type(hp) == 'number' and hp >= 0 and hp <= 1, 'hole standard52 range')
  eq(hd.holeUnknown, true)
end)

-- ============ 10. core 200 张 sample 性能护栏 ============
check('200-card realistic sample converges under node budget', function()
  local sample = {}
  local ranks = { 'A', '2', '3', '4', '5', '6', '7', '8', '9', '10', 'J', 'Q', 'K' }
  for i = 1, 200 do sample[#sample + 1] = card(ranks[((i - 1) % 13) + 1], 'S') end
  eq(SI.rankComposition(sample).total, 200)
  local p, d = SI.dealerBustOdds({ card('10') }, 2, { cards = sample })
  assert(type(p) == 'number' and p >= 0 and p <= 1, 'converged to a probability')
  assert(d.nodes > 0 and d.nodes <= SI.NODE_BUDGET, 'within budget: ' .. tostring(d.nodes))
  eq(d.holeUnknown, true)
end)

print(string.format('Probability acceptance: PASS=%d FAIL=%d', pass, #failures))
if #failures > 0 then error(table.concat(failures, '\n')) end
