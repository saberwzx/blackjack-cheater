-- ============================================================
-- Tween — 轻量补间动画系统
-- 用于卡牌发牌 / 翻牌 / 入场动画
-- ============================================================

local Tween = {}
Tween.__index = Tween

Tween.list = {}  -- 全局 tween 列表

-- 缓动函数
Tween.EASE = {
    linear    = function(t) return t end,
    outQuad   = function(t) return 1 - (1-t)*(1-t) end,
    outCubic  = function(t) return 1 - (1-t)^3 end,
    outBack   = function(t) local s=1.70158; t=t-1; return t*t*((s+1)*t+s)+1 end,
    outElastic= function(t)
        if t==0 or t==1 then return t end
        return 2^(-10*t) * math.sin((t-0.075)*(2*math.pi)/0.3) + 1
    end,
    inOutQuad = function(t)
        if t < 0.5 then return 2*t*t else return 1 - 2*(-2*t+2)^2/2 end
    end,
}

-- 创建一个 tween，自动加入全局列表
-- target: 被驱动的 table（如 card.visual）
-- props: 最终值 { x = 100, y = 200, scaleX = 1 }
-- duration: 秒
-- ease: 缓动函数名（字符串或函数）
-- onComplete: 结束后回调
function Tween.new(target, props, duration, ease, onComplete)
    ease = ease or "outQuad"
    if type(ease) == "string" then ease = Tween.EASE[ease] or Tween.EASE.outQuad end

    local tw = setmetatable({
        target = target,
        props  = props,
        duration = duration or 0.3,
        ease = ease,
        onComplete = onComplete,
        from   = {},  -- 起始值（自动记录）
        t      = 0,
        done   = false,
    }, Tween)

    -- 记录每个 prop 的起始值
    for k, _ in pairs(props) do
        tw.from[k] = target[k] or 0
    end

    table.insert(Tween.list, tw)
    return tw
end

-- 每帧更新所有 tween
function Tween.updateAll(dt)
    for i = #Tween.list, 1, -1 do
        local tw = Tween.list[i]
        tw.t = tw.t + dt
        local p = math.min(1, tw.t / tw.duration)
        local e = tw.ease(p)
        for k, toVal in pairs(tw.props) do
            local fromVal = tw.from[k] or 0
            tw.target[k] = fromVal + (toVal - fromVal) * e
        end
        if p >= 1 then
            tw.done = true
            if tw.onComplete then tw.onComplete() end
            table.remove(Tween.list, i)
        end
    end
end

function Tween.clear()
    Tween.list = {}
end

-- 给一张卡创建 visual 子表（分离视觉和逻辑）
function Tween.initCardVisual(card, startX, startY)
    card.visual = {
        x = startX or 0,
        y = startY or 0,
        targetX = startX or 0,
        targetY = startY or 0,
        scaleX = 1,  -- 用于翻牌动画
        flipAnimating = false,
        flipTimer = 0,
    }
end

return Tween
