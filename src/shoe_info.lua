-- src/shoe_info.lua 情报模块（纯函数；不消耗随机数，GDD §11）
-- 精确口径：
--   * 标准桶 = A / 2..9 / 10（J/Q/K 并 10）。
--   * 已知数值的自定义牌（小数 / 负数等）不参与标准桶枚举，但计入 coverageGap（GDD §11.1）；
--   * 不定值牌（骰子 / RPS / 非数值 rank）无法估值，查询返回 nil + reason + coverageGap，
--     绝不返回误导性的“精确”数字。
--   * dealerBustOdds 对剩余牌靴做「无放回」递归枚举；memo 键包含每种桶的剩余计数、
--     深度、软 A 状态与已追加张数。深度 ≤10、节点预算 150k、追加上限 5 张。
local SI = {}
local BJ = require('src.blackjack')

SI.UNKNOWN = 'unknown'
SI.MAX_DEPTH = 10
SI.NODE_BUDGET = 150000
SI.DEALER_HIT_CAP = 5

local ORDER = { 'A', '2', '3', '4', '5', '6', '7', '8', '9', '10' }

-- 牌分类：standard / valued / undetermined / nonstandard / none
function SI.classify(card)
  if not card then return { kind = 'none' } end
  if card.is_rps then return { kind = 'undetermined', why = 'rps' } end
  if card.kind == 'dice6' or card.kind == 'dice20' or card.is_dice6 or card.is_dice20 then
    return { kind = 'undetermined', why = 'dice' }
  end
  if card.value ~= nil then
    if type(card.value) ~= 'number' then return { kind = 'undetermined', why = 'value' } end
    return { kind = 'valued', value = card.value }
  end
  local rs = tostring(card.rank)
  if rs == 'A' then return { kind = 'standard', bucket = 'A' } end
  if rs == '10' or rs == 'J' or rs == 'Q' or rs == 'K' then return { kind = 'standard', bucket = '10' } end
  local n = tonumber(rs)
  if n and n >= 2 and n <= 9 and n == math.floor(n) then return { kind = 'standard', bucket = tostring(n) } end
  return { kind = 'nonstandard', rank = rs }
end

function SI.bucketOf(card)
  local cl = SI.classify(card)
  if cl.kind == 'standard' then return cl.bucket end
  return SI.UNKNOWN
end

function SI.bucketValue(card)
  local cl = SI.classify(card)
  if cl.kind ~= 'standard' then return nil end
  if cl.bucket == 'A' then return 11 end
  return tonumber(cl.bucket)
end

local function cardTag(card, cl)
  if cl.kind == 'valued' then return 'valued:' .. tostring(cl.value) end
  if cl.kind == 'undetermined' then return 'undetermined:' .. tostring(cl.why or '') end
  if cl.kind == 'nonstandard' then return 'nonstandard:' .. tostring(cl.rank or '?') end
  return 'unknown'
end

local function gapText(gap)
  if not gap or (gap.total or 0) == 0 then return '' end
  local parts = {}
  for tag, n in pairs(gap.entries or {}) do parts[#parts + 1] = tag .. '×' .. n end
  table.sort(parts)
  return '非标准牌 ' .. tostring(gap.total) .. ' 张未参与标准桶枚举（' .. table.concat(parts, '、') .. '）'
end

local function addToGap(gap, card, cl)
  gap.total = (gap.total or 0) + 1
  gap.entries = gap.entries or {}
  local tag = cardTag(card, cl)
  gap.entries[tag] = (gap.entries[tag] or 0) + 1
end

-- 覆盖统计：标准桶 / 各类非标准牌计数与缺口文案
function SI.coverageOf(cards)
  local out = { standard = 0, valued = 0, undetermined = 0, nonstandard = 0, unknown = 0, total = 0, entries = {} }
  local gap = { total = 0, entries = {} }
  for i = 1, #(cards or {}) do
    local cl = SI.classify(cards[i])
    out.total = out.total + 1
    if cl.kind == 'standard' then out.standard = out.standard + 1
    elseif cl.kind == 'valued' then out.valued = out.valued + 1; addToGap(gap, cards[i], cl)
    elseif cl.kind == 'undetermined' then out.undetermined = out.undetermined + 1; addToGap(gap, cards[i], cl)
    elseif cl.kind == 'nonstandard' then out.nonstandard = out.nonstandard + 1; addToGap(gap, cards[i], cl) end
  end
  out.unknown = out.valued + out.undetermined + out.nonstandard
  out.entries = gap.entries
  out.coverageGap = gapText(gap)
  return out
end

function SI.coverageGap(cards)
  return SI.coverageOf(cards).coverageGap
end

local function stdCounts()
  local defs, counts = {}, {}
  for i = 1, #ORDER do
    local b = ORDER[i]
    defs[#defs + 1] = { bucket = b, value = (b == 'A') and 11 or tonumber(b), ace = (b == 'A') }
    counts[#counts + 1] = (b == 'A') and 4 or ((b == '10') and 16 or 4)
  end
  return defs, counts
end

-- 把一组牌拆成「标准桶计数」+「已知值缺口」+「不定值缺口」。
-- 标准桶参与无放回递归；已知值牌按 GDD §11.1 不参与枚举但计入 coverageGap；
-- 不定值牌（骰子/RPS/非数值）无法估值 -> 调用方返回 nil + 原因。
local function listCounts(pile)
  local defs, counts, index = {}, {}, {}
  local valued = { total = 0, entries = {} }
  local unknown = { total = 0, entries = {} }
  for i = 1, #(pile or {}) do
    local cl = SI.classify(pile[i])
    if cl.kind == 'standard' then
      local b = cl.bucket
      if not index[b] then
        index[b] = #defs + 1
        defs[#defs + 1] = { bucket = b, value = (b == 'A') and 11 or tonumber(b), ace = (b == 'A') }
        counts[#counts + 1] = 0
      end
      counts[index[b]] = counts[index[b]] + 1
    elseif cl.kind == 'valued' then
      addToGap(valued, pile[i], cl)
    else
      addToGap(unknown, pile[i], cl)
    end
  end
  return defs, counts, valued, unknown
end

local function deckCounts(deck)
  return listCounts(deck and deck.drawPile)
end

local function addBucket(total, soft, def)
  -- def 既可能是 classify 结果 { bucket=... }，也可能是内部 { value=..., ace=... }
  local isAce = def.ace or def.bucket == 'A'
  local v = def.value
  if v == nil and def.bucket ~= nil then v = isAce and 11 or tonumber(def.bucket) end
  if isAce then
    if total + 11 <= 21 then return total + 11, true end
    return total + 1, soft
  end
  local nt = total + (v or 0)
  if nt > 21 and soft then nt = nt - 10; soft = false end
  return nt, soft
end

-- 追加一张牌的爆牌判定（bustOdds 用）
local function bustAfterAppend(total, opts, cand)
  if opts.hand then
    local temp = {}
    for i = 1, #opts.hand do temp[i] = opts.hand[i] end
    local c
    if cand.card then c = cand.card
    elseif cand.ace then c = { rank = 'A' }
    elseif cand.value ~= nil then c = { rank = tostring(cand.value), value = cand.value }
    else c = { rank = cand.bucket } end
    temp[#temp + 1] = c
    return BJ.handTotal(temp) > 21
  end
  local nt
  if cand.ace then
    nt = (total + 11 <= 21) and (total + 11) or (total + 1)
  else
    nt = total + (cand.value or tonumber(cand.bucket) or 0)
  end
  if nt > 21 and opts.softAce then nt = nt - 10 end
  return nt > 21
end

-- 下一张爆率：对已知值牌多重集精确枚举。
-- opts.hand（推荐，core 提供）为真实手牌数组；追加后调用 BJ.handTotal，
-- 因此 A 超 21 自动降 1、已有软 A 也会正确降级。
-- 不传 opts.hand 时按硬点数近似（A 追加超 21 仍降 1），detail.needHand = true。
-- 含未知值牌（骰子 / RPS / 非数值 value）时返回 nil + reason + coverageGap。
function SI.bustOdds(total, cards, opts)
  opts = opts or {}
  total = tonumber(total) or 0
  local candidates, unknown = {}, 0
  local gap = { total = 0, entries = {} }
  if opts.knownValues then
    for i = 1, #opts.knownValues do
      local v = opts.knownValues[i]
      if type(v) == 'number' then
        candidates[#candidates + 1] = { value = v, ace = (v == 11) }
      else
        unknown = unknown + 1
      end
    end
  else
    for i = 1, #(cards or {}) do
      local c = cards[i]
      local cl = SI.classify(c)
      if cl.kind == 'standard' then
        candidates[#candidates + 1] = { bucket = cl.bucket, card = c, ace = (cl.bucket == 'A') }
      elseif cl.kind == 'valued' then
        candidates[#candidates + 1] = { value = cl.value, card = c, ace = false }
      elseif cl.kind == 'nonstandard' then
        local n = tonumber(cl.rank)
        if n then candidates[#candidates + 1] = { value = n, card = c, ace = false }
        else unknown = unknown + 1; addToGap(gap, c, cl) end
      else
        unknown = unknown + 1; addToGap(gap, c, cl)
      end
    end
  end
  if unknown > 0 and not opts.ignoreUnknown then
    return nil, { reason = 'unknown_cards', message = '候选牌含未知值牌，无法精确枚举', unknown = unknown,
      coverageGap = gapText(gap), bust = 0, total = #candidates, count = #candidates }
  end
  if #candidates == 0 then
    return nil, { reason = 'no_known_cards', message = '没有可枚举的已知值牌', unknown = unknown,
      coverageGap = gapText(gap), bust = 0, total = 0, count = 0 }
  end
  local bust = 0
  for i = 1, #candidates do
    if bustAfterAppend(total, opts, candidates[i]) then bust = bust + 1 end
  end
  return bust / #candidates, {
    bust = bust, total = #candidates, count = #candidates, unknown = unknown,
    coverageGap = gapText(gap), needHand = (opts.hand == nil),
  }
end

-- 庄家爆率：对剩余标准桶做无放回精确递归（GDD §11.1 / §9.3）。
-- 语义：
--   * 只枚举标准点数桶（A/2..9/10）；无放回；按真实要牌规则 BJ.dealerShouldHitTotal。
--   * 已知数值的自定义牌不参与枚举，但计入 coverageGap（非致命，仍给数字）。
--   * 不定值牌（骰子 / RPS / 非数值 rank）无法估值 -> nil + reason + coverageGap。
--   * 深度 > maxDepth 或节点 > budget：放弃 -> nil + reason（绝不回退成近似数字）。
-- upcards：庄家已知牌数组（core 传 { dealer.hand[2] } 明牌即可）。
-- opts:
--   cards       table  剩余牌靴牌数组（core 的 sample；优先于 deck）
--   deck        table  含 drawPile 的牌靴（opts.useShoe ~= false 时使用）
--   useShoe     bool   关闭且无 cards 时用标准 52 张近似（detail.basis == 'standard52'）
--   holeUnknown bool   暗牌未知，按剩余可用标准桶枚举（默认 #upcards == 1 且未给 holeCard）
--   holeCard    card   已亮明的暗牌（并入已知手牌；不要在 cards 中重复）
--   playerTotal number 难度 3 读牌
--   bustAt      number 爆牌线（默认 21）
--   standOn / standOnSoft17 / forceStand  透传给 BJ.dealerShouldHitTotal
--   maxDepth    默认 10；budget 默认 150000；hitCap 默认 5（庄家追加要牌上限）
-- 返回 number, detail 或 nil, { reason, message, coverageGap, nodes }
function SI.dealerBustOdds(upcards, difficulty, opts)
  opts = opts or {}
  if upcards and upcards.rank ~= nil then upcards = { upcards } end
  upcards = upcards or {}
  difficulty = difficulty or 1
  local bustAt = opts.bustAt or 21
  local maxDepth = opts.maxDepth or SI.MAX_DEPTH
  local budget = opts.budget or SI.NODE_BUDGET
  local hitCap = opts.hitCap or SI.DEALER_HIT_CAP
  local playerTotal = opts.playerTotal

  local Base, Soft = 0, false
  local upUnknown = { total = 0, entries = {} }
  local validUp = 0
  for i = 1, #upcards do
    local card = upcards[i]
    if card ~= nil then
      validUp = validUp + 1
      local cl = SI.classify(card)
      if cl.kind == 'standard' then
        Base, Soft = addBucket(Base, Soft, cl)
      elseif cl.kind == 'valued' then
        -- 已知值明牌：精确并入 Base，不产生分支
        Base, Soft = addBucket(Base, Soft, { value = cl.value, ace = false })
      else
        addToGap(upUnknown, card, cl)
      end
    end
  end
  local holeCard = opts.holeCard
  if opts.holeUnknown == true then holeCard = nil end
  if holeCard then
    local cl = SI.classify(holeCard)
    if cl.kind == 'standard' then Base, Soft = addBucket(Base, Soft, cl)
    elseif cl.kind == 'valued' then Base, Soft = addBucket(Base, Soft, { value = cl.value, ace = false })
    else addToGap(upUnknown, holeCard, cl) end
  end

  local holeUnknown = opts.holeUnknown
  if holeUnknown == nil then
    holeUnknown = (validUp == 1) and (opts.holeKnown ~= true) and (holeCard == nil)
  end

  if validUp == 0 and not holeCard then
    return nil, { reason = 'no_upcard', message = '缺少庄家明牌，无法计算', nodes = 0, coverageGap = '' }
  end
  if upUnknown.total > 0 then
    return nil, { reason = 'unknown_upcard', message = '庄家已知牌含不定值牌，无法估值',
      coverageGap = gapText(upUnknown), nodes = 0, gap = upUnknown }
  end

  local defs, counts, valuedGap, unknownGap, basis
  if opts.cards then
    defs, counts, valuedGap, unknownGap = listCounts(opts.cards)
    basis = 'cards'
  elseif opts.deck and opts.deck.drawPile and opts.useShoe ~= false then
    defs, counts, valuedGap, unknownGap = listCounts(opts.deck.drawPile)
    basis = 'shoe'
  else
    defs, counts = stdCounts()
    valuedGap = { total = 0, entries = {} }
    unknownGap = { total = 0, entries = {} }
    basis = 'standard52'
    local idx = {}
    for i = 1, #defs do idx[defs[i].bucket] = i end
    local function sub(card)
      local cl = SI.classify(card)
      if cl.kind == 'standard' then
        local j = idx[cl.bucket]
        if j and counts[j] > 0 then counts[j] = counts[j] - 1 end
      end
    end
    for i = 1, #upcards do sub(upcards[i]) end
    if holeCard then sub(holeCard) end
  end

  if unknownGap.total > 0 then
    return nil, { reason = 'unknown_cards', message = '待抽牌靴含不定值牌，无法估值',
      coverageGap = gapText(unknownGap), nodes = 0, gap = unknownGap }
  end
  if #defs == 0 then
    return nil, { reason = 'no_standard_cards', message = '待抽牌靴没有可枚举的标准桶',
      coverageGap = gapText(valuedGap), nodes = 0, gap = valuedGap }
  end
  local gapStr = gapText(valuedGap)

  if Base > bustAt then
    return 1, { nodes = 0, basis = basis, holeUnknown = holeUnknown, coverageGap = gapStr, hitCap = hitCap, maxDepth = maxDepth }
  end

  local nodes = 0
  local memo = {}
  local hitOpts = { bustAt = bustAt, standOn = opts.standOn, standOnSoft17 = opts.standOnSoft17, forceStand = opts.forceStand }

  local function rec(t, s, hits, depth)
    nodes = nodes + 1
    if nodes > budget then error('SI_BUDGET', 0) end
    if depth > maxDepth then error('SI_DEPTH', 0) end
    if t > bustAt then return 1 end
    if hits >= hitCap then return 0 end
    local remaining = 0
    for i = 1, #counts do remaining = remaining + counts[i] end
    if remaining == 0 then return 0 end
    if not BJ.dealerShouldHitTotal(t, s, difficulty, playerTotal, hitOpts) then return 0 end
    local key = table.concat(counts, ',') .. '|' .. t .. '|' .. (s and 1 or 0) .. '|' .. hits .. '|' .. depth
    local m = memo[key]
    if m ~= nil then return m end
    local sum = 0
    for i = 1, #defs do
      local c = counts[i]
      if c > 0 then
        counts[i] = c - 1
        local nt, ns = addBucket(t, s, defs[i])
        sum = sum + c * rec(nt, ns, hits + 1, depth + 1)
        counts[i] = c
      end
    end
    local r = sum / remaining
    memo[key] = r
    return r
  end

  local function compute()
    if holeUnknown then
      local remaining = 0
      for i = 1, #counts do remaining = remaining + counts[i] end
      if remaining == 0 then return 0, 'empty_shoe' end
      local sum = 0
      for i = 1, #defs do
        local c = counts[i]
        if c > 0 then
          counts[i] = c - 1
          local nt, ns = addBucket(Base, Soft, defs[i])
          sum = sum + c * rec(nt, ns, 0, 0)
          counts[i] = c
        end
      end
      return sum / remaining, nil
    end
    return rec(Base, Soft, 0, 0), nil
  end

  local ok, res, note = pcall(compute)
  if not ok then
    local msg = tostring(res)
    local reason = 'error'
    if string.find(msg, 'SI_BUDGET', 1, true) then reason = 'budget_exceeded'
    elseif string.find(msg, 'SI_DEPTH', 1, true) then reason = 'depth_exceeded' end
    return nil, { reason = reason, message = msg, nodes = nodes, budget = budget, maxDepth = maxDepth, coverageGap = gapStr }
  end
  return res, {
    nodes = nodes, basis = basis, holeUnknown = holeUnknown, coverageGap = gapStr,
    valuedExcluded = valuedGap.total, hitCap = hitCap, maxDepth = maxDepth, note = note,
  }
end

-- 顺序带：从当前偏移取 n 张真实卡引用
function SI.orderBand(deck, opts)
  opts = opts or {}
  local pile = (deck and deck.drawPile) or {}
  local offset = math.max(0, math.floor(tonumber(opts.offset) or 0))
  local n = opts.n or opts.k or #pile
  local revealDepth = opts.revealDepth or 0
  local revealSet = opts.revealSet or {}
  local revealAll = opts.revealAll or false
  local out = {}
  for i = 1, n do
    local k = offset + i
    if k > #pile then break end
    local card = pile[k]
    local uid = card and card.uid
    local revealed = revealAll or (i <= revealDepth) or (uid ~= nil and revealSet[uid] == true) or (card and card.revealed == true)
    out[#out + 1] = { offset = k, card = card, uid = uid, revealed = revealed, marked = (card and card.marked ~= nil) or false }
  end
  return out
end

-- 成分统计：J/Q/K 并入 10；A 单独；其余非标准桶单列 unknown
function SI.rankComposition(cards)
  local buckets = {}
  for i = 1, #ORDER do buckets[ORDER[i]] = 0 end
  local unknown, total = 0, 0
  local gap = { total = 0, entries = {} }
  for i = 1, #(cards or {}) do
    local card = cards[i]
    if card then
      total = total + 1
      local cl = SI.classify(card)
      if cl.kind == 'standard' then buckets[cl.bucket] = (buckets[cl.bucket] or 0) + 1
      else unknown = unknown + 1; addToGap(gap, card, cl) end
    end
  end
  local out = { buckets = {}, unknown = unknown, total = total, order = ORDER,
    nonstandard = { total = gap.total, entries = gap.entries }, coverageGap = gapText(gap) }
  for i = 1, #ORDER do out.buckets[ORDER[i]] = buckets[ORDER[i]] or 0 end
  return out
end

-- 切牌：一等公民，返回顺序参考（就地切 drawPile）。也接受 state（含 .deck）。
function SI.cutShoe(deckOrState, k, known)
  local deck = deckOrState
  if deck and deck.deck and deck.deck.drawPile then deck = deck.deck end
  if not deck or type(deck.cut) ~= 'function' then return nil end
  deck:cut(k)
  return deck
end

function SI.standardCut(rng)
  local r
  if type(rng) == 'function' then r = rng()
  elseif love and love.math and love.math.random then r = love.math.random()
  else r = math.random() end
  if type(r) ~= 'number' then r = 0 end
  return 8 + math.floor(r * 18) -- 8..25
end

return SI
