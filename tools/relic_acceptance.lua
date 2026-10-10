-- tools/relic_acceptance.lua — 遗物行为独立验收（不依赖 UI）
-- 运行：python tools/run_lua.py tools/relic_acceptance.lua
-- 目标：用行为断言证明遗物真的生效/正确扣次，而不是“存在定义”。
local GS = require('src.game_state')
require('src.relic_actions').install(GS)
local Relics = require('src.relics')
local Marks = require('src.marks')
local Scoring = require('src.scoring')
local BJ = require('src.blackjack')
local DT = require('src.deck_types')

local pass, failures = 0, {}
local function check(name, fn)
  local ok, err = pcall(fn)
  if ok then pass = pass + 1; print('PASS ' .. name)
  else failures[#failures + 1] = name .. ': ' .. tostring(err); print('FAIL ' .. failures[#failures]) end
end
local function eq(a, b, msg)
  if a ~= b then error((msg and (msg .. ' ') or '') .. 'expected=' .. tostring(b) .. ' got=' .. tostring(a), 2) end
end
local function truthy(v, msg) if not v then error(msg or 'expected truthy', 2) end end

local function mkRng(seed)
  local s = seed or 987654321
  return function(a, b)
    s = (s * 1103515245 + 12345) % 2147483648
    if a == nil then return s / 2147483648 end
    return a + (s % (b - a + 1))
  end
end
local function memfs()
  return {
    read = function() return nil end, write = function() return true end,
    getInfo = function() return nil end, mkdir = function() return true end, remove = function() return true end,
  }
end
local function newGame()
  local g = GS.new({ rng = mkRng(20261001), filesystem = memfs() })
  g.state.relicSlotMax = 99
  g.state.chips = 1000000
  g.state.state = 'bet'
  return g
end
local function give(g, ids)
  for _, id in ipairs(ids) do
    local d = Relics.byId(id)
    assert(d, 'missing relic ' .. tostring(id))
    assert(g:addRelic(d), 'addRelic failed ' .. id)
  end
end
local function c(rank, value)
  return DT.mk({ rank = rank, suit = 'S', kind = 'basic', is_basic = true, value = value })
end
local function setHand(g, cards) g.state.player.hand = cards; g:refreshPlayer() end
local function setDraw(g, cards)
  local d = g.state.deck
  d.drawPile = cards; d.discardPile = {}; d.removed = {}
  for i = 1, #d.drawPile do d:assignUid(d.drawPile[i]) end
  return d
end
local function asPlayer(g) g.state.state = 'player'; return g end

-- 1. 精准 12：A 算 1（两张 A 不是 12，不触发）
check('ace_and_ten_exact uses A=1 (A+A is 2, not 12)', function()
  local g = newGame(); give(g, { 'ace_and_ten_exact' })
  setHand(g, { c('A'), c('A') })
  local ctx = g:scoreCtxFor({ outcome = 'player' }); ctx.gs = g
  Scoring.run(ctx, g:activeRelics(), g.scoreHandlers, g)
  eq(ctx.score.mult, 0)
end)
check('ace_and_ten_exact triggers on A+A+10 (A=1 sum 12)', function()
  local g = newGame(); give(g, { 'ace_and_ten_exact' })
  setHand(g, { c('A'), c('A'), c('10') })
  local ctx = g:scoreCtxFor({ outcome = 'player' }); ctx.gs = g
  Scoring.run(ctx, g:activeRelics(), g.scoreHandlers, g)
  eq(ctx.score.mult, 20)
end)

-- 2. 给牌组：下次要牌强制点数，且真实生效才扣次（2 次）
check('give_card_4 forces next hit to 4 and consumes one use', function()
  local g = newGame(); give(g, { 'give_card_4' }); asPlayer(g)
  setHand(g, { c('5'), c('5') })
  setDraw(g, { c('9') })
  g:playerHit()
  eq(g.state.player.hand[3].rank, '4')
  eq(g:relicById('give_card_4').usesLeft, 1)
end)

-- 3. 第三张必 10
check('always_10_on_third makes the third card a 10', function()
  local g = newGame(); give(g, { 'always_10_on_third' }); asPlayer(g)
  setHand(g, { c('2'), c('3') })
  setDraw(g, { c('9') })
  g:playerHit()
  eq(g.state.player.hand[3].rank, '10')
end)

-- 4. 凑 20 为止
check('hit_to_20 reaches exactly 20', function()
  local g = newGame(); give(g, { 'hit_to_20' }); asPlayer(g)
  setHand(g, { c('5'), c('5'), c('5') })
  setDraw(g, { c('2') })
  g:playerHit()
  eq(g.state.player.total, 20)
end)

-- 5. 对子凑 21
check('pair_to_21 reaches 21 when the pair leaves a <=10 gap', function()
  local g = newGame(); give(g, { 'pair_to_21' }); asPlayer(g)
  setHand(g, { c('8'), c('8') })   -- 16 -> 需 5
  setDraw(g, { c('2') })
  g:playerHit()
  eq(g.state.player.total, 21)
end)
check('pair_to_21 caps at +10 when the gap exceeds 10', function()
  local g = newGame(); give(g, { 'pair_to_21' }); asPlayer(g)
  setHand(g, { c('5'), c('5') })   -- 10 -> 需 11，GDD 只加 10
  setDraw(g, { c('2') })
  g:playerHit()
  eq(g.state.player.total, 20)
end)

-- 6. 八球幸运
check('eight_ball gives a ten when holding an 8', function()
  local g = newGame(); give(g, { 'eight_ball' }); asPlayer(g)
  setHand(g, { c('8'), c('3') })
  setDraw(g, { c('2') })
  g:playerHit()
  truthy(BJ.isTenValue(g.state.player.hand[#g.state.player.hand]))
end)

-- 7. 第一次 Hit 安全：避免爆牌才扣次
check('first_hit_safe prevents the first bust and consumes', function()
  local g = newGame(); give(g, { 'first_hit_safe' }); asPlayer(g)
  setHand(g, { c('10'), c('10') })
  setDraw(g, { c('5') })
  g:playerHit()
  truthy(not g.state.player.busted)
  eq(g:relicById('first_hit_safe').usesLeft, 2)
end)

-- 8. 最后一张救命：换成安全牌（已 21 不干预由 playerHit 自动停牌保证）
check('last_card_save replaces a busting draw with a safe card', function()
  local g = newGame(); give(g, { 'last_card_save' }); asPlayer(g)
  setHand(g, { c('10'), c('10') })
  setDraw(g, { c('5') })
  g:playerHit()
  truthy(not g.state.player.busted)
  eq(g.state.player.total, 21)
  eq(g:relicById('last_card_save').usesLeft, 2)
end)

-- 9. 卡包：空则寄存，有则取出（跨小局保留在 st.cardPack）
check('card_pack stores on empty then retrieves on next hit', function()
  local g = newGame(); give(g, { 'card_pack' }); asPlayer(g)
  setHand(g, { c('5'), c('7') })
  setDraw(g, { c('9'), c('2') })
  g:playerHit()             -- 寄存本次摸到的牌
  truthy(g.state.cardPack ~= nil)
  local stored = g.state.cardPack.rank
  g.state.state = 'player'; g.state.player.stood = false
  g:playerHit()             -- 取出寄存牌
  eq(g.state.player.hand[#g.state.player.hand].rank, stored)
end)

-- 10. 黑洞（本小局点亮，下一次要牌吸收第一张，用后熄灭）
check('black_hole absorbs the first card on the next hit', function()
  local g = newGame(); give(g, { 'black_hole' }); asPlayer(g)
  truthy(g:toggle_relic('black_hole'))
  local inst = g:relicById('black_hole'); truthy(inst._active)
  setHand(g, { c('5'), c('6') })
  setDraw(g, { c('9') })
  g:playerHit()
  eq(#g.state.player.hand, 2)
  eq(g.state.player.hand[1].rank, '6')
  truthy(not inst._active, 'black_hole should deactivate after use')
end)

-- 11. 21 至尊：触发即扣次并置阶段胜利
check('twentyone_supreme consumes and marks stage win', function()
  local g = newGame(); give(g, { 'twentyone_supreme' })
  g.state.stage = 1; g.state.stageTarget = 2000; g.state.roundsInStage = 3
  setHand(g, { c('K'), c('5'), c('6') })  -- 21
  local ctx = g:scoreCtxFor({ outcome = 'player' }); ctx.gs = g; ctx.stage = 1
  Scoring.run(ctx, g:activeRelics(), g.scoreHandlers, g)
  truthy(g.state.supremeClear)
  truthy(g:relicById('twentyone_supreme')._expired)
end)

-- 12. 爆牌护盾：生效时扣次并改判平局
check('bust_shield consumes and turns bust into push', function()
  local g = newGame(); give(g, { 'bust_shield' })
  local ctx = g:scoreCtxFor({ outcome = 'dealer' }); ctx.gs = g
  ctx.player.busted = true
  Scoring.run(ctx, g:activeRelics(), g.scoreHandlers, g)
  local _, info = Scoring.finalize(ctx)
  eq(info.outcome, 'push')
  eq(g:relicById('bust_shield').usesLeft, 2)
end)

-- 13. 窥牌：亮明并扣次
check('peek_1 reveals the top card and consumes', function()
  local g = newGame(); give(g, { 'peek_1' }); asPlayer(g)
  setDraw(g, { c('2'), c('3'), c('4') })
  truthy(g:use_relic('peek_1'))
  truthy(g.state.shoe.revealSlots[1])
  eq(g:relicById('peek_1').usesLeft, 2)
end)

-- 14. 焚牌：进弃牌堆而非 removed
check('burn moves cards to the discard pile', function()
  local g = newGame(); give(g, { 'burn_1' }); asPlayer(g)
  local d = setDraw(g, { c('2'), c('3') })
  local before = #d.discardPile
  truthy(g:use_relic('burn_1'))
  eq(#d.discardPile, before + 1)
  eq(#d.removed, 0)
end)

-- 15. 淘洗：空堆不扣次
check('discard_rinse does not consume on an empty discard', function()
  local g = newGame(); give(g, { 'discard_rinse' }); asPlayer(g)
  local d = setDraw(g, { c('2') }); d.discardPile = {}
  local ok = g:use_relic('discard_rinse')
  eq(ok, false)
  eq(g:relicById('discard_rinse').usesLeft, 3)
end)

-- 16. 钓具：deep 把已标记牌沉底并扣次；未标记拒绝
check('rod_deep sinks a marked card to the bottom', function()
  local g = newGame(); give(g, { 'rod_deep' }); asPlayer(g)
  local d = setDraw(g, { c('2'), c('3'), c('4') })
  local card = d.drawPile[1]
  Marks.newInk(card, { by = 'player', price = 50, stage = 1 })
  truthy(g:use_relic('rod_deep'))
  truthy(g:rod_pick({ uid = card.uid }))
  truthy(g:rod_confirm())
  eq(d.drawPile[#d.drawPile].uid, card.uid)
  eq(g:relicById('rod_deep').usesLeft, 2)
end)

-- 17. 下注遗物：最小下注者强制 $50；下注集团翻倍
check('bet_minimizer forces a $50 bet', function()
  local g = newGame(); give(g, { 'bet_minimizer' }); g.state.state = 'bet'
  truthy(g:bet_set(500))
  eq(g.state.bet, 50)
end)
check('bet_syndicate doubles the confirmed bet', function()
  local g = newGame(); give(g, { 'bet_syndicate' }); g.state.state = 'bet'
  g.state.bet = 100
  truthy(g:bet_confirm())
  eq(g.state.bet, 200)
  eq(g.state.chips, 1000000 - 200)
end)

-- 18. 被动遗物不可点亮
check('passive relics are not toggleable', function()
  local g = newGame(); give(g, { 'mult_ring' }); asPlayer(g)
  eq(g:toggle_relic('mult_ring'), false)
end)

-- 19. 特种标记：放置时扣遗物次数，虚空标记前面无牌不扣
check('special mark consumes its relic only when placed', function()
  local g = newGame(); give(g, { 'mark_flame' }); asPlayer(g)
  truthy(g:use_relic('mark_flame'))
  local d = setDraw(g, { c('2'), c('3') })
  g.state.flags.specialMarkUsedThisRound = false
  truthy(g:mark_card({ zone = 'shoe', index = 2 }))
  eq(d.drawPile[2].marked.markId, 'mark_flame')
  eq(g:relicById('mark_flame').usesLeft, 2)
end)

print(string.format('relic acceptance: PASS=%d FAIL=%d', pass, #failures))
if #failures > 0 then error(table.concat(failures, '\n')) end
