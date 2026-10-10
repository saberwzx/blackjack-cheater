-- src/event_manager.lua 事件总线（on/off/emit）
local EM = {}
EM.__index = EM

function EM.new()
  return setmetatable({ handlers = {} }, EM)
end

function EM:on(name, fn)
  if type(fn) ~= 'function' then return fn end
  self.handlers[name] = self.handlers[name] or {}
  self.handlers[name][#self.handlers[name] + 1] = fn
  return fn
end

function EM:off(name, fn)
  local list = self.handlers[name]
  if not list then return end
  if not fn then self.handlers[name] = nil; return end
  for i = #list, 1, -1 do
    if list[i] == fn then table.remove(list, i) end
  end
end

function EM:emit(name, ...)
  local list = self.handlers[name]
  if not list then return {} end
  local results = {}
  local snapshot = {}
  for i = 1, #list do snapshot[i] = list[i] end
  for i = 1, #snapshot do
    local ok, r = pcall(snapshot[i], ...)
    if ok then results[#results + 1] = r
    else results[#results + 1] = { error = tostring(r) } end
  end
  return results
end

function EM:count(name)
  return #(self.handlers[name] or {})
end

function EM:clear()
  self.handlers = {}
end

return EM
