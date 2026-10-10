-- tools/scoring_acceptance.lua — 39 件“纯 fx”遗物的数值验收（不依赖 UI）
-- 运行：python tools/run_lua.py tools/scoring_acceptance.lua
-- 目标：按 GDD 附录 A 的预期，对 mult / x_mult / chips / 最终 winnings 做正反例断言，
--       并验证叠加顺序、软 22 规则、67 组合的 ×67 优先级。
--       不是“调用了 fx 就算通过”——每个用例都断言具体数值。
local R = require('src.relics')
local S = require('src.scoring')
local BJ = require('src.blackjack')

local pass, failures = 0, {}
local function check(name, fn)
  local ok, err = pcall(fn)
  if ok then pass = pass + 1; print('PASS ' .. name)
  else failures[#failures+1] = name .. ': ' .. tostring(err); print('FAIL ' .. failures[#failures]) end
end
local function eq(a, b, msg)
  if a ~= b then error((msg and (msg..' ') or '')..'expected='..tostring(b)..' got='..tostring(a), 2) end
end
local function approx(a, b, msg)
  if math.abs((a or 0) - b) > 1e-6 then error((msg and (msg..' ') or '')..'expected~='..tostring(b)..' got='..tostring(a), 2) end
end

local function card(rank, suit) return { rank = rank, suit = suit or 'S', value = nil } end
local function hand(spec)
  local h = {}
  for _, s in ipairs(spec) do h[#h+1] = card(s:sub(1, #s-1), s:sub(-1)) end
  return h
end
local function P(spec, total, extra)
  local h = hand(spec)
  local p = { hand = h, total = total or BJ.handTotal(h), busted = false, blackjack = false }
  if p.total > 21 then p.busted = true end
  for k, v in pairs(extra or {}) do p[k] = v end
  return p
end
local function D(spec, total, extra)
  local h = hand(spec)
  local d = { hand = h, total = total or BJ.handTotal(h), busted = false }
  for k, v in pairs(extra or {}) do d[k] = v end
  return d
end
local function baseP() return P({'9S','8S'}) end
local function baseD() return D({'9H','7H'}) end

local function run(ids, p, d, st, opts)
  if type(ids) == 'string' then ids = { ids } end
  local list = {}
  for _, id in ipairs(ids) do
    local def = R.byId(id)
    if not def then error('missing relic ' .. tostring(id)) end
    list[#list+1] = { def = def }
  end
  local ctx = S.newCtx(p, d, st or { streak = 0 }, opts or {})
  ctx.creditUsed = (opts and opts.creditUsed)
  ctx.stage = (opts and opts.stage)
  S.run(ctx, list, {}, nil)
  if ctx.errors and #ctx.errors > 0 then error('fx error in '..tostring(ctx.errors[1].id)..': '..tostring(ctx.errors[1].err)) end
  local w, info = S.finalize(ctx)
  return ctx, info, w
end
local function sc(id, opts, p, d, st)
  return run(id, p or baseP(), d or baseD(), st, opts or { bet = 100, outcome = 'player' })
end

-- ===================== 固定倍率 / 乘区 =====================
check('mult_ring 每局倍率 +1', function()
  local _, info, w = sc('mult_ring'); eq(info.mult, 2); eq(w, 400)
end)
check('gold_charm 倍率 +2', function()
  local _, info = sc('gold_charm'); eq(info.mult, 3)
end)
check('super_mult 倍率 +3', function()
  local _, info = sc('super_mult'); eq(info.mult, 4)
end)
check('divine_blessing 最终 ×1.2', function()
  local _, info, w = sc('divine_blessing'); approx(info.x_mult, 1.2); eq(w, 240)
end)

-- ===================== 精准点数 =====================
check('perfect_21 非自然 21 -> ×2', function()
  local _, info, w = sc('perfect_21', { bet=100, outcome='player' }, P({'10S','5S','6S'}, 21)); approx(info.x_mult, 2); eq(w, 400)
end)
check('perfect_21 自然 21 不触发（由 Blackjack 大师负责）', function()
  local _, info = sc('perfect_21', { bet=100, outcome='player' }, P({'AS','KS'}, 21, { blackjack=true })); approx(info.x_mult, 1)
end)
check('perfect_21 20 点不触发', function()
  local _, info = sc('perfect_21', { bet=100, outcome='player' }, P({'10S','5S','5S'}, 20)); approx(info.x_mult, 1)
end)
check('ace_and_ten_exact A 算 1 恰好 12 -> 倍率 +20', function()
  local _, info = sc('ace_and_ten_exact', nil, P({'5S','7S'}, 12)); eq(info.mult, 21)
end)
check('ace_and_ten_exact 两张 A（A=1 为 2）不触发', function()
  local _, info = sc('ace_and_ten_exact', nil, P({'AS','AH'}, 12)); eq(info.mult, 1)
end)
check('ace_and_ten_exact A+K+2（A=1 为 13）不触发', function()
  local _, info = sc('ace_and_ten_exact', nil, P({'AS','KS','2S'}, 13)); eq(info.mult, 1)
end)
check('fives_15 三张 5 -> +30', function()
  local _, info = sc('fives_15', nil, P({'5S','5H','5D'})); eq(info.mult, 31)
end)
check('fives_15 两张 5 不触发', function()
  local _, info = sc('fives_15', nil, P({'5S','5H','9D'})); eq(info.mult, 1)
end)
check('low_buff 含 3/4/5 -> +2', function()
  local _, info = sc('low_buff', nil, P({'3S','9H'})); eq(info.mult, 3)
end)
check('low_buff 无 3/4/5 不触发', function()
  local _, info = sc('low_buff', nil, P({'8S','9H'})); eq(info.mult, 1)
end)
check('dealer_mirror_17 点数 == 庄家明牌(10) -> +3', function()
  local _, info = sc('dealer_mirror_17', nil, P({'5S','5H'}, 10), D({'9H','JS'}, 19)); eq(info.mult, 4)
end)
check('dealer_mirror_17 明牌为 A 时按 11 比对', function()
  local _, info = sc('dealer_mirror_17', nil, P({'6S','5H'}, 11), D({'9H','AS'}, 20)); eq(info.mult, 4)
end)
check('dealer_mirror_17 不等不触发', function()
  local _, info = sc('dealer_mirror_17', nil, P({'5S','5H'}, 10), D({'9H','8S'}, 17)); eq(info.mult, 1)
end)

-- ===================== 自然 21 / 保险 =====================
check('blackjack_master 自然 21 -> ×5', function()
  local _, info, w = sc('blackjack_master', { bet=100, outcome='player', naturalBJ=true }, P({'AS','KS'}, 21, { blackjack=true }))
  approx(info.x_mult, 5); eq(w, 750)
end)
check('blackjack_master 非自然 21 不触发', function()
  local _, info = sc('blackjack_master', nil, P({'10S','5S','6S'}, 21)); approx(info.x_mult, 1)
end)
check('bj_insurance 自然 21 强制判胜（庄家赢改判玩家赢）', function()
  local _, info = sc('bj_insurance', { bet=100, outcome='dealer', naturalBJ=true }, P({'AS','KS'}, 21, { blackjack=true }))
  eq(info.outcome, 'player')
end)

-- ===================== 对子 / 同花 / 牌型 =====================
check('pair_boost J+Q 视为同点对子 -> +3', function()
  local _, info = sc('pair_boost', nil, P({'JS','QS'}, 20)); eq(info.mult, 4)
end)
check('pair_boost 10+J 视为同点对子 -> +3', function()
  local _, info = sc('pair_boost', nil, P({'10S','JD'}, 20)); eq(info.mult, 4)
end)
check('pair_boost 10+9 不触发', function()
  local _, info = sc('pair_boost', nil, P({'10S','9D'}, 19)); eq(info.mult, 1)
end)
check('pair_royalty J+J -> +8', function()
  local _, info = sc('pair_royalty', nil, P({'JS','JD'}, 20)); eq(info.mult, 9)
end)
check('pair_royalty Q+Q / K+K -> +8', function()
  local _, i1 = sc('pair_royalty', nil, P({'QS','QD'}, 20)); eq(i1.mult, 9)
  local _, i2 = sc('pair_royalty', nil, P({'KS','KD'}, 20)); eq(i2.mult, 9)
end)
check('pair_royalty J+Q 点数不同不触发', function()
  local _, info = sc('pair_royalty', nil, P({'JS','QD'}, 20)); eq(info.mult, 1)
end)
check('pair_royalty 10+J 非同一 J/Q/K 不触发', function()
  local _, info = sc('pair_royalty', nil, P({'10S','JD'}, 20)); eq(info.mult, 1)
end)
check('pair_royalty 10+10 不触发（10 不属于 J/Q/K）', function()
  local _, info = sc('pair_royalty', nil, P({'10S','10D'}, 20)); eq(info.mult, 1)
end)
check('flush_master 4 张同花 -> ×2', function()
  local _, info = sc('flush_master', nil, P({'2S','5S','7S','9S'}, 23)); approx(info.x_mult, 2)
end)
check('flush_master 3 张同花不触发', function()
  local _, info = sc('flush_master', nil, P({'2S','5S','7S','9H'}, 23)); approx(info.x_mult, 1)
end)
check('double_seven 两张 7 -> +15', function()
  local _, info = sc('double_seven', nil, P({'7S','7D'}, 14)); eq(info.mult, 16)
end)
check('double_seven 一张 7 不触发', function()
  local _, info = sc('double_seven', nil, P({'7S','8D'}, 15)); eq(info.mult, 1)
end)
check('rainbow_21 恰好 21 且四花色齐全 -> ×2', function()
  local _, info = sc('rainbow_21', nil, P({'5S','6H','4D','6C'}, 21)); approx(info.x_mult, 2)
end)
check('rainbow_21 缺一花色不触发', function()
  local _, info = sc('rainbow_21', nil, P({'5S','6H','4D','6D'}, 21)); approx(info.x_mult, 1)
end)
check('rainbow_21 四花色但非 21 不触发', function()
  local _, info = sc('rainbow_21', nil, P({'5S','6H','4D','4C'}, 19)); approx(info.x_mult, 1)
end)
check('clockwork_dragon 含 A 与 10 点牌且非自然 -> ×10', function()
  local _, info = sc('clockwork_dragon', nil, P({'AS','10H','5D'}, 16)); approx(info.x_mult, 10)
end)
check('clockwork_dragon 自然 21 不触发（“非自然”边界）', function()
  local _, info = sc('clockwork_dragon', { bet=100, outcome='player', naturalBJ=true }, P({'AS','KH'}, 21, { blackjack=true }))
  approx(info.x_mult, 1)
end)
check('clockwork_dragon 无 A 不触发', function()
  local _, info = sc('clockwork_dragon', nil, P({'KS','QH','5D'}, 25)); approx(info.x_mult, 1)
end)
check('clockwork_dragon 无 10 点牌不触发', function()
  local _, info = sc('clockwork_dragon', nil, P({'AS','5H','5D'}, 11)); approx(info.x_mult, 1)
end)

-- ===================== 平局 / 保险 / 22 =====================
check('push_king 平局 -> 倍率 +2 且筹码 +300', function()
  local _, info, w = sc('push_king', { bet=100, outcome='push' })
  eq(info.mult, 3); eq(info.cardChips, 300); eq(info.additive, 400); eq(w, 1200)
end)
check('push_as_win 平局判胜', function()
  local _, info = sc('push_as_win', { bet=100, outcome='push' }); eq(info.outcome, 'player')
end)
check('dealer_22_push 庄家 22 且玩家 <=21 -> 判平局', function()
  local _, info = sc('dealer_22_push', { bet=100, outcome='player' }, P({'10S','9H'}, 19), D({'10H','10D','2S'}, 22, { busted=true }))
  eq(info.outcome, 'push')
end)
check('dealer_22_push 玩家也超 21 时不改判', function()
  local _, info = sc('dealer_22_push', { bet=100, outcome='player' }, P({'10S','10H','5D'}, 25, { busted=true }), D({'10H','10D','2S'}, 22, { busted=true }))
  eq(info.outcome, 'player')
end)
check('insurance_master 庄家明 A 且输 -> 只输一半', function()
  local _, info = sc('insurance_master', { bet=100, outcome='dealer', dealerUpAce=true }); eq(info.halfLoss, true); eq(info.netChange, -50)
end)
check('insurance_master 庄家非明 A 不触发', function()
  local _, info = sc('insurance_master', { bet=100, outcome='dealer', dealerUpAce=false }); eq(info.halfLoss, false)
end)
check('bust_shield 爆牌改判平局并扣次', function()
  local consumed = nil
  local ctx = S.newCtx(P({'10S','10H','5D'}, 25, { busted=true }), baseD(), { streak=0 }, { bet=100, outcome='dealer' })
  ctx.gs = { consumeRelic = function(self, id) consumed = id end }
  S.run(ctx, { { def = R.byId('bust_shield') } }, {}, nil)
  local _, info = S.finalize(ctx)
  eq(consumed, 'bust_shield'); eq(info.outcome, 'push')
end)
check('bust_shield 未爆牌不触发也不扣次', function()
  local consumed = nil
  local ctx = S.newCtx(baseP(), baseD(), { streak=0 }, { bet=100, outcome='player' })
  ctx.gs = { consumeRelic = function(self, id) consumed = id end }
  S.run(ctx, { { def = R.byId('bust_shield') } }, {}, nil)
  local _, info = S.finalize(ctx)
  eq(consumed, nil); eq(info.outcome, 'player')
end)

-- ===================== A 与十点牌 =====================
check('ace_blessing 每张 A 倍率 +1', function()
  local _, info = sc('ace_blessing', nil, P({'AS','AH'}, 12)); eq(info.mult, 3)
end)
check('ace_blessing 无 A 不触发', function()
  local _, info = sc('ace_blessing', nil, P({'KS','QH'}, 20)); eq(info.mult, 1)
end)
check('ten_spotlight 含 10/J/Q/K -> +1', function()
  local _, i1 = sc('ten_spotlight', nil, P({'10S','5H'}, 15)); eq(i1.mult, 2)
  local _, i2 = sc('ten_spotlight', nil, P({'JS','5H'}, 15)); eq(i2.mult, 2)
end)
check('ten_spotlight 无十点牌不触发', function()
  local _, info = sc('ten_spotlight', nil, P({'9S','5H'}, 14)); eq(info.mult, 1)
end)

-- ===================== 庄家相关 =====================
check('dealer_killer 庄家爆牌 -> 筹码 +1000', function()
  local _, info = sc('dealer_killer', { bet=100, outcome='player' }, baseP(), D({'10H','10D','5S'}, 25, { busted=true }))
  eq(info.cardChips, 1000); eq(info.additive, 1200)
end)
check('steal_money 庄家爆牌 -> ×1.2', function()
  local _, info = sc('steal_money', { bet=100, outcome='player' }, baseP(), D({'10H','10D','5S'}, 25, { busted=true }))
  approx(info.x_mult, 1.2)
end)
check('coward_curse 庄家恰 17 -> +2', function()
  local _, info = sc('coward_curse', nil, baseP(), D({'10H','7S'}, 17)); eq(info.mult, 3)
end)
check('coward_curse 庄家 16 不触发', function()
  local _, info = sc('coward_curse', nil, baseP(), D({'10H','6S'}, 16)); eq(info.mult, 1)
end)

-- ===================== 下注策略 / 连胜 / 阶段 =====================
check('conservative_bet 下注 <=100 且赢 -> +3', function()
  local _, info = sc('conservative_bet', { bet=100, outcome='player' }); eq(info.mult, 4)
end)
check('conservative_bet 下注 101 或未赢不触发', function()
  local _, i1 = sc('conservative_bet', { bet=101, outcome='player' }); eq(i1.mult, 1)
  local _, i2 = sc('conservative_bet', { bet=100, outcome='dealer' }); eq(i2.mult, 1)
end)
check('balanced_bet 下注 200~500 且赢 -> +5', function()
  local _, i1 = sc('balanced_bet', { bet=200, outcome='player' }); eq(i1.mult, 6)
  local _, i2 = sc('balanced_bet', { bet=500, outcome='player' }); eq(i2.mult, 6)
end)
check('balanced_bet 边界 199 / 501 不触发', function()
  local _, i1 = sc('balanced_bet', { bet=199, outcome='player' }); eq(i1.mult, 1)
  local _, i2 = sc('balanced_bet', { bet=501, outcome='player' }); eq(i2.mult, 1)
end)
check('small_bet_master 恰 $50 且赢 -> +4 且 +1000', function()
  local _, info = sc('small_bet_master', { bet=50, outcome='player' }); eq(info.mult, 5); eq(info.cardChips, 1000)
end)
check('aggressive_bet 下注 >=500 且赢 -> ×1.5', function()
  local _, info = sc('aggressive_bet', { bet=500, outcome='player' }); approx(info.x_mult, 1.5)
end)
check('all_in_fanatic 下注 >=80% 筹码且赢 -> ×2', function()
  local _, info = sc('all_in_fanatic', { bet=800, outcome='player', chipsBefore=1000 }); approx(info.x_mult, 2)
  local _, i2 = sc('all_in_fanatic', { bet=799, outcome='player', chipsBefore=1000 }); approx(i2.x_mult, 1)
end)
check('bet_sniper 下注 >= 筹码一半且赢 -> ×2', function()
  local _, info = sc('bet_sniper', { bet=500, outcome='player', chipsBefore=1000 }); approx(info.x_mult, 2)
  local _, i2 = sc('bet_sniper', { bet=499, outcome='player', chipsBefore=1000 }); approx(i2.x_mult, 1)
end)
check('chip_magnet 赢 -> ×1.3；输不触发', function()
  local _, info = sc('chip_magnet', { bet=100, outcome='player' }); approx(info.x_mult, 1.3)
  local _, i2 = sc('chip_magnet', { bet=100, outcome='dealer' }); approx(i2.x_mult, 1)
end)
check('all_in_master 全押且赢 -> ×3', function()
  local _, info = sc('all_in_master', { bet=1000, outcome='player', chipsBefore=1000 }); approx(info.x_mult, 3)
  local _, i2 = sc('all_in_master', { bet=999, outcome='player', chipsBefore=1000 }); approx(i2.x_mult, 1)
end)
check('debt_collector_pro 赊账且赢 -> ×1.5', function()
  local _, info = sc('debt_collector_pro', { bet=100, outcome='player', creditUsed=true }); approx(info.x_mult, 1.5)
  local _, i2 = sc('debt_collector_pro', { bet=100, outcome='player', creditUsed=false }); approx(i2.x_mult, 1)
end)
check('streak_master 连胜 >=3 -> ×3', function()
  local _, info = sc('streak_master', { bet=100, outcome='player' }, baseP(), baseD(), { streak=3 }); approx(info.x_mult, 3)
  local _, i2 = sc('streak_master', { bet=100, outcome='player' }, baseP(), baseD(), { streak=2 }); approx(i2.x_mult, 1)
end)
check('streak_hammer 连胜 >=2 -> 倍率 + 连胜数', function()
  local _, i2 = sc('streak_hammer', { bet=100, outcome='player' }, baseP(), baseD(), { streak=2 }); eq(i2.mult, 3)
  local _, i5 = sc('streak_hammer', { bet=100, outcome='player' }, baseP(), baseD(), { streak=5 }); eq(i5.mult, 6)
  local _, i1 = sc('streak_hammer', { bet=100, outcome='player' }, baseP(), baseD(), { streak=1 }); eq(i1.mult, 1)
end)
check('stage_champion 阶段 3 -> ×1.5', function()
  local _, info = sc('stage_champion', { bet=100, outcome='player', stage=3 }); approx(info.x_mult, 1.5)
  local _, i2 = sc('stage_champion', { bet=100, outcome='player', stage=2 }); approx(i2.x_mult, 1)
end)

-- ===================== 叠加顺序 / 67 组合 =====================
check('叠加：倍率加法、乘区连乘，且与顺序无关', function()
  local ids = { 'mult_ring', 'gold_charm', 'super_mult', 'divine_blessing', 'chip_magnet' }
  local rev = { 'chip_magnet', 'divine_blessing', 'super_mult', 'gold_charm', 'mult_ring' }
  local _, info, w = run(ids, baseP(), baseD(), { streak=0 }, { bet=100, outcome='player' })
  eq(info.mult, 7)                    -- 1 + 1 + 2 + 3
  approx(info.x_mult, 1.2 * 1.3)      -- 连乘
  eq(info.additive, 200)
  eq(w, 2184)                         -- floor(200 * 7 * 1.56)
  local _, info2, w2 = run(rev, baseP(), baseD(), { streak=0 }, { bet=100, outcome='player' })
  eq(info2.mult, 7); eq(w2, w)
end)
check('67 组合：x_mult 之后额外 ×67（优先级最高）', function()
  local _, info, w = run('chip_magnet', baseP(), baseD(), { streak=0 }, { bet=100, outcome='player', is67=true })
  eq(info.mult, 1); approx(info.x_mult, 1.3 * 67); eq(info.additive, 200); eq(w, 17420)
end)
check('67 组合与倍率叠加：winnings = floor(add * mult * x * 67)', function()
  local _, info, w = run({ 'mult_ring', 'divine_blessing' }, baseP(), baseD(), { streak=0 }, { bet=100, outcome='player', is67=true })
  eq(info.mult, 2); approx(info.x_mult, 1.2 * 67)
  local x = 1.2 * 67
  eq(w, math.floor(200 * 2 * x))   -- 与 finalize 相同的乘法顺序
end)

-- ===================== 22 规则（scoreHandlers，经真实 GS 安装） =====================
local GS = require('src.game_state')
local function mkRng(seed)
  local s = seed or 7
  return function(a, b)
    s = (s * 1103515245 + 12345) % 2147483648
    if a == nil then return s / 2147483648 end
    return a + (s % (b - a + 1))
  end
end
local function memfs() return { read = function() end, write = function() return true end } end
local function newG()
  local g = GS.new({ rng = mkRng(20261212), filesystem = memfs() })
  g.state.relicSlotMax = 99
  return g
end
local function give(g, ids) for _, id in ipairs(ids) do assert(g:addRelic(R.byId(id)), 'addRelic ' .. id) end end

check('soft_22_safe 软 22（含 A、A=11 计 22）改判平局并扣次', function()
  local g = newG(); give(g, { 'soft_22_safe' })
  local p = { hand = hand({'AS','5H','6D'}), total = 22, busted = true }
  local d = { hand = hand({'KH','7H'}), total = 17, busted = false }
  local ctx = S.newCtx(p, d, g.state, { outcome='dealer', bet=100 }); ctx.gs = g
  S.run(ctx, g:activeRelics(), g.scoreHandlers, g)
  local _, info = S.finalize(ctx)
  eq(info.outcome, 'push'); eq(g:relicById('soft_22_safe').usesLeft, 2)
end)
check('soft_22_safe 无 A 的 22 不算软 22，不误伤', function()
  local g = newG(); give(g, { 'soft_22_safe' })
  local p = { hand = hand({'10S','6H','6D'}), total = 22, busted = true }
  local d = { hand = hand({'KH','7H'}), total = 17, busted = false }
  local ctx = S.newCtx(p, d, g.state, { outcome='dealer', bet=100 }); ctx.gs = g
  S.run(ctx, g:activeRelics(), g.scoreHandlers, g)
  local _, info = S.finalize(ctx)
  eq(info.outcome, 'dealer'); eq(g:relicById('soft_22_safe').usesLeft, 3)
end)
check('soft_bust_shield 软 22 直接判赢并扣次', function()
  local g = newG(); give(g, { 'soft_bust_shield' })
  local p = { hand = hand({'AS','5H','6D'}), total = 22, busted = true }
  local d = { hand = hand({'KH','7H'}), total = 17, busted = false }
  local ctx = S.newCtx(p, d, g.state, { outcome='dealer', bet=100 }); ctx.gs = g
  S.run(ctx, g:activeRelics(), g.scoreHandlers, g)
  local _, info = S.finalize(ctx)
  eq(info.outcome, 'player'); eq(g:relicById('soft_bust_shield').usesLeft, 2)
end)

print(string.format('scoring_acceptance: PASS=%d FAIL=%d', pass, #failures))
if #failures > 0 then error('scoring_acceptance failed: ' .. #failures) end
