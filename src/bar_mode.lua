-- src/bar_mode.lua 酒吧周目（100 局、6 杯 5 口、赠酒/保底/宿醉/结局）
-- 纯数据与判定；随机经 game_state 注入 rng。
local DT = require('src.deck_types')
local Cocktails = require('src.cocktails')

local Bar = {}

Bar.ROUNDS = 100
Bar.MAX_CUPS = 6
Bar.MOUTHS = 5          -- 每杯 5 口
Bar.BUFF_ROUNDS = 5     -- 喝 1 口解锁技能 5 局
Bar.GIFT_BASE = 0.01
Bar.GIFT_STEP = 0.005
Bar.PITY_ROUNDS = { 1, 20, 40, 60, 80, 100 }
Bar.HANGOVER_MIN = 4

-- 酒吧牌堆 = 10 种特殊牌组各取 1 样牌，各 10 张 = 100 张
Bar.DECK_KEYS = { 'decimal', 'negative', 'multiplier', 's67', 'rps', 'blackhole', 'cage', 'chip', 'dice6', 'dice20' }
Bar.COPIES = 10

function Bar.sampleCards()
  local out = {}
  for i = 1, #Bar.DECK_KEYS do
    local key = Bar.DECK_KEYS[i]
    local roster = DT.generate(key, 'small')
    local c = DT.clone(roster[1] or roster[2])
    c.bar_sample = key
    out[#out + 1] = c
  end
  return out
end

function Bar.buildDeck()
  local samples = Bar.sampleCards()
  local cards = {}
  for i = 1, #samples do
    for k = 1, Bar.COPIES do
      local c = DT.clone(samples[i])
      cards[#cards + 1] = c
    end
  end
  return cards
end

function Bar.newState()
  return {
    mode = 'bar', round = 0, wins = 0, losses = 0, finished = false,
    cups = {}, cupCount = 0, offered = {}, giftChance = Bar.GIFT_BASE,
    lastGift = nil, pendingGift = nil, pendingPity = false,
    ending = nil, hangover = nil, usedAbilityThisRound = false,
    abilitiesUsed = {}, log = {},
  }
end

function Bar.isPityRound(round)
  for i = 1, #Bar.PITY_ROUNDS do
    if Bar.PITY_ROUNDS[i] == round then return true end
  end
  return false
end

function Bar.giftChance(bar)
  return bar.giftChance or Bar.GIFT_BASE
end

function Bar.cupsFull(bar)
  return bar.cupCount >= Bar.MAX_CUPS
end

-- 从未在本周目获得/出现过的酒里选 3 款（不足则全给）
function Bar.giftCandidates(bar, count)
  count = count or 3
  local pool = {}
  for i = 1, #Cocktails.LIST do
    local d = Cocktails.LIST[i]
    if not bar.offered[d.id] and not Bar.findCup(bar, d.id) then
      pool[#pool + 1] = { id = d.id, name = d.name, en = d.en, gift = d.gift, group = d.group, def = d }
    end
  end
  local out = {}
  while #out < count and #pool > 0 do
    local pick = (bar._pickSeed or 1) % #pool + 1
    out[#out + 1] = pool[pick]
    table.remove(pool, pick)
  end
  return out
end

function Bar.findCup(bar, id)
  for i = 1, #bar.cups do
    if bar.cups[i].drink == id then return bar.cups[i], i end
  end
  return nil
end

function Bar.newCup(def)
  return {
    drink = def.id, name = def.name, en = def.en, glass = def.glass, color = def.color,
    strength = def.strength, ability = def.ability, gift = def.gift, group = def.group,
    mouth = 0, buffLeft = 0, def = def,
  }
end

function Bar.addCup(bar, def)
  if Bar.cupsFull(bar) then return nil, 'cups_full' end
  if Bar.findCup(bar, def.id) then return nil, 'already_have' end
  local cup = Bar.newCup(def)
  bar.cups[#bar.cups + 1] = cup
  bar.cupCount = #bar.cups
  bar.offered[def.id] = true
  return cup
end

-- 喝 1 口：mouth 0=满、5=空；首次喝解锁技能 5 局，同类刷新不叠层
function Bar.drink(bar, cupIndex)
  local cup = bar.cups[cupIndex]
  if not cup then return nil, 'no_cup' end
  if cup.mouth >= Bar.MOUTHS then return nil, 'empty' end
  cup.mouth = cup.mouth + 1
  cup.buffLeft = Bar.BUFF_ROUNDS
  bar.lastGift = nil
  return cup
end

function Bar.quaff(bar, cupIndex, n)
  local cup = bar.cups[cupIndex]
  if not cup then return nil, 'no_cup' end
  for i = 1, (n or 1) do
    if cup.mouth >= Bar.MOUTHS then break end
    cup.mouth = cup.mouth + 1
  end
  if cup.mouth > 0 then cup.buffLeft = Bar.BUFF_ROUNDS end
  return cup
end

function Bar.emptyCup(bar, cupIndex)
  local cup = bar.cups[cupIndex]
  if not cup then return nil end
  cup.mouth = Bar.MOUTHS
  return cup
end

function Bar.remaining(cup)
  return Bar.MOUTHS - (cup.mouth or 0)
end

function Bar.totalRemaining(bar)
  local n = 0
  for i = 1, #bar.cups do n = n + Bar.remaining(bar.cups[i]) end
  return n
end

function Bar.activeCups(bar)
  local out = {}
  for i = 1, #bar.cups do
    if Bar.remaining(bar.cups[i]) > 0 then out[#out + 1] = bar.cups[i] end
  end
  return out
end

-- 每局无条件 -1；返回本局到期的酒（用于下一局宿醉）
function Bar.tickBuffs(bar)
  local drank = {}
  for i = 1, #bar.cups do
    local cup = bar.cups[i]
    if cup.buffLeft and cup.buffLeft > 0 then
      cup.buffLeft = cup.buffLeft - 1
      if cup.buffLeft == 0 then drank[#drank + 1] = cup end
    end
  end
  return drank
end

function Bar.classify(bar)
  local total = Bar.totalRemaining(bar)
  if total <= 0 then return 'fail', total end
  if total == 1 then return 'date', total end
  local allHave = (#bar.cups >= Bar.MAX_CUPS)
  if allHave then
    for i = 1, #bar.cups do
      if Bar.remaining(bar.cups[i]) <= 0 then allHave = false; break end
    end
  end
  if allHave then return 'fish', total end
  if total > 0 then return 'buddies', total end
  return 'fail', total
end

-- 宿醉滤镜颜色 = 到期酒水颜色算术平均
function Bar.hangoverColor(cups)
  if not cups or #cups == 0 then return nil end
  local r, g, b, n = 0, 0, 0, 0
  for i = 1, #cups do
    local col = cups[i].color or cups[i].def and cups[i].def.color
    if col then
      local cr, cg, cb = 1, 1, 1
      if type(col) == 'table' then cr, cg, cb = col[1] or col.r or 1, col[2] or col.g or 1, col[3] or col.b or 1 end
      r, g, b, n = r + cr, g + cg, b + cb, n + 1
    end
  end
  if n == 0 then return nil end
  return { r / n, g / n, b / n }
end

function Bar.abilityMeta(special)
  local t = {
    redraw_hand = { label = '重调手牌', target = false },
    swap_hand_card = { label = '换掉一张', target = true },
    peek_sink_pick = { label = '窥底挑牌', target = false },
    burn_half = { label = '焚牌一半', target = false },
    duplicate_lowest = { label = '复制最小', target = false },
    dealer_stop = { label = '庄家停牌', target = false },
    discard_highest = { label = '弃最大牌', target = false },
    swap_with_dealer = { label = '与庄家换牌', target = true },
    discard_random = { label = '随机弃牌', target = false },
    pick_from_champion = { label = '冠军选牌', target = true },
    take_dealer_highest_sink = { label = '夺庄家最大', target = false },
    give_lowest_to_dealer = { label = '送最小给庄家', target = false },
  }
  return t[special] or { label = tostring(special or '技能'), target = false }
end

return Bar
