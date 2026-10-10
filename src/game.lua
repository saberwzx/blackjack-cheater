-- src/game.lua 对外门面：UI 只依赖本文件
-- Game.new(opts) -> g；g.state 为当前对局视图；公开方法 start/action/update/flush/can/getView/drainFx/drainLog。
local GS = require('src.game_state')

local Game = {}

local function proxy(self, key)
  local g = rawget(self, '_g')
  if Game[key] ~= nil then return Game[key] end
  if not g then return nil end
  if key == 'state' then return g.state end
  local st = g.state
  if st and st[key] ~= nil then return st[key] end
  return g[key]
end

function Game.new(opts)
  local self = setmetatable({}, { __index = proxy, __newindex = function(t, k, v) rawset(t, k, v) end })
  rawset(self, '_g', GS.new(opts))
  return self
end

function Game:start(mode, seed) return self._g:start(mode, seed) end
function Game:action(name, arg) return self._g:action(name, arg) end
function Game:update(dt) return self._g:update(dt) end
function Game:flush(n) return self._g:flush(n) end
function Game:can(action) return self._g:can(action) end
function Game:getView() return self._g:getView() end
function Game:drainFx()
  local g = self._g
  local fx = g.fx
  g.fx = {}
  g.state.fx = g.fx
  return fx
end
function Game:drainLog()
  local g = self._g
  local log = g.log
  g.log = {}
  g.state.log = g.log
  return log
end
function Game:saveProgress() return self._g:saveProgress() end
function Game:resetProgress() return self._g:resetProgress() end

return Game
