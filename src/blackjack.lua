-- src/blackjack.lua 点数、牌型、胜负与庄家 AI（纯函数）
-- 规则口径（GDD §7）：
--   1) card.value ~= nil 时最高优先，直接采用该值（小数 / 负数 / RPS / 已定值骰子）。
--   2) 只有 rank=='A' 且 value==nil 的牌才是可升降的 A。
--   3) A 默认 11，超过 21 时逐个降为 1。
--   4) 软手 = 存在「按 11 计」的 A，即 total > base（base 将所有 A 记 1）。
local BJ = {}

function BJ.isAce(card)
  return card ~= nil and card.rank == 'A' and card.value == nil
end

function BJ.isTenValue(card)
  if not card then return false end
  if card.value ~= nil then return card.value == 10 end
  local r = card.rank
  return r == '10' or r == 'J' or r == 'Q' or r == 'K'
end

function BJ.isFace(card)
  if not card then return false end
  local r = card.rank
  return r == 'J' or r == 'Q' or r == 'K'
end

-- 保守值：A 记 1；特殊牌直接用 value；未定值骰子返回 0
function BJ.cardValue(card)
  if not card then return 0 end
  if card.value ~= nil then return card.value end
  local r = card.rank
  if r == 'A' then return 1 end
  if r == '10' or r == 'J' or r == 'Q' or r == 'K' then return 10 end
  local n = tonumber(r)
  if n then return n end
  return 0
end

-- base：所有 A 记 1 的点数和
function BJ.handBase(hand)
  local b = 0
  for i = 1, #(hand or {}) do
    local c = hand[i]
    if BJ.isAce(c) then b = b + 1
    else b = b + (BJ.cardValue(c) or 0) end
  end
  return b
end

function BJ.countAces(hand)
  local n = 0
  for i = 1, #(hand or {}) do
    if BJ.isAce(hand[i]) then n = n + 1 end
  end
  return n
end

function BJ.hasAce(hand)
  return BJ.countAces(hand) > 0
end

-- 原始值：A 全部按 11 计，不降级
function BJ.handRawTotal(hand)
  return BJ.handBase(hand) + BJ.countAces(hand) * 10
end

-- 有效值：A 默认 11，超出 21 逐个降级
function BJ.handTotal(hand)
  local base = BJ.handBase(hand)
  local aces = BJ.countAces(hand)
  local total = base + aces * 10
  while total > 21 and aces > 0 do
    total = total - 10
    aces = aces - 1
  end
  return total
end

-- 软手判定：A 仍按 11 计（total > base）
function BJ.isSoft(hand)
  return BJ.handTotal(hand) > BJ.handBase(hand)
end

function BJ.isBustValue(total)
  return total > 21
end

-- 自然 Blackjack：恰 2 张，A + 10 点牌，合计 21，非 67 / 非 RPS
function BJ.isBlackjack(hand)
  if #(hand or {}) ~= 2 then return false end
  local hasA, hasTen = false, false
  for i = 1, #hand do
    local c = hand[i]
    if c.is_67 or c.is_rps then return false end
    if BJ.isAce(c) then hasA = true
    elseif BJ.isTenValue(c) then hasTen = true end
  end
  return hasA and hasTen and BJ.handTotal(hand) == 21
end

-- 67 组合技：同时含 6 与 7（黑洞继承时写入 s67_rank）
function BJ.has67(hand)
  local six, seven = false, false
  for i = 1, #(hand or {}) do
    local c = hand[i]
    if c.is_67 then
      local r = c.s67_rank or c.rank
      if r == '6' then six = true elseif r == '7' then seven = true end
    end
  end
  return six and seven
end

function BJ.rpsSymbol(hand)
  for i = 1, #(hand or {}) do
    if hand[i].is_rps then return hand[i].rps_symbol or hand[i].rank end
  end
  return nil
end

function BJ.isPair(hand)
  if #(hand or {}) ~= 2 then return false end
  local a, b = hand[1], hand[2]
  if a.is_67 or b.is_67 or a.is_rps or b.is_rps then return false end
  local function t(c)
    if c.value ~= nil then return c.value end
    if c.rank == '10' or c.rank == 'J' or c.rank == 'Q' or c.rank == 'K' then return 10 end
    return tonumber(c.rank) or c.rank
  end
  return t(a) == t(b) and #hand == 2
end

function BJ.compare(pTotal, dTotal, pBust, dBust)
  if pBust and dBust then return 'dealer' end
  if pBust then return 'dealer' end
  if dBust then return 'player' end
  if pTotal > dTotal then return 'player' end
  if pTotal < dTotal then return 'dealer' end
  return 'push'
end

-- 庄家是否要牌（按 total/soft 判定，供 shoe_info 递归复用）
-- opts: forceStand, standOn, bustAt（默认 21）, standOnSoft17
function BJ.dealerShouldHitTotal(total, soft, difficulty, playerTotal, opts)
  opts = opts or {}
  if opts.forceStand then return false end
  local bustAt = opts.bustAt or 21
  if total > bustAt then return false end
  if opts.standOn and total >= opts.standOn then return false end
  if opts.standOnSoft17 and total >= 17 then return false end

  difficulty = difficulty or 1
  if difficulty <= 1 then
    if total < 15 then return true end
    if total == 16 or total == 17 then return soft end
    return false
  elseif difficulty == 2 then
    if total < 18 then return true end
    if total == 18 then return soft end
    return false
  else
    if playerTotal == nil then
      if total < 18 then return true end
      if total == 18 then return soft end
      return false
    end
    if playerTotal >= 18 then return total < 17 end
    if total > playerTotal then return false end
    if total < playerTotal then return true end
    return total < 19
  end
end

-- hand 为手牌数组（可判断软手）；difficulty 1/2/3；playerTotal 可为 nil。
function BJ.dealerShouldHit(hand, difficulty, playerTotal, opts)
  return BJ.dealerShouldHitTotal(BJ.handTotal(hand), BJ.isSoft(hand), difficulty, playerTotal, opts)
end

function BJ.cardLabel(card)
  if not card then return '?' end
  if card.label and card.label ~= '' then return card.label end
  return tostring(card.rank or '?') .. tostring(card.suit or '')
end

function BJ.suitName(suit)
  if suit == 'S' then return '黑桃' end
  if suit == 'H' then return '红心' end
  if suit == 'D' then return '方块' end
  if suit == 'C' then return '梅花' end
  return tostring(suit or '')
end

return BJ
