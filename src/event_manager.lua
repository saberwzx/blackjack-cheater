-- ============================================================
-- EventManager — 简单的事件注册/派发系统
-- 内容触发器（trigger/hook）总线模式，按 21 点场景裁剪
-- ============================================================

local EventManager = {}
EventManager.__index = EventManager

function EventManager.new()
    local self = setmetatable({}, EventManager)
    self._listeners = {}  -- event_name -> { {id = func_name, fn = function, priority = n}, ... }
    self._enabled = true
    return self
end

-- 注册事件监听
-- event: 事件名 (如 "on_hit", "on_score_calc")
-- id:    唯一标识，用于移除
-- fn:    回调函数，接收 (context) 参数，返回值会根据事件类型决定如何处理
-- priority: 可选，数字越小越先执行（默认 100）
function EventManager:on(event, id, fn, priority)
    priority = priority or 100
    if not self._listeners[event] then
        self._listeners[event] = {}
    end
    -- 防止重复注册同一个 id
    self:off(event, id)
    table.insert(self._listeners[event], {
        id = id,
        fn = fn,
        priority = priority
    })
    -- 按优先级排序
    table.sort(self._listeners[event], function(a, b)
        return a.priority < b.priority
    end)
end

-- 移除事件监听
function EventManager:off(event, id)
    if not self._listeners[event] then return end
    for i, listener in ipairs(self._listeners[event]) do
        if listener.id == id then
            table.remove(self._listeners[event], i)
            return
        end
    end
end

-- 触发事件
-- event: 事件名
-- context: 传递给所有监听器的上下文表
-- 返回: 合并后的结果表（用于 scoring 类事件），或者 nil
function EventManager:trigger(event, context)
    if not self._enabled or not self._listeners[event] then return nil end

    local result = {}
    local listeners = self._listeners[event]

    for _, listener in ipairs(listeners) do
        local ok, ret = pcall(listener.fn, context)
        if not ok then
            print(string.format("[EventManager] ERROR in listener '%s' for event '%s': %s", 
                listener.id, event, tostring(ret)))
        elseif ret and type(ret) == "table" then
            -- 合并返回值（多遗物效果叠加）
            for k, v in pairs(ret) do
                if type(v) == "number" then
                    -- 累加型（chips, mult）
                    result[k] = (result[k] or 0) + v
                elseif type(v) == "boolean" then
                    -- 布尔型（允许/阻止）
                    result[k] = v
                end
            end
        end
    end

    return result
end

-- 触发事件，支持每个监听器返回的修改值链式叠加
-- 用于 scoring 类事件：每个效果可以在前面的基础上继续修改
function EventManager:trigger_chain(event, context, initial_values)
    if not self._enabled or not self._listeners[event] then return initial_values end

    local values = {}
    if initial_values then
        for k, v in pairs(initial_values) do values[k] = v end
    end

    local listeners = self._listeners[event]
    for _, listener in ipairs(listeners) do
        context.values = values  -- 把当前值传进去，让监听器可以读取和修改
        
        local ok, ret = pcall(listener.fn, context)
        if not ok then
            print(string.format("[EventManager] ERROR in listener '%s' for event '%s': %s",
                listener.id, event, tostring(ret)))
        elseif ret and type(ret) == "table" then
            -- 合并：数字累加，特殊字段 x_mult/h_mult 用乘法
            for k, v in pairs(ret) do
                if type(v) == "number" then
                    if k == "x_mult" or k == "xmult" then
                        -- x_mult 是乘法叠加
                        values[k] = (values[k] or 1) * v
                    else
                        -- chips, mult 等是加法
                        values[k] = (values[k] or 0) + v
                    end
                elseif type(v) == "boolean" then
                    values[k] = v
                end
            end
        end
    end

    return values
end

-- 禁用/启用所有事件
function EventManager:setEnabled(enabled)
    self._enabled = enabled
end

-- 清除所有监听
function EventManager:clear()
    self._listeners = {}
end

-- ============================================================
-- 预定义的事件名常量（所有模块统一使用这些名字）
-- ============================================================
EventManager.EVENTS = {
    -- 游戏流程事件
    GAME_START    = "on_game_start",
    ROUND_START   = "on_round_start",
    BET           = "on_bet",
    DEAL          = "on_deal",
    DEAL_AFTER    = "on_deal_after",   -- 玩家开局两张牌发完之后（改牌型类遗物用）
    HIT           = "on_hit",
    STAND         = "on_stand",
    DEALER_TURN   = "on_dealer_turn",
    DEALER_HIT    = "on_dealer_hit",
    DEALER_BUST   = "on_dealer_bust",
    SCORE_CALC    = "on_score_calc",
    ROUND_END     = "on_round_end",
    STAGE_CLEAR   = "on_stage_clear",
    STAGE_START   = "on_stage_start",
    ACCUSE        = "on_accuse",

    -- 特殊行动事件
    DOUBLE_DOWN   = "on_double_down",
    SPLIT         = "on_split",
    INSURANCE     = "on_insurance",
}

return EventManager
