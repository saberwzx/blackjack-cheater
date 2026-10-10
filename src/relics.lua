-- src/relics.lua 遗物完整定义（139 件）
-- 元数据（id/name/rarity/price）来自 docs/gdd-relics.json（父代理按附录 A 逐项生成，139 件，稀有度 2/29/57/51）。
-- 效果由本文件 fx / special 提供；special 由 game_state 分发。未实现者 approx=true 并记入 docs/core-gaps.md。
local R = {}
R.LIST = {}
R.MAP = {}
R.unsupported = {}
R.POOL_EXCLUDED = {
  deck_weight_low = true, deck_weight_high = true,
  exclusive_supreme = true, seclusion = true,
}
R.TRIGGER_COUNTS = { on_score_calc = 44, on_hit = 14, on_deal = 6, on_bet = 5 }

local function def(t)
  R.LIST[#R.LIST + 1] = t
  R.MAP[t.id] = t
  return t
end

-- ---------- 结算辅助 ----------
local function sc(ctx) return ctx.score end
local function mark(ctx)
  if ctx.engine and ctx.engine.markRelicActive then ctx.engine:markRelicActive(ctx.def and ctx.def.id) end
end
local function note(ctx, kind, value)
  if ctx.score and ctx.score.breakdown then
    ctx.score.breakdown[#ctx.score.breakdown + 1] = { label = (ctx.def and ctx.def.name) or '', kind = kind, value = value }
  end
end
local function m(ctx, v)
  if not v or v == 0 then return end
  sc(ctx).mult = sc(ctx).mult + v; note(ctx, 'mult', v); mark(ctx)
end
local function x(ctx, v)
  if not v or v == 1 then return end
  sc(ctx).x_mult = sc(ctx).x_mult * v; note(ctx, 'x_mult', v); mark(ctx)
end
local function ch(ctx, v)
  if not v or v == 0 then return end
  sc(ctx).chips = sc(ctx).chips + v; note(ctx, 'chips', v); mark(ctx)
end
local function ph(ctx) return (ctx.player and ctx.player.hand) or {} end
local function dh(ctx) return (ctx.dealer and ctx.dealer.hand) or {} end
local function cr(ctx, r)
  local n = 0
  for _, c in ipairs(ph(ctx)) do if c.rank == r then n = n + 1 end end
  return n
end
local function hr(ctx, r) return cr(ctx, r) > 0 end
local function hasAny(ctx, list)
  for _, r in ipairs(list) do if hr(ctx, r) then return true end end
  return false
end
local function hasAce(ctx) return hr(ctx, 'A') end
local function hasTen(ctx)
  for _, c in ipairs(ph(ctx)) do
    if c.rank == '10' or c.rank == 'J' or c.rank == 'Q' or c.rank == 'K' then return true end
  end
  return false
end
local function isNatural(ctx) return ctx.player and ctx.player.blackjack end
local function total(ctx) return (ctx.player and ctx.player.total) or 0 end
-- A 算 1 的点数和（GDD：精准 12 用 A=1 计）
local function totalA1(ctx)
  local s = 0
  for _, c in ipairs(ph(ctx)) do
    if c.rank == 'A' and c.value == nil then
      s = s + 1
    elseif c.value ~= nil then
      s = s + c.value
    elseif c.rank == '10' or c.rank == 'J' or c.rank == 'Q' or c.rank == 'K' then
      s = s + 10
    else
      s = s + (tonumber(c.rank) or 0)
    end
  end
  return s
end
local function dtotal(ctx) return (ctx.dealer and ctx.dealer.total) or 0 end
local function dup(ctx)
  local h = dh(ctx); local c = h[2]
  if not c then return 0 end
  if c.rank == 'A' then return 11 end
  if c.rank == '10' or c.rank == 'J' or c.rank == 'Q' or c.rank == 'K' then return 10 end
  return tonumber(c.rank) or 0
end
local function countSuits(ctx)
  local counts, maxn = {}, 0
  for _, c in ipairs(ph(ctx)) do
    if c.suit then
      counts[c.suit] = (counts[c.suit] or 0) + 1
      if counts[c.suit] > maxn then maxn = counts[c.suit] end
    end
  end
  return maxn
end
local function fourSuits(ctx)
  local s = {}
  for _, c in ipairs(ph(ctx)) do if c.suit then s[c.suit] = true end end
  return s.S and s.H and s.D and s.C
end
local function pair(ctx)
  local h = ph(ctx)
  if #h ~= 2 then return false end
  local a, b = h[1].rank, h[2].rank
  local function t(z) if z == 'J' or z == 'Q' or z == 'K' then return '10' end return z end
  return t(a) == t(b)
end
local function win(ctx) return ctx.outcome == 'player' end
local function loseO(ctx) return ctx.outcome == 'dealer' end
local function pushO(ctx) return ctx.outcome == 'push' end
local function streak(ctx) return (ctx.state and ctx.state.streak) or 0 end
local function chipsBefore(ctx) return ctx.chipsBefore or ctx.chips or 0 end
local function forceWin(ctx) if ctx.api and ctx.api.forcePlayerWin then ctx.api.forcePlayerWin() end end
local function pushIt(ctx) ctx.forceResult = 'push' end

R.helpers = { m = m, x = x, ch = ch, ph = ph, dh = dh, cr = cr, hr = hr, hasAny = hasAny, hasAce = hasAce, hasTen = hasTen, isNatural = isNatural, total = total, totalA1 = totalA1, dtotal = dtotal, dup = dup, pair = pair, win = win, loseO = loseO, pushO = pushO, streak = streak, chipsBefore = chipsBefore, fourSuits = fourSuits, countSuits = countSuits }

def({ id='mult_ring', name='倍率戒指', desc='每局倍率 +1', spec='on_score_calc | 永久 | 每局倍率 +1', rarity='uncommon', price=1200, line=1250, trigger='on_score_calc', kind='mult', group='score', fx=function(ctx) m(ctx,1) end })
def({ id='gold_charm', name='黄金幸运符', desc='每局倍率 +2', spec='on_score_calc | 永久 | 每局倍率 +2', rarity='rare', price=1400, line=1251, trigger='on_score_calc', kind='mult', group='score', fx=function(ctx) m(ctx,2) end })
def({ id='super_mult', name='超级倍率', desc='每局倍率 +3', spec='on_score_calc | 永久 | 每局倍率 +3', rarity='legendary', price=1800, line=1252, trigger='on_score_calc', kind='mult', group='score', fx=function(ctx) m(ctx,3) end })
def({ id='divine_blessing', name='神之保佑', desc='每局最终 ×1.2', spec='on_score_calc | 永久 | 每局最终 ×1.2', rarity='legendary', price=1800, line=1253, trigger='on_score_calc', kind='x_mult', group='score', fx=function(ctx) x(ctx,1.2) end })
def({ id='perfect_21', name='完美 21', desc='恰好 21 点（非自然）时最终 ×2', spec='on_score_calc | 永久 | 恰好 21 点（非自然）时最终 ×2', rarity='legendary', price=1800, line=1259, trigger='on_score_calc', kind='x_mult', group='score', fx=function(ctx) if total(ctx)==21 and not isNatural(ctx) then x(ctx,2) end end })
def({ id='twentyone_supreme', name='21 至尊', desc='恰好 21 点直接判该阶段胜利，奖励等同阶段目标的筹码并立刻转阶段（不占本局计数）', spec='on_score_calc | **1×** | 恰好 21 点直接判该阶段胜利，奖励等同阶段目标的筹码并立刻转阶段（不占本局计数）', rarity='legendary', price=800, line=1260, trigger='on_score_calc', kind='special', group='score', consumes=true, uses=1, special='stage_win' })
def({ id='ace_and_ten_exact', name='精准 12', desc='点数恰好 12（A 算 1）时倍率 +20', spec='on_score_calc | 永久 | 点数恰好 12（A 算 1）时倍率 +20', rarity='rare', price=1200, line=1261, trigger='on_score_calc', kind='mult', group='score', fx=function(ctx) if totalA1(ctx)==12 then m(ctx,20) end end })
def({ id='fives_15', name='三个 5', desc='手牌 ≥3 张 5 时倍率 +30', spec='on_score_calc | 永久 | 手牌 ≥3 张 5 时倍率 +30', rarity='legendary', price=1520, line=1262, trigger='on_score_calc', kind='mult', group='score', fx=function(ctx) if cr(ctx,"5")>=3 then m(ctx,30) end end })
def({ id='low_buff', name='低牌 buff', desc='手牌含 3/4/5 时倍率 +2', spec='on_score_calc | 永久 | 手牌含 3/4/5 时倍率 +2', rarity='rare', price=1400, line=1263, trigger='on_score_calc', kind='mult', group='score', fx=function(ctx) if hasAny(ctx,{"3","4","5"}) then m(ctx,2) end end })
def({ id='dealer_mirror_17', name='庄家跟牌', desc='你的点数等于庄家明牌点数时倍率 +3', spec='on_score_calc | 永久 | 你的点数等于庄家明牌点数时倍率 +3', rarity='rare', price=1400, line=1264, trigger='on_score_calc', kind='mult', group='score', fx=function(ctx) if total(ctx)==dup(ctx) then m(ctx,3) end end })
def({ id='blackjack_master', name='Blackjack 大师', desc='自然 21 时最终 ×5', spec='on_score_calc | 自然 21 时最终 ×5', rarity='legendary', price=1800, line=1270, trigger='on_score_calc', kind='x_mult', group='score', fx=function(ctx) if isNatural(ctx) then x(ctx,5) end end })
def({ id='bj_insurance', name='Blackjack 保险', desc='自然 21 不会被庄家反超（强制判胜）', spec='on_score_calc | 自然 21 不会被庄家反超（强制判胜）', rarity='legendary', price=1400, line=1271, trigger='on_score_calc', kind='special', group='score', fx=function(ctx) if isNatural(ctx) then forceWin(ctx) end end })
def({ id='pair_boost', name='对拍加成', desc='有对子时倍率 +3（10/J/Q/K 互为同点）', spec='on_score_calc | 有对子时倍率 +3（10/J/Q/K 互为同点）', rarity='rare', price=1400, line=1277, trigger='on_score_calc', kind='mult', group='score', fx=function(ctx) if pair(ctx) then m(ctx,3) end end })
def({ id='pair_royalty', name='对子皇家', desc='两张同点数 J/Q/K 时倍率 +8', spec='on_score_calc | 两张同点数 J/Q/K 时倍率 +8', rarity='rare', price=1200, line=1278, trigger='on_score_calc', kind='mult', group='score', fx=function(ctx) local h=ph(ctx); if #h==2 then local a,b=h[1].rank,h[2].rank; local f=function(z) return z=="J" or z=="Q" or z=="K" end; if f(a) and a==b then m(ctx,8) end end end })
def({ id='flush_master', name='同花大师', desc='4+ 张同花色时最终 ×2', spec='on_score_calc | 4+ 张同花色时最终 ×2', rarity='legendary', price=1800, line=1279, trigger='on_score_calc', kind='x_mult', group='score', fx=function(ctx) if countSuits(ctx)>=4 then x(ctx,2) end end })
def({ id='double_seven', name='双七', desc='手牌有 2 张 7 时倍率 +15', spec='on_score_calc | 手牌有 2 张 7 时倍率 +15', rarity='rare', price=1260, line=1280, trigger='on_score_calc', kind='mult', group='score', fx=function(ctx) if cr(ctx,"7")>=2 then m(ctx,15) end end })
def({ id='rainbow_21', name='彩虹 21', desc='恰好 21 且四种花色齐全时最终 ×2', spec='on_score_calc | 恰好 21 且四种花色齐全时最终 ×2', rarity='legendary', price=1800, line=1281, trigger='on_score_calc', kind='x_mult', group='score', fx=function(ctx) if total(ctx)==21 and fourSuits(ctx) then x(ctx,2) end end })
def({ id='clockwork_dragon', name='发条龙', desc='同时含 A 与 10 点牌且非自然 21 时最终 ×10', spec='on_score_calc | 同时含 A 与 10 点牌且非自然 21 时最终 ×10', rarity='legendary', price=1800, line=1282, trigger='on_score_calc', kind='x_mult', group='score', fx=function(ctx) if hasAce(ctx) and hasTen(ctx) and not isNatural(ctx) then x(ctx,10) end end })
def({ id='push_king', name='平局之王', desc='平局时倍率 +2 且筹码 +300', spec='on_score_calc | 平局时倍率 +2 且筹码 +300', rarity='rare', price=1400, line=1288, trigger='on_score_calc', kind='mult', group='score', fx=function(ctx) if pushO(ctx) then m(ctx,2); ch(ctx,300) end end })
def({ id='push_as_win', name='平局即胜', desc='平局判为玩家赢', spec='on_score_calc | 平局判为玩家赢', rarity='legendary', price=1800, line=1289, trigger='on_score_calc', kind='special', group='score', fx=function(ctx) if pushO(ctx) then forceWin(ctx) end end })
def({ id='dealer_22_push', name='庄家 22 平局', desc='庄家恰 22 点且玩家 ≤21 时算平局', spec='on_score_calc·被动 | 庄家恰 22 点且玩家 ≤21 时算平局', rarity='rare', price=1200, line=1290, trigger='on_score_calc', kind='special', group='score', fx=function(ctx) if dtotal(ctx)==22 and total(ctx)<=21 then pushIt(ctx) end end })
def({ id='insurance_master', name='保险大师', desc='庄家明 A 且本局输 → 只输一半', spec='on_score_calc·被动 | 庄家明 A 且本局输 → 只输一半', rarity='rare', price=1200, line=1291, trigger='on_score_calc', kind='special', group='score', fx=function(ctx) if ctx.dealerUpAce and loseO(ctx) then ctx.halfLoss=true end end })
def({ id='first_hit_safe', name='第一次 Hit 安全', desc='本小局第一次要牌不会爆牌', spec='on_hit | 3× | 本小局第一次要牌不会爆牌', rarity='rare', price=200, line=1297, trigger='on_hit', kind='special', group='protection', consumes=true, uses=3, special='first_hit_safe' })
def({ id='bust_shield', name='爆牌护盾', desc='爆牌时改判平局并退还下注', spec='on_score_calc | 3× | 爆牌时改判平局并退还下注', rarity='legendary', price=400, line=1298, trigger='on_score_calc', kind='special', group='protection', consumes=true, uses=3, fx=function(ctx) if ctx.player.busted then pushIt(ctx); if ctx.gs then ctx.gs:consumeRelic('bust_shield') end end end })
def({ id='soft_22_safe', name='软爆护盾', desc='22 点不算爆，按正常规则与庄家比大小', spec='on_score_calc | 3× | 22 点不算爆，按正常规则与庄家比大小', rarity='rare', price=200, line=1299, trigger='on_score_calc', kind='special', group='protection', consumes=true, uses=3, special='soft_22_safe' })
def({ id='soft_bust_shield', name='软爆护盾 v2', desc='22 点直接判赢', spec='on_score_calc | 3× | 22 点直接判赢', rarity='legendary', price=400, line=1300, trigger='on_score_calc', kind='special', group='protection', consumes=true, uses=3, special='soft_22_win' })
def({ id='last_card_save', name='最后一张救命', desc='要牌会爆时自动换成不超过 21 的安全牌（已 21 点则不干预、不扣次）', spec='on_hit | 3× | 要牌会爆时自动换成不超过 21 的安全牌（已 21 点则不干预、不扣次）', rarity='legendary', price=520, line=1301, trigger='on_hit', kind='special', group='protection', consumes=true, uses=3, special='last_card_save' })
def({ id='ace_blessing', name='A 之祝福', desc='手牌每张 A 倍率 +1', spec='on_score_calc | 永久 | 手牌每张 A 倍率 +1', rarity='rare', price=1400, line=1309, trigger='on_score_calc', kind='mult', group='deal', fx=function(ctx) m(ctx, cr(ctx,"A")) end })
def({ id='ace_guarantee', name='A 之保证', desc='发牌第一张总是 A♠', spec='on_deal·Pre | 永久 | 发牌第一张总是 A♠', rarity='legendary', price=1400, line=1310, trigger='on_deal', kind='special', group='deal', pre=true, special='ace_guarantee' })
def({ id='ace_magnet', name='A 磁铁', desc='每次要牌 12% 概率直接给一张 A', spec='on_hit | 永久 | 每次要牌 12% 概率直接给一张 A', rarity='rare', price=1200, line=1311, trigger='on_hit', kind='special', group='deal', special='ace_magnet', param1=0.12 })
def({ id='ace_revolution', name='A 之革命', desc='你的 A 永远算 11 点（不降级，更容易爆）；67 组合优先', spec='on_score_calc | 永久 | 你的 A 永远算 11 点（不降级，更容易爆）；67 组合优先', rarity='legendary', price=1800, line=1312, trigger='on_score_calc', kind='special', group='deal', special='ace_revolution' })
def({ id='second_ace', name='第二张 A', desc='发牌后第二张有 40% 概率变成 A♣', spec='on_deal_after·Pre | 永久 | 发牌后第二张有 40% 概率变成 A♣', rarity='rare', price=1200, line=1313, trigger='on_deal_after', kind='special', group='deal', pre=true, special='second_ace', param1=0.4 })
def({ id='ten_guarantee', name='10 点保证', desc='发牌第二张总是 10/J/Q/K（随机）', spec='on_deal·Pre | 永久 | 发牌第二张总是 10/J/Q/K（随机）', rarity='rare', price=1260, line=1314, trigger='on_deal', kind='special', group='deal', pre=true, special='ten_guarantee' })
def({ id='ten_magnet', name='10 点磁铁', desc='每次要牌 38% 概率给一张 10 点牌', spec='on_hit | 永久 | 每次要牌 38% 概率给一张 10 点牌', rarity='rare', price=1200, line=1315, trigger='on_hit', kind='special', group='deal', special='ten_magnet', param1=0.38 })
def({ id='ten_spotlight', name='10 点聚光灯', desc='手牌含 10/J/Q/K 时倍率 +1', spec='on_score_calc | 永久 | 手牌含 10/J/Q/K 时倍率 +1', rarity='uncommon', price=1100, line=1316, trigger='on_score_calc', kind='mult', group='score', fx=function(ctx) if hasTen(ctx) then m(ctx,1) end end })
def({ id='jackpot_two', name='JQK 配对', desc='第一张是 J/Q/K 时第二张也换成 J/Q/K', spec='on_deal_after·Pre | 永久 | 第一张是 J/Q/K 时第二张也换成 J/Q/K', rarity='rare', price=1200, line=1317, trigger='on_deal_after', kind='special', group='deal', pre=true, special='jackpot_two' })
def({ id='always_10_on_third', name='第三张必 10', desc='你的第三张牌总是 10♣', spec='on_hit | 永久 | 你的第三张牌总是 10♣', rarity='rare', price=1200, line=1323, trigger='on_hit', kind='special', group='control', special='third_ten' })
def({ id='auto_surrender_16', name='16 自动停牌', desc='点数 ≥16 时，要牌自动改为停牌（不再抽牌）', spec='on_hit | 永久 | 点数 ≥16 时，要牌自动改为停牌（不再抽牌）', rarity='uncommon', price=1100, line=1324, trigger='on_hit', kind='special', group='control', special='auto_stand_16' })
def({ id='peek_and_chase', name='牌堆追踪', desc='每次要牌 30% 概率直接给一张 10', spec='on_hit | 永久 | 每次要牌 30% 概率直接给一张 10', rarity='rare', price=1200, line=1325, trigger='on_hit', kind='special', group='control', special='chase_ten', param1=0.3 })
def({ id='soft_hand_magnet', name='软手磁铁', desc='每次要牌 25% 概率给一张 A', spec='on_hit | 永久 | 每次要牌 25% 概率给一张 A', rarity='rare', price=1260, line=1326, trigger='on_hit', kind='special', group='control', special='chase_ace', param1=0.25 })
def({ id='hit_to_20', name='凑 20 为止', desc='点数 <20 且手牌 ≤3 张时，给一张恰好凑到 20 的牌', spec='on_hit | 永久 | 点数 <20 且手牌 ≤3 张时，给一张恰好凑到 20 的牌', rarity='rare', price=1260, line=1327, trigger='on_hit', kind='special', group='control', special='hit_to_20' })
def({ id='pair_to_21', name='对子凑 21', desc='有对子时给一张尽量凑到 21 的牌（点数太低时只加 10）', spec='on_hit | 永久 | 有对子时给一张尽量凑到 21 的牌（点数太低时只加 10）', rarity='rare', price=1260, line=1328, trigger='on_hit', kind='special', group='control', special='pair_to_21' })
def({ id='eight_ball', name='八球幸运', desc='手牌有 8 时，下次要牌必给 10', spec='on_hit | 永久 | 手牌有 8 时，下次要牌必给 10', rarity='uncommon', price=1100, line=1329, trigger='on_hit', kind='special', group='control', special='eight_ball' })
def({ id='black_hole', name='黑洞', desc='本小局下一次要牌时吸收位于第一位置的牌（激活状态每小局重置，需重新点亮）', spec='on_hit | 永久 | 本小局下一次要牌时吸收位于第一位置的牌（激活状态每小局重置，需重新点亮）', rarity='legendary', price=1400, line=1330, trigger='on_hit', kind='special', group='control', special='black_hole_absorb' })
def({ id='card_pack', name='卡包', desc='卡包空时下次要牌存入；卡包有牌时下次要牌取出寄存那张（寄存内容在状态栏显示，跨小局保留）', spec='on_hit | 永久 | 卡包空时下次要牌存入；卡包有牌时下次要牌取出寄存那张（寄存内容在状态栏显示，跨小局保留）', rarity='legendary', price=1400, line=1331, trigger='on_hit', kind='special', group='control', special='card_pack' })
def({ id='give_card_8', name='给牌 · 8', desc='下次要牌强制给 8 点（花色随机）', spec='on_hit | 2× | 下次要牌强制给 8 点（花色随机）', rarity='uncommon', price=100, line=1337, trigger='on_hit', kind='special', group='give', consumes=true, uses=2, special='give_card', param1=8 })
def({ id='give_card_7', name='给牌 · 7', desc='强制给 7 点', spec='on_hit | 2× | 强制给 7 点', rarity='uncommon', price=150, line=1338, trigger='on_hit', kind='special', group='give', consumes=true, uses=2, special='give_card', param1=7 })
def({ id='give_card_6', name='给牌 · 6', desc='强制给 6 点', spec='on_hit | 2× | 强制给 6 点', rarity='uncommon', price=200, line=1339, trigger='on_hit', kind='special', group='give', consumes=true, uses=2, special='give_card', param1=6 })
def({ id='give_card_5', name='给牌 · 5', desc='强制给 5 点', spec='on_hit | 2× | 强制给 5 点', rarity='uncommon', price=250, line=1340, trigger='on_hit', kind='special', group='give', consumes=true, uses=2, special='give_card', param1=5 })
def({ id='give_card_4', name='给牌 · 4', desc='强制给 4 点', spec='on_hit | 2× | 强制给 4 点', rarity='uncommon', price=300, line=1341, trigger='on_hit', kind='special', group='give', consumes=true, uses=2, special='give_card', param1=4 })
def({ id='give_card_3', name='给牌 · 3', desc='强制给 3 点', spec='on_hit | 2× | 强制给 3 点', rarity='uncommon', price=350, line=1342, trigger='on_hit', kind='special', group='give', consumes=true, uses=2, special='give_card', param1=3 })
def({ id='give_card_2', name='给牌 · 2', desc='强制给 2 点', spec='on_hit | 2× | 强制给 2 点', rarity='uncommon', price=400, line=1343, trigger='on_hit', kind='special', group='give', consumes=true, uses=2, special='give_card', param1=2 })
def({ id='deck_weight_low', name='低牌加重', desc='发牌前两张优先抽 2-6', spec='on_deal·Pre | ⛔ | 发牌前两张优先抽 2-6', rarity='uncommon', price=1100, line=1351, trigger='on_deal', kind='special', group='excluded', pre=true, noPool=true, approx=true, special='excluded' })
def({ id='deck_weight_high', name='高牌加重', desc='发牌前两张优先抽 10/J/Q/K/A', spec='on_deal·Pre | ⛔ | 发牌前两张优先抽 10/J/Q/K/A', rarity='uncommon', price=1100, line=1352, trigger='on_deal', kind='special', group='excluded', pre=true, noPool=true, approx=true, special='excluded' })
def({ id='exclusive_supreme', name='独享至尊', desc='本小局只有你能抽到特殊牌组的牌，庄家只能抽固有牌', spec='on_round_start·被动 | ⛔ | 本小局只有你能抽到特殊牌组的牌，庄家只能抽固有牌', rarity='legendary', price=1400, line=1353, trigger='on_round_start', kind='special', group='excluded', pre=true, noPool=true, approx=true, special='excluded' })
def({ id='seclusion', name='闭关', desc='本小局只有庄家能抽到特殊牌组的牌，你只能抽固有牌', spec='on_round_start·被动 | ⛔ | 本小局只有庄家能抽到特殊牌组的牌，你只能抽固有牌', rarity='common', price=1050, line=1354, trigger='on_round_start', kind='special', group='excluded', pre=true, noPool=true, approx=true, special='excluded' })
def({ id='dealer_killer', name='庄家克星', desc='庄家爆牌时筹码 +1000', spec='on_score_calc | 永久 | 庄家爆牌时筹码 +1000', rarity='rare', price=1200, line=1360, trigger='on_score_calc', kind='chips', group='score', fx=function(ctx) if ctx.dealer.busted then ch(ctx,1000) end end })
def({ id='steal_money', name='偷金之手', desc='庄家爆牌时最终 ×1.2', spec='on_score_calc | 永久 | 庄家爆牌时最终 ×1.2', rarity='legendary', price=1800, line=1361, trigger='on_score_calc', kind='x_mult', group='score', fx=function(ctx) if ctx.dealer.busted then x(ctx,1.2) end end })
def({ id='coward_curse', name='胆小鬼诅咒', desc='庄家点数恰为 17 时倍率 +2', spec='on_score_calc | 永久 | 庄家点数恰为 17 时倍率 +2', rarity='uncommon', price=1200, line=1362, trigger='on_score_calc', kind='mult', group='dealer', fx=function(ctx) if dtotal(ctx)==17 then m(ctx,2) end end })
def({ id='dealer_fatigue', name='庄家疲劳', desc='庄家点数 ≥17 即停（覆盖经典的软 17 继续）', spec='on_dealer_turn·被动 | 永久 | 庄家点数 ≥17 即停（覆盖经典的软 17 继续）', rarity='rare', price=1200, line=1363, trigger='on_dealer_turn', kind='special', group='dealer', pre=true, special='dealer_fatigue' })
def({ id='dealer_blind', name='庄家致盲', desc='庄家看不到你的第二张牌（AI 难度压回 1 档）', spec='on_dealer_turn·被动 | 永久 | 庄家看不到你的第二张牌（AI 难度压回 1 档）', rarity='rare', price=1200, line=1364, trigger='on_dealer_turn', kind='special', group='dealer', pre=true, special='dealer_blind' })
def({ id='anti_cheat', name='反侦察器', desc='阶段 3 时庄家不会看你的牌（读牌 AI 失效）', spec='on_dealer_turn | 永久 | 阶段 3 时庄家不会看你的牌（读牌 AI 失效）', rarity='legendary', price=1400, line=1365, trigger='on_dealer_turn', kind='special', group='dealer', pre=true, special='anti_cheat' })
def({ id='dealer_magnet', name='庄家磁铁', desc='庄家要牌时 55% 概率摸到 2~6 的爆牌牌', spec='on_dealer_hit | 永久 | 庄家要牌时 55% 概率摸到 2~6 的爆牌牌', rarity='legendary', price=1400, line=1366, trigger='on_dealer_hit', kind='special', group='dealer', special='dealer_magnet', param1=0.55 })
def({ id='no_face_dealer', name='庄家无面', desc='庄家摸到 J/Q/K 时自动换成 10', spec='on_dealer_hit | 永久 | 庄家摸到 J/Q/K 时自动换成 10', rarity='legendary', price=1400, line=1367, trigger='on_dealer_hit', kind='special', group='dealer', special='no_face_dealer' })
def({ id='bet_syndicate', name='下注集团', desc='每局下注自动翻倍', spec='on_bet·Pre | 永久 | 每局下注自动翻倍', rarity='rare', price=1260, line=1375, trigger='on_bet', kind='special', group='bet', pre=true, special='double_bet' })
def({ id='bet_minimizer', name='最小下注者', desc='强制下注 $50（多余部分退回筹码，每局都安全）', spec='on_bet·Pre | 永久 | 强制下注 $50（多余部分退回筹码，每局都安全）', rarity='uncommon', price=1100, line=1376, trigger='on_bet', kind='special', group='bet', pre=true, special='force_min_bet' })
def({ id='late_surrender', name='后期投降', desc='点亮后点数 <18 可投降，退回一半下注', spec='—（玩家动作 U） | 永久 | 点亮后点数 <18 可投降，退回一半下注', rarity='rare', price=1200, line=1377, trigger='active', kind='special', group='bet', special='late_surrender' })
def({ id='conservative_bet', name='保守策略', desc='下注 ≤$100 且赢时倍率 +3', spec='on_score_calc | 下注 ≤$100 且赢时倍率 +3', rarity='uncommon', price=1200, line=1383, trigger='on_score_calc', kind='mult', group='score', fx=function(ctx) if win(ctx) and ctx.bet<=100 then m(ctx,3) end end })
def({ id='balanced_bet', name='平衡策略', desc='下注 $200~$500 且赢时倍率 +5', spec='on_score_calc | 下注 $200~$500 且赢时倍率 +5', rarity='rare', price=1400, line=1384, trigger='on_score_calc', kind='mult', group='score', fx=function(ctx) if win(ctx) and ctx.bet>=200 and ctx.bet<=500 then m(ctx,5) end end })
def({ id='small_bet_master', name='小额大师', desc='下注恰为 $50 且赢时倍率 +4 且筹码 +1000', spec='on_score_calc | 下注恰为 $50 且赢时倍率 +4 且筹码 +1000', rarity='rare', price=1400, line=1385, trigger='on_score_calc', kind='mult', group='score', fx=function(ctx) if win(ctx) and ctx.bet==50 then m(ctx,4); ch(ctx,1000) end end })
def({ id='aggressive_bet', name='豪赌策略', desc='下注 ≥$500 且赢时最终 ×1.5', spec='on_score_calc | 下注 ≥$500 且赢时最终 ×1.5', rarity='legendary', price=1800, line=1386, trigger='on_score_calc', kind='x_mult', group='score', fx=function(ctx) if win(ctx) and ctx.bet>=500 then x(ctx,1.5) end end })
def({ id='all_in_fanatic', name='全押狂魔', desc='下注 ≥80% 筹码且赢时最终 ×2', spec='on_score_calc | 下注 ≥80% 筹码且赢时最终 ×2', rarity='legendary', price=1800, line=1387, trigger='on_score_calc', kind='x_mult', group='score', fx=function(ctx) if win(ctx) and ctx.bet>=0.8*chipsBefore(ctx) then x(ctx,2) end end })
def({ id='bet_sniper', name='下注狙击手', desc='下注 ≥ 筹码一半且赢时最终 ×2', spec='on_score_calc | 下注 ≥ 筹码一半且赢时最终 ×2', rarity='legendary', price=1800, line=1388, trigger='on_score_calc', kind='x_mult', group='score', fx=function(ctx) if win(ctx) and ctx.bet>=chipsBefore(ctx)/2 then x(ctx,2) end end })
def({ id='chip_magnet', name='筹码磁铁', desc='赢时最终 ×1.3', spec='on_score_calc | 赢时最终 ×1.3', rarity='legendary', price=1800, line=1389, trigger='on_score_calc', kind='x_mult', group='score', fx=function(ctx) if win(ctx) then x(ctx,1.3) end end })
def({ id='all_in_master', name='全押大师', desc='全押（下注 = 全部筹码）且赢时最终 ×3', spec='on_score_calc | 全押（下注 = 全部筹码）且赢时最终 ×3', rarity='legendary', price=1800, line=1390, trigger='on_score_calc', kind='x_mult', group='score', fx=function(ctx) if win(ctx) and ctx.bet>=chipsBefore(ctx) then x(ctx,3) end end })
def({ id='credit_line', name='信用额度', desc='允许下注超出筹码，总额上限 = 筹码的 3 倍；输成负数立即退出', spec='on_bet·Pre | 允许下注超出筹码，总额上限 = 筹码的 3 倍；输成负数立即退出', rarity='legendary', price=1400, line=1396, trigger='on_bet', kind='special', group='credit', pre=true, special='credit', param1=2 })
def({ id='all_in_fanatic_rel', name='赌徒信条', desc='允许赊账，总额上限 = 筹码的 4 倍；输成负数立即退出', spec='on_bet·Pre | 允许赊账，总额上限 = 筹码的 4 倍；输成负数立即退出', rarity='legendary', price=1400, line=1397, trigger='on_bet', kind='special', group='credit', pre=true, special='credit', param1=3 })
def({ id='high_roller', name='豪客特权', desc='允许赊账，额外 +$5,000 固定额度；输成负数立即退出', spec='on_bet·Pre | 允许赊账，额外 +$5,000 固定额度；输成负数立即退出', rarity='legendary', price=1400, line=1398, trigger='on_bet', kind='special', group='credit', pre=true, special='credit', param1=0, param2=5000 })
def({ id='debt_collector_pro', name='债主代理人', desc='用赊账下注且赢时最终 ×1.5', spec='on_score_calc | 用赊账下注且赢时最终 ×1.5', rarity='legendary', price=1800, line=1399, trigger='on_score_calc', kind='x_mult', group='score', fx=function(ctx) if win(ctx) and ctx.creditUsed then x(ctx,1.5) end end })
def({ id='streak_master', name='连胜之王', desc='连胜 ≥3 时最终 ×3', spec='on_score_calc | 连胜 ≥3 时最终 ×3', rarity='legendary', price=1800, line=1405, trigger='on_score_calc', kind='x_mult', group='score', fx=function(ctx) if streak(ctx)>=3 then x(ctx,3) end end })
def({ id='streak_hammer', name='连胜铁锤', desc='连胜 ≥2 时倍率 +（当前连胜数）', spec='on_score_calc | 连胜 ≥2 时倍率 +（当前连胜数）', rarity='legendary', price=1800, line=1406, trigger='on_score_calc', kind='mult', group='score', fx=function(ctx) if streak(ctx)>=2 then m(ctx, streak(ctx)) end end })
def({ id='stage_champion', name='阶段冠军', desc='阶段 3 时最终 ×1.5', spec='on_score_calc | 阶段 3 时最终 ×1.5', rarity='legendary', price=1800, line=1407, trigger='on_score_calc', kind='x_mult', group='score', fx=function(ctx) if ctx.stage==3 then x(ctx,1.5) end end })
def({ id='stage_survivor', name='阶段幸存者', desc='阶段完成时额外奖励 $2,000', spec='on_stage_clear·Pre | 阶段完成时额外奖励 $2,000', rarity='rare', price=1200, line=1408, trigger='on_stage_clear', kind='special', group='flow', pre=true, special='stage_bonus', param1=2000 })
def({ id='debt_collector', name='债务收藏家', desc='每阶段开始借你 $5,000，但输掉一局时先扣掉这笔债', spec='on_stage_start·Pre | 每阶段开始借你 $5,000，但输掉一局时先扣掉这笔债', rarity='uncommon', price=1100, line=1409, trigger='on_stage_start', kind='special', group='flow', pre=true, special='debt_borrow', param1=5000 })
def({ id='ink_thief', name='墨水大盗', desc='墨水标记费用减半（$25/$100/$500，按阶段）', spec='—（被动判定） | 3× | 墨水标记费用减半（$25/$100/$500，按阶段）', rarity='rare', price=200, line=1417, trigger='passive', kind='special', group='cheat', consumes=true, uses=3, special='ink_half' })
def({ id='cheat_consort', name='千门人脉', desc='墨水标记上限 +2（5 → 7）。台子里总有人肯替你兜东西', spec='—（被动） | 永久 | 墨水标记上限 +2（5 → 7）。台子里总有人肯替你兜东西', rarity='legendary', price=1400, line=1418, trigger='passive', kind='special', group='cheat', special='mark_limit_up', param1=2 })
def({ id='sharp_family', name='老千世家', desc='墨水牌被发现时罚金减半，且 50% 概率保住标记', spec='—（被动判定） | 3× | 墨水牌被发现时罚金减半，且 50% 概率保住标记', rarity='rare', price=200, line=1419, trigger='passive', kind='special', group='cheat', consumes=true, uses=3, special='sharp_family' })
def({ id='hedge_fund', name='对冲基金', desc='爆注未中返还一半注；命中时彩金再 ×1.25', spec='—（被动判定） | 3× | 爆注未中返还一半注；命中时彩金再 ×1.25', rarity='legendary', price=400, line=1420, trigger='passive', kind='special', group='cheat', consumes=true, uses=3, special='hedge_fund' })
def({ id='iron_evidence', name='铁证如山', desc='指认成功奖金从 3 倍下注提升至 5 倍', spec='—（被动判定） | 3× | 指认成功奖金从 3 倍下注提升至 5 倍', rarity='rare', price=200, line=1421, trigger='passive', kind='special', group='cheat', consumes=true, uses=3, special='iron_evidence' })
def({ id='mind_memory', name='过目不忘', desc='点亮窥牌遗物时深度额外 +1；算牌师的每局自动窥视也 +1', spec='—（被动判定） | 3× | 点亮窥牌遗物时深度额外 +1；算牌师的每局自动窥视也 +1', rarity='legendary', price=400, line=1422, trigger='passive', kind='special', group='cheat', consumes=true, uses=3, special='mind_memory' })
def({ id='reveal_ink', name='显影墨水', desc='标记的同时立刻亮明被标记的那张牌（本就公开的不消耗次数）', spec='—（被动） | 3× | 标记的同时立刻亮明被标记的那张牌（本就公开的不消耗次数）', rarity='rare', price=800, line=1423, trigger='passive', kind='special', group='cheat', consumes=true, uses=3, special='reveal_ink' })
def({ id='cheat_probe', name='作弊探测器', desc='阶段 2+ 时干扰项不再出现（看到的痕迹一定为真）', spec='on_deal·Pre | 阶段 2+ 时干扰项不再出现（看到的痕迹一定为真）', rarity='uncommon', price=1100, line=1429, trigger='on_deal', kind='special', group='anticheat', pre=true, special='suppress_distractor' })
def({ id='cheat_eye', name='作弊之眼', desc='同上（旧版遗留，当前与探测器重复，见 §22.4 #19）', spec='on_deal·Pre | 同上（旧版遗留，**当前与探测器重复**，见 §22.4 #19）', rarity='rare', price=1200, line=1430, trigger='on_deal', kind='special', group='anticheat', pre=true, special='suppress_distractor' })
def({ id='cheat_buster_1', name='作弊克星', desc='庄家作弊时强制庄家爆牌', spec='on_dealer_turn·被动 | 庄家作弊时强制庄家爆牌', rarity='legendary', price=1800, line=1431, trigger='on_dealer_turn', kind='special', group='anticheat', pre=true, special='cheat_force_bust' })
def({ id='cheat_reverse', name='反作弊器', desc='指认猜对时额外获得 3 倍下注的筹码', spec='on_accuse·被动 | 指认猜对时额外获得 3 倍下注的筹码', rarity='legendary', price=1800, line=1432, trigger='passive', kind='special', group='anticheat', special='accuse_bonus', param1=3 })
def({ id='scales_of_justice', name='公平之秤', desc='指认猜对时额外获得 2 倍下注的筹码', spec='on_accuse | 指认猜对时额外获得 2 倍下注的筹码', rarity='legendary', price=1800, line=1433, trigger='on_accuse', kind='special', group='anticheat', special='accuse_bonus', param1=2 })
def({ id='cheat_sniffer', name='识破大师', desc='指认猜对时额外获得 5 倍下注的筹码', spec='on_accuse | 指认猜对时额外获得 5 倍下注的筹码', rarity='legendary', price=1800, line=1434, trigger='on_accuse', kind='special', group='anticheat', special='accuse_bonus', param1=5 })
def({ id='cheat_trap', name='反作弊陷阱', desc='指认猜对后，下一局自动替你停牌（不保证赢）', spec='on_accuse | 指认猜对后，下一局自动替你停牌（不保证赢）', rarity='rare', price=1200, line=1435, trigger='on_accuse', kind='special', group='anticheat', special='auto_stand_next' })
def({ id='cheat_fear', name='庄家恐惧症', desc='阶段 3 的庄家出千概率减半（45% → 22.5%，幂等不累积）', spec='on_game_start / on_stage_start·Pre | 阶段 3 的庄家出千概率减半（45% → 22.5%，幂等不累积）', rarity='legendary', price=1400, line=1436, trigger='on_game_start', kind='special', group='anticheat', pre=true, special='halve_cheat' })
def({ id='peek_1', name='窥牌 · 壹', desc='本轮牌靴情报里亮明接下来 1 张（每小局重新点亮）', spec='点亮即生效 | 3× | 本轮牌靴情报里亮明接下来 1 张（每小局重新点亮）', rarity='uncommon', price=100, line=1442, trigger='active', kind='special', group='info', consumes=true, uses=3, special='peek', param1=1 })
def({ id='peek_2', name='窥牌 · 贰', desc='亮明接下来 2 张', spec='点亮即生效 | 3× | 亮明接下来 2 张', rarity='rare', price=200, line=1443, trigger='active', kind='special', group='info', consumes=true, uses=3, special='peek', param1=2 })
def({ id='peek_3', name='天眼通', desc='亮明接下来 3 张', spec='点亮即生效 | 3× | 亮明接下来 3 张', rarity='legendary', price=400, line=1444, trigger='active', kind='special', group='info', consumes=true, uses=3, special='peek', param1=3 })
def({ id='far_sight', name='千里眼', desc='亮明接下来 5 张', spec='点亮即生效 | 3× | 亮明接下来 5 张', rarity='legendary', price=400, line=1445, trigger='active', kind='special', group='info', consumes=true, uses=3, special='peek', param1=5 })
def({ id='peek_auto', name='算牌师', desc='每小局开始自动亮明接下来 1 张', spec='on_round_start·被动 | 3× | 每小局开始自动亮明接下来 1 张', rarity='rare', price=200, line=1446, trigger='on_round_start', kind='special', group='info', consumes=true, uses=3, special='peek_auto', param1=1 })
def({ id='burn_1', name='焚牌术', desc='把牌靴顶 1 张烧进弃牌堆（不亮明——减少不确定性也是情报）', spec='点亮即生效 | 3× | 把牌靴顶 1 张烧进弃牌堆（不亮明——减少不确定性也是情报）', rarity='uncommon', price=100, line=1447, trigger='active', kind='special', group='info', consumes=true, uses=3, special='burn', param1=1 })
def({ id='burn_3', name='炼狱焚堆', desc='把牌靴顶 3 张烧进弃牌堆', spec='点亮即生效 | **2×** | 把牌靴顶 3 张烧进弃牌堆', rarity='rare', price=200, line=1448, trigger='active', kind='special', group='info', consumes=true, uses=2, special='burn', param1=3 })
def({ id='reveal_12', name='揭示 · 一二', desc='第 1、2 张', spec='3× | 第 1、2 张', rarity='uncommon', price=500, line=1454, trigger='active', kind='special', group='info', consumes=true, uses=3, special='reveal', param1=1, param2=2 })
def({ id='reveal_34', name='揭示 · 三四', desc='第 3、4 张', spec='3× | 第 3、4 张', rarity='uncommon', price=500, line=1455, trigger='active', kind='special', group='info', consumes=true, uses=3, special='reveal', param1=3, param2=4 })
def({ id='reveal_56', name='揭示 · 五六', desc='第 5、6 张', spec='3× | 第 5、6 张', rarity='uncommon', price=700, line=1456, trigger='active', kind='special', group='info', consumes=true, uses=3, special='reveal', param1=5, param2=6 })
def({ id='reveal_78', name='揭示 · 七八', desc='第 7、8 张', spec='3× | 第 7、8 张', rarity='uncommon', price=700, line=1457, trigger='active', kind='special', group='info', consumes=true, uses=3, special='reveal', param1=7, param2=8 })
def({ id='reveal_123', name='揭示 · 一二三', desc='第 1~3 张', spec='3× | 第 1~3 张', rarity='rare', price=900, line=1458, trigger='active', kind='special', group='info', consumes=true, uses=3, special='reveal', param1=1, param2=3 })
def({ id='reveal_345', name='揭示 · 三四五', desc='第 3~5 张', spec='3× | 第 3~5 张', rarity='rare', price=900, line=1459, trigger='active', kind='special', group='info', consumes=true, uses=3, special='reveal', param1=3, param2=5 })
def({ id='reveal_456', name='揭示 · 四五六', desc='第 4~6 张', spec='3× | 第 4~6 张', rarity='rare', price=1000, line=1460, trigger='active', kind='special', group='info', consumes=true, uses=3, special='reveal', param1=4, param2=6 })
def({ id='reveal_15', name='揭示 · 前五张', desc='第 1~5 张', spec='3× | 第 1~5 张', rarity='legendary', price=2500, line=1461, trigger='active', kind='special', group='info', consumes=true, uses=3, special='reveal', param1=1, param2=5 })
def({ id='reveal_20_30', name='揭示 · 二十到三十', desc='第 20~30 张（滚轮后拉查看）', spec='3× | 第 20~30 张（滚轮后拉查看）', rarity='legendary', price=1500, line=1462, trigger='active', kind='special', group='info', consumes=true, uses=3, special='reveal', param1=20, param2=30 })
def({ id='reveal_10_20', name='揭示 · 十到二十', desc='第 10~20 张（滚轮后拉查看）', spec='3× | 第 10~20 张（滚轮后拉查看）', rarity='legendary', price=1800, line=1463, trigger='active', kind='special', group='info', consumes=true, uses=3, special='reveal', param1=10, param2=20 })
def({ id='rod_deep', name='深海钓具', desc='把一张已标记牌沉到牌库最底', spec='3× | 点选 | 把一张已标记牌沉到牌库最底', rarity='uncommon', price=600, line=1471, trigger='active', kind='special', group='rod', consumes=true, uses=3, special='rod', param1='deep' })
def({ id='rod_trawl', name='拖钓钓具', desc='把一张已标记牌向牌顶方向拖 3 张（已近顶则到顶）', spec='3× | 点选 | 把一张已标记牌向牌顶方向拖 3 张（已近顶则到顶）', rarity='uncommon', price=800, line=1472, trigger='active', kind='special', group='rod', consumes=true, uses=3, special='rod', param1='trawl' })
def({ id='rod_rogue', name='失控钓具', desc='所有标记牌（含双方手上与弃牌堆）随机抛回牌库各处', spec='3× | 即发 | 所有标记牌（含双方手上与弃牌堆）随机抛回牌库各处', rarity='rare', price=1000, line=1473, trigger='active', kind='special', group='rod', consumes=true, uses=3, special='rod', param1='rogue' })
def({ id='rod_swap', name='换位钓具', desc='依次点两张已标记牌，交换它们在牌库中的位置', spec='3× | 点选 | 依次点两张已标记牌，交换它们在牌库中的位置', rarity='rare', price=1200, line=1474, trigger='active', kind='special', group='rod', consumes=true, uses=3, special='rod', param1='swap' })
def({ id='rod_standard', name='标准钓具', desc='把一张已标记牌钓到牌库第一张', spec='3× | 点选 | 把一张已标记牌钓到牌库第一张', rarity='rare', price=1500, line=1475, trigger='active', kind='special', group='rod', consumes=true, uses=3, special='rod', param1='standard' })
def({ id='rod_lost', name='遗弃钓具', desc='弃牌堆所有标记牌钓回牌库顶（越晚弃的越靠顶）', spec='3× | 即发 | 弃牌堆所有标记牌钓回牌库顶（越晚弃的越靠顶）', rarity='rare', price=1800, line=1476, trigger='active', kind='special', group='rod', consumes=true, uses=3, special='rod', param1='lost' })
def({ id='rod_golden', name='黄金钓具', desc='牌库中所有标记牌按标记顺序钓到顶层依次排列', spec='3× | 即发 | 牌库中所有标记牌按标记顺序钓到顶层依次排列', rarity='legendary', price=3500, line=1477, trigger='active', kind='special', group='rod', consumes=true, uses=3, special='rod', param1='golden' })
def({ id='discard_rinse', name='淘洗', desc='把整个弃牌堆洗回牌库并随机切牌一次（空堆不消耗次数）', spec='3× | 把整个弃牌堆洗回牌库并随机切牌一次（空堆不消耗次数）', rarity='common', price=500, line=1483, trigger='active', kind='special', group='discard', consumes=true, uses=3, special='discard_rinse' })
def({ id='discard_backflow', name='回流', desc='把最近弃掉的 3 张按原顺序放回牌库顶', spec='3× | 把最近弃掉的 3 张按原顺序放回牌库顶', rarity='uncommon', price=900, line=1484, trigger='active', kind='special', group='discard', consumes=true, uses=3, special='discard_backflow', param1=3 })
def({ id='discard_salvager', name='打捞', desc='打开情报面板弃牌堆页签，点一张牌 → 下次要牌改为打出这张（照常结算与触发标记）', spec='3× | 打开情报面板弃牌堆页签，点一张牌 → 下次要牌改为打出这张（照常结算与触发标记）', rarity='rare', price=1800, line=1485, trigger='active', kind='special', group='discard', consumes=true, uses=3, special='discard_salvager' })
def({ id='mark_vanish', name='消失标记', desc='标记动作改为「消失」：这张牌被你要到时如同不存在般消失，转而摸下一张', spec='3× | 灰 | 标记动作改为「消失」：这张牌被你要到时如同不存在般消失，转而摸下一张', rarity='rare', price=1000, line=1491, trigger='active', kind='special', group='mark', consumes=true, uses=3, markDot=true, special='gain_mark', param1='mark_vanish' })
def({ id='mark_flame', name='火焰标记', desc='庄家无法要这张牌；庄家的下一张若是火焰牌只能停牌', spec='3× | 金 | 庄家无法要这张牌；庄家的下一张若是火焰牌只能停牌', rarity='rare', price=1500, line=1492, trigger='active', kind='special', group='mark', consumes=true, uses=3, markDot=true, special='gain_mark', param1='mark_flame' })
def({ id='mark_bounty', name='赏金标记', desc='庄家要这张牌时你立刻获得 $500 赏金', spec='3× | 绿 | 庄家要这张牌时你立刻获得 $500 赏金', rarity='rare', price=2000, line=1493, trigger='active', kind='special', group='mark', consumes=true, uses=3, markDot=true, special='gain_mark', param1='mark_bounty' })
def({ id='mark_void', name='虚空标记', desc='标记的瞬间立刻吸收它前面那张牌及其词条（继承倍率与特性；前面没牌则不消耗次数）', spec='3× | 紫 | 标记的瞬间立刻吸收它前面那张牌及其词条（继承倍率与特性；前面没牌则不消耗次数）', rarity='rare', price=2500, line=1494, trigger='active', kind='special', group='mark', consumes=true, uses=3, markDot=true, special='gain_mark', param1='mark_void' })
def({ id='mark_bomb', name='爆炸标记', desc='这张牌被任何人摸到时，炸掉其后 2 张牌（移入弃牌堆）', spec='3× | 红 | 这张牌被**任何人**摸到时，炸掉其后 2 张牌（移入弃牌堆）', rarity='rare', price=3000, line=1495, trigger='active', kind='special', group='mark', consumes=true, uses=3, markDot=true, special='gain_mark', param1='mark_bomb' })
def({ id='class_rider_shard', name='骑之残卷', desc='本小局按 R 可跳过一次（下注归还），点亮即扣次', spec='3× | 点亮型 | 本小局按 R 可跳过一次（下注归还），点亮即扣次', rarity='uncommon', price=600, line=1501, trigger='active', kind='special', group='shard', consumes=true, uses=3, special='shard_rider' })
def({ id='class_archer_shard', name='弓之残卷', desc='本小局发牌时预览你的第一张牌（需在下注前点亮）', spec='3× | 点亮型 | 本小局发牌时预览你的第一张牌（需在下注前点亮）', rarity='uncommon', price=800, line=1502, trigger='active', kind='special', group='shard', consumes=true, uses=3, special='shard_archer' })
def({ id='class_lancer_shard', name='枪之残卷', desc='本小局开局发三张（第三张保证不爆 21）', spec='3× | 点亮型 | 本小局开局发三张（第三张保证不爆 21）', rarity='rare', price=1200, line=1503, trigger='active', kind='special', group='shard', consumes=true, uses=3, special='shard_lancer' })
def({ id='class_assassin_shard', name='杀之残卷', desc='本小局庄家看不到你的牌（看牌类出千直接放弃）', spec='3× | 点亮型 | 本小局庄家看不到你的牌（看牌类出千直接放弃）', rarity='rare', price=1500, line=1504, trigger='active', kind='special', group='shard', consumes=true, uses=3, special='shard_assassin' })
def({ id='class_caster_shard', name='术之残卷', desc='连胜 3 局时，从 3 个候选里挑 1 个替换本遗物自身（也可以不换）', spec='3× | 被动型 | 连胜 3 局时，从 3 个候选里挑 1 个**替换本遗物自身**（也可以不换）', rarity='rare', price=1800, line=1505, trigger='passive', kind='special', group='shard', consumes=true, uses=3, special='shard_caster' })
def({ id='class_saber_shard', name='剑之残卷', desc='本小局结算时斩掉庄家点数最小的一张牌（与剑阶不叠加），真实生效才扣次', spec='3× | 触发型 | 本小局结算时斩掉庄家点数最小的一张牌（与剑阶不叠加），真实生效才扣次', rarity='legendary', price=2500, line=1506, trigger='on_score_calc', kind='special', group='shard', consumes=true, uses=3, special='shard_saber' })
def({ id='class_berserker_shard', name='狂之残卷', desc='本小局 25 点内不爆；未爆且比庄家大直接判胜（与狂阶不叠加，67 优先）', spec='3× | 触发型 | 本小局 25 点内不爆；未爆且比庄家大直接判胜（与狂阶不叠加，67 优先）', rarity='legendary', price=2500, line=1507, trigger='on_score_calc', kind='special', group='shard', consumes=true, uses=3, special='shard_berserker' })
def({ id='mobile_network', name='移动网络', desc='立刻在要牌阶段打开一次商店，规则与回合末商店完全一致；用后消失', spec='点亮即开店 | **1×** | 立刻在要牌阶段打开一次商店，规则与回合末商店完全一致；用后消失', rarity='rare', price=200, line=1513, trigger='active', kind='special', group='flow', consumes=true, uses=1, special='open_shop_early' })

-- ---------- 查询 ----------
function R.byId(id) return R.MAP[id] end
function R.all() return R.LIST end
function R.count() return #R.LIST end

function R.rarityPrice(rarity)
  if rarity == 'common' then return 50 end
  if rarity == 'uncommon' then return 100 end
  if rarity == 'rare' then return 200 end
  if rarity == 'legendary' then return 400 end
  if rarity == 'cursed' then return 150 end
  return 50
end

-- 库内基础价（定义表已带实测价；无价时按稀有度推导）
function R.price(d, stage, opts)
  if not d then return 0 end
  local p = d.price
  if not p or p == 0 then p = R.rarityPrice(d.rarity) end
  if opts and opts.raw then return p end
  local mult = ({ 1.0, 1.5, 2.0 })[stage or 1] or 1.0
  return math.floor(p * mult)
end

function R.isPoolExcluded(d)
  if not d then return false end
  return R.POOL_EXCLUDED[d.id] == true or d.noPool == true
end

-- 收集未实现的 special
function R.auditSpecial(handlerIds)
  local known = {}
  for _, id in ipairs(handlerIds or {}) do known[id] = true end
  R.unsupported = {}
  for i = 1, #R.LIST do
    local d = R.LIST[i]
    if d.special and not known[d.special] and not d.fx then
      R.unsupported[#R.unsupported + 1] = { id = d.id, special = d.special }
    end
  end
  return R.unsupported
end

return R
