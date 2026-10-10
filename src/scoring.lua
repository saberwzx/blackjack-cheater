-- src/scoring.lua 算分五阶段链式（GDD §8）
-- additive = max(0, baseChips + Σ遗物筹码 + 卡牌筹码)
-- mult     = 1 + Σ遗物倍率 + Σ卡牌 mult_bonus
-- x_mult   = Πx_mult（67 组合在最后再 ×67）
-- winnings = floor(additive * mult * x_mult)   -- 铁律：mult 加法、x_mult 乘法
local S = {}

function S.baseFor(outcome, bet, naturalBJ)
  bet = bet or 0
  if outcome == 'player' then
    if naturalBJ then return bet * 1.5 end
    return bet * 2
  elseif outcome == 'push' then
    return bet
  end
  return 0
end

-- 新建结算上下文（供遗物 fx 使用）
function S.newCtx(player, dealer, state, opts)
  opts = opts or {}
  local ctx = {
    score = { chips = opts.cardChips or 0, mult = opts.cardMultBonus or 0, x_mult = opts.xMult or 1, breakdown = {} },
    player = player,
    dealer = dealer,
    state = state,
    outcome = opts.outcome or 'dealer',
    bet = opts.bet or 0,
    naturalBJ = opts.naturalBJ or false,
    is67 = opts.is67 or false,
    chipsBefore = opts.chipsBefore or 0,
    dealerUpAce = opts.dealerUpAce or false,
    forceResult = nil,
    halfLoss = false,
    forced = false,
  }
  ctx.api = {
    forcePlayerWin = function()
      if ctx.forceResult ~= 'loss' then ctx.outcome = 'player' end
    end,
    forceDealerWin = function() ctx.outcome = 'dealer' end,
  }
  return ctx
end

-- 应用遗物 fx（on_score_calc）与 special 处理器
function S.run(ctx, relicList, handlers, engine)
  relicList = relicList or {}
  handlers = handlers or {}
  for i = 1, #relicList do
    local inst = relicList[i]
    local d = inst.def or inst
    local fx = d.fx
    if fx then
      ctx.def = d
      ctx.score.breakdown[#ctx.score.breakdown + 1] = { label = d.name or d.id, kind = 'begin' }
      local ok, err = pcall(fx, ctx)
      if not ok then
        ctx.errors = ctx.errors or {}
        ctx.errors[#ctx.errors + 1] = { id = d.id, err = tostring(err) }
      end
    elseif d.special and handlers[d.special] then
      ctx.def = d
      local ok, err = pcall(handlers[d.special], ctx)
      if not ok then
        ctx.errors = ctx.errors or {}
        ctx.errors[#ctx.errors + 1] = { id = d.id, err = tostring(err) }
      end
    end
  end
  return ctx
end

-- 结算：先允许结果覆盖（forceResult / halfLoss），再算 winnings
function S.finalize(ctx)
  if ctx.forceResult == 'player' then ctx.outcome = 'player' end
  if ctx.forceResult == 'push' then ctx.outcome = 'push' end
  if ctx.forceResult == 'dealer' then ctx.outcome = 'dealer' end

  local base = S.baseFor(ctx.outcome, ctx.bet, ctx.naturalBJ)
  local add = math.max(0, base + (ctx.score.chips or 0))
  local mult = 1 + (ctx.score.mult or 0)
  local x = ctx.score.x_mult or 1
  if ctx.is67 then x = x * 67 end
  local winnings = math.floor(add * mult * x)
  if winnings < 0 then winnings = 0 end
  -- netChange = 实际筹码变化 = winnings - 下注 + 半输退款（含遗物额外筹码，push 时也体现）
  local refund = 0
  if ctx.outcome == 'dealer' and ctx.halfLoss then refund = math.floor(ctx.bet * 0.5) end
  local net = winnings - ctx.bet + refund
  return winnings, {
    outcome = ctx.outcome,
    baseChips = base,
    cardChips = ctx.score.chips or 0,
    mult = mult,
    x_mult = x,
    additive = add,
    netChange = net,
    halfLoss = ctx.halfLoss,
    breakdown = ctx.score.breakdown,
    errors = ctx.errors,
  }
end

return S
