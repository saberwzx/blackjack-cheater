-- tests/play_smoke.lua : 用确定性 rng 驱动三种模式，捕获运行期错误
local Game = require('src.game')

local seed = 987654321
local function rng(a, b)
  seed = (seed * 1103515245 + 12345) % 2147483648
  if a == nil then return seed / 2147483648 end
  return a + (seed % (b - a + 1))
end

local files = {}
local function memfs()
  return {
    read = function(path) return files[path] end,
    write = function(path, data) files[path] = data; return true end,
    getInfo = function(path) if files[path] then return { type = 'file' } end return nil end,
    mkdir = function() return true end,
    remove = function(path) files[path] = nil; return true end,
  }
end

local errors = {}
local function act(g, name, arg)
  local ok, err = g:action(name, arg)
  if not ok then errors[#errors + 1] = name .. ' -> ' .. tostring(err) .. ' @' .. tostring(g.state.state) end
  g:flush()
  return ok
end

local function playPlayerTurn(g, guard)
  local n = 0
  while g.state.state == 'player' and n < 40 do
    n = n + 1
    local p = g.state.player
    local t = 0
    for i = 1, #p.hand do
      local ok, v = pcall(function() return require('src.blackjack').handTotal(p.hand) end)
      t = ok and v or 0
    end
    if p.cageBlocked then act(g, 'stand')
    elseif t < 15 and n < 8 then act(g, 'hit') else act(g, 'stand') end
  end
  return n
end

local function drive(mode, maxSteps)
  seed = 987654321
  local g = Game.new({ rng = rng, filesystem = memfs() })
  local ok, err = g:start(mode, 20261001)
  if not ok then errors[#errors + 1] = 'start(' .. mode .. ') -> ' .. tostring(err) end
  g:flush()
  local steps = 0
  local seen = {}
  while steps < (maxSteps or 4000) do
    steps = steps + 1
    local s = g.state.state
    seen[s] = (seen[s] or 0) + 1
    if s == 'relic_select' then act(g, 'pick_relic', 1)
    elseif s == 'classSelect' then
      local c = g.state.classOffer and g.state.classOffer.candidates
      act(g, 'choose_class', c and c[1] and c[1].id or 'saber')
    elseif s == 'classOffer' then act(g, 'take_class_offer', 1)
    elseif s == 'bet' then act(g, 'bet_set', 200); act(g, 'bet_confirm')
    elseif s == 'player' then playPlayerTurn(g)
    elseif s == 'bar_gift' then act(g, 'bar_gift_pick', 1)
    elseif s == 'bar_brief' then act(g, 'bar_begin')
    elseif s == 'result' then act(g, 'continue')
    elseif s == 'shop' then act(g, 'leave_shop')
    elseif s == 'stageClear' then act(g, 'continue')
    elseif s == 'victory' or s == 'forceExit' or s == 'bar_ending' then break
    elseif s == 'title' then break
    else
      errors[#errors + 1] = 'unhandled state ' .. tostring(s) .. ' @step' .. steps
      break
    end
  end
  local counts = {}
  for k, v in pairs(seen) do counts[#counts + 1] = k .. '=' .. v end
  table.sort(counts)
  print(string.format('[%s] steps=%d round=%s chips=%s state=%s | %s',
    mode, steps, tostring(g.state.round), tostring(g.state.chips), tostring(g.state.state), table.concat(counts, ' ')))
  return g
end

print('=== normal ==='); drive('normal', 4000)
print('=== hard ===');   drive('hard', 6000)
print('=== bar ===');    drive('bar', 6000)

print('errors = ' .. #errors)
for i = 1, math.min(#errors, 30) do print('  ' .. errors[i]) end
os.exit(#errors == 0 and 0 or 1)
