-- tools/meta_acceptance.lua
-- 元系统（教程 + 冠军牌组编辑器）独立验收。用注入的内存文件系统运行，绝不触碰正式存档。
-- 运行：python tools/run_lua.py tools/meta_acceptance.lua
local Game = require('src.game')
local GS = require('src.game_state')
local M = require('src.meta_actions')
local DT = require('src.deck_types')
local Champion = require('src.champion')
local Persist = require('src.persist')

local pass, failures = 0, {}
local function check(name, fn)
  local ok, err = pcall(fn)
  if ok then
    pass = pass + 1
    print('PASS ' .. name)
  else
    failures[#failures + 1] = name .. ': ' .. tostring(err)
    print('FAIL ' .. failures[#failures])
  end
end
local function eq(a, b, msg)
  assert(a == b, tostring(msg or '') .. ' expected=' .. tostring(b) .. ' got=' .. tostring(a))
end
local function is_true(v, msg) assert(v == true, tostring(msg or '') .. ' expected true got ' .. tostring(v)) end
local function is_false(v, msg) assert(v == false, tostring(msg or '') .. ' expected false got ' .. tostring(v)) end

local function memfs()
  local files = {}
  local fs = {
    read = function(p) return files[p] end,
    write = function(p, v) files[p] = v; return true end,
    mkdir = function() return true end,
    getInfo = function(p) return files[p] and { type = 'file' } or nil end,
  }
  return files, fs
end

local function makeRng(seed)
  local s = seed or 20240617
  return function(a, b)
    s = (s * 1103515245 + 12345) % 2147483648
    local v = s / 2147483648
    if a ~= nil then
      b = b or a
      return a + math.floor(v * (b - a + 1))
    end
    return v
  end
end

local function newGame(seed)
  local files, fs = memfs()
  M.install(GS)
  local g = Game.new({ filesystem = fs, rng = makeRng(seed or 1234567) })
  return g, files, fs
end

local function S(g) return g._g.state end
local function step(g) return S(g).tutorial and S(g).tutorial.step or -1 end
local function advance(g) return g:action('tutorial_advance') end

-- ---- 真实推进到各步骤的驱动（每一步都是真实动作，不走捷径）----
local function driveToBetGate(g)
  g:action('start_tutorial')
  advance(g) -- 1 -> 2
  advance(g) -- 2 -> 3
  return g
end
local function driveToPick(g)
  driveToBetGate(g)
  is_true(g:action('bet_set', 50), 'bet_set')
  is_true(g:action('bet_confirm'), 'bet_confirm')
  if S(g).state == 'player' then g:action('stand') end
  g:flush(500)
  advance(g)               -- 5 -> 6
  is_true(g:action('open_deck'), 'open_deck')
  advance(g)               -- 7 -> 8
  is_true(g:action('close_deck'), 'close_deck')
  advance(g)               -- 9 -> 10
  return g
end
local function driveToActivate(g)
  driveToPick(g)
  eq(step(g), 10, 'at pick_relic')
  if S(g).relicSelect == nil then
    is_true(S(g).tutorialPendingRelic, 'pending relic select')
    is_true(g:action('continue'), 'continue into next round')
    g:flush(50)
  end
  is_true(g:action('pick_relic', 1), 'pick_relic')
  return g
end
local function driveToEnd(g)
  driveToActivate(g)
  is_true(g:action('use_relic', 1), 'use_relic')
  advance(g) -- 12 -> 13
  advance(g) -- 13 -> 14
  advance(g) -- 14 -> done
  return g
end

-- ===================== 牌池规格（附录 C4 明确分项）=====================

check('C4 pool is itemized 345 with explicit per-group counts', function()
  local pool = DT.championPool()
  eq(#pool, 345, 'pool size')
  eq(DT.championPoolSize(), 345, 'poolSize')
  local want = { basic = 52, decimal = 44, negative = 40, multiplier = 40, s67 = 8,
                 rps = 3, blackhole = 52, cage = 52, chip = 52, dice6 = 1, dice20 = 1 }
  local got, sum = {}, 0
  for _, e in ipairs(DT.championGroupCounts()) do got[e.key] = e.count; sum = sum + e.count end
  for k, v in pairs(want) do eq(got[k], v, 'group ' .. k) end
  eq(sum, 345, 'group sum')
  for i = 1, #pool do
    assert(pool[i].group and pool[i].groupName and type(pool[i].card) == 'table', 'entry ' .. i)
    assert(pool[i].card.uid == nil, 'uid leaked at ' .. i)
  end
end)

check('Champion contract: price 21, exactly 36, expand 36/72/108', function()
  eq(Champion.SIZE, 36)
  eq(Champion.price(), 21)
  local sel = {}
  for i = 1, 36 do sel[i] = DT.championPool()[i].card end
  eq(#Champion.expand(sel, 'small'), 36)
  eq(#Champion.expand(sel, 'medium'), 72)
  eq(#Champion.expand(sel, 'large'), 108)
end)

-- ===================== 教程 =====================

check('Tutorial start lands on the live state table and is UI-projected', function()
  local g = newGame()
  is_true(g:action('start_tutorial'))
  local st = S(g)
  eq(st.state, 'bet'); eq(st.mode, 'normal'); eq(st.chips, 2500)
  eq(st.playerClass, nil); eq(st.dealerClass, nil); eq(#st.relics, 0)
  eq(st.tutorial.active, true); eq(st.tutorial.done, false)
  eq(st.tutorial.step, 1); eq(st.tutorial.total, 14)
  eq(st.tutorial.phase.index, 1); eq(st.tutorial.phase.requireAction, nil)
  assert(type(st.tutorial.phase.title) == 'string' and #st.tutorial.phase.title > 0)
  assert(type(st.tutorial.phase.text) == 'string' and #st.tutorial.phase.text > 0)
  eq(st.tutorial.phase.actionHint, '')
end)

check('Tutorial manual steps advance; bet gate refuses shortcuts and passes on real bet', function()
  local g = driveToBetGate(newGame())
  eq(step(g), 3)
  eq(S(g).tutorial.phase.requireAction, 'bet')
  local ok, err = advance(g)
  is_false(ok); eq(err, 'tutorial_action_required'); eq(step(g), 3)
  g:action('close_top'); eq(step(g), 3) -- 跨层快捷键不得放行
  is_true(g:action('bet_set', 50))
  is_true(g:action('bet_confirm'))
  eq(step(g), 4)
  eq(S(g).tutorial.phase.requireAction, 'round_end')
end)

check('Tutorial round_end gate passes only after a real settled round', function()
  local g = driveToBetGate(newGame())
  is_true(g:action('bet_set', 50))
  is_true(g:action('bet_confirm'))
  eq(step(g), 4)
  local ok, err = advance(g)
  is_false(ok); eq(err, 'tutorial_action_required'); eq(step(g), 4)
  if S(g).state == 'player' then g:action('stand') end
  g:flush(500)
  eq(step(g), 5)
  eq(S(g).tutorial.phase.requireAction, nil)
  assert(S(g).state == 'result' or S(g).state == 'stageClear' or S(g).state == 'forceExit')
end)

check('Tutorial deck gates require the real open/close actions', function()
  local g = driveToBetGate(newGame())
  is_true(g:action('bet_set', 50))
  is_true(g:action('bet_confirm'))
  if S(g).state == 'player' then g:action('stand') end
  g:flush(500)
  advance(g); eq(step(g), 6)
  eq(S(g).tutorial.phase.requireAction, 'open_deck')
  local ok, err = advance(g)
  is_false(ok); eq(err, 'tutorial_action_required'); eq(step(g), 6)
  g:action('close_top'); eq(step(g), 6) -- 未打开前关闭不得放行
  is_true(g:action('open_deck')); eq(S(g).deckOpen, true); eq(step(g), 7)
  advance(g); eq(step(g), 8)
  eq(S(g).tutorial.phase.requireAction, 'close_deck')
  is_true(g:action('close_deck')); eq(S(g).deckOpen, false); eq(step(g), 9)
end)

check('Tutorial pick_relic gate runs on a deterministic real consumable trio', function()
  local g = driveToPick(newGame())
  eq(step(g), 10)
  eq(S(g).tutorial.phase.requireAction, 'pick_relic')
  if S(g).relicSelect == nil then
    is_true(S(g).tutorialPendingRelic)
    is_true(g:action('continue'))
    g:flush(50)
  end
  eq(S(g).state, 'relic_select')
  eq(#S(g).relicSelect.candidates, 3)
  for i = 1, 3 do
    assert(S(g).relicSelect.candidates[i].consumable == true, 'candidate ' .. i .. ' must be consumable')
    assert(type(S(g).relicSelect.candidates[i].def) == 'table', 'candidate ' .. i .. ' def')
  end
  local ok, err = advance(g)
  is_false(ok); eq(err, 'tutorial_action_required'); eq(step(g), 10)
  is_true(g:action('pick_relic', 1))
  eq(step(g), 11)
  eq(#S(g).relics, 1)
end)

check('Tutorial activate_relic gate passes on a real relic activation', function()
  local g = driveToActivate(newGame())
  eq(step(g), 11)
  eq(S(g).tutorial.phase.requireAction, 'activate_relic')
  local ok, err = advance(g)
  is_false(ok); eq(err, 'tutorial_action_required'); eq(step(g), 11)
  is_true(g:action('use_relic', 1))
  eq(step(g), 12)
end)

check('Tutorial completes after all 14 steps and never fakes hard clear', function()
  local g = driveToEnd(newGame())
  eq(S(g).tutorialRun, nil)
  eq(S(g).tutorial.active, false)
  eq(S(g).tutorial.done, true)
  eq(S(g).tutorial.total, 14)
  eq(S(g).tutorial.step, 14)
  eq(S(g).progress.hardCleared, false)
  eq(g._g.progress.meta.hardCleared, false)
  local ok, err = g:action('open_deck_editor')
  is_false(ok); eq(err, 'locked')
end)

check('Aliases route through the same gates (placeBet -> bet)', function()
  local g = driveToBetGate(newGame())
  is_true(g:action('bet_set', 50))
  is_true(g:action('placeBet'))
  eq(step(g), 4)
end)

check('install(GS) is idempotent', function()
  is_true(M.install(GS))
  is_true(M.install(GS))
  local g = newGame()
  is_true(g:action('start_tutorial'))
  eq(step(g), 1)
  is_true(advance(g))
  eq(step(g), 2)
end)

-- ===================== 冠军编辑器 =====================

check('Editor is locked until hardCleared (memory progress or state flag)', function()
  local g = newGame()
  local ok, err = g:action('open_deck_editor')
  is_false(ok); eq(err, 'locked')
  S(g).progress.hardCleared = true
  is_true(g:action('open_deck_editor'))
  eq(S(g).state, 'deckEditor')
end)

check('Editor unlock also honors persisted progress.meta.hardCleared', function()
  local g = newGame()
  g._g.progress.meta.hardCleared = true
  is_true(g:action('open_deck_editor'))
  eq(S(g).state, 'deckEditor')
end)

check('Editor opens over the full 345 pool and exposes a stable UI shape', function()
  local g = newGame()
  S(g).progress.hardCleared = true
  is_true(g:action('open_deck_editor'))
  local ed = S(g).deckEditor
  eq(#ed.pool, 345)
  eq(ed.max, 36); eq(ed.selectedCount, 0); eq(ed.filter, 'all'); eq(#ed.groups, 11)
  eq(ed.unlocked, true); eq(ed.savedCount, 0); eq(ed.loadedFromSave, false)
  assert(type(ed.selected) == 'table' and type(ed.chosen) == 'table')
  assert(type(ed.selectedFaces) == 'table' and #ed.selectedFaces == 0)
end)

check('Editor toggle caps at 36 and clear empties the selection', function()
  local g = newGame()
  S(g).progress.hardCleared = true
  g:action('open_deck_editor')
  local ed = S(g).deckEditor
  for i = 1, 36 do is_true(g:action('champion_toggle', i)) end
  eq(ed.selectedCount, 36)
  local ok, err = g:action('champion_toggle', 37)
  is_false(ok); eq(err, 'champion_full'); eq(ed.selectedCount, 36)
  is_true(g:action('champion_clear'))
  eq(ed.selectedCount, 0)
end)

check('Editor save requires exactly 36 and writes only whitelisted card fields', function()
  local g = newGame()
  S(g).progress.hardCleared = true
  g:action('open_deck_editor')
  local ed = S(g).deckEditor
  is_true(g:action('champion_toggle', 1))
  eq(ed.selectedCount, 1)
  local ok0, err0 = g:action('champion_save')
  is_false(ok0); eq(err0, 'champion_size')
  g:action('champion_clear')
  for i = 1, 36 do is_true(g:action('champion_toggle', i)) end
  is_true(g:action('champion_save'))
  eq(#S(g).championCards, 36)
  local col = g._g.persist:readCollection()
  eq(#col.cards, 36)
  local allow = {}
  for _, f in ipairs(Persist.CARD_FIELDS) do allow[f] = true end
  for i = 1, #col.cards do
    assert(col.cards[i].uid == nil, 'uid leaked into saved card')
    for k in pairs(col.cards[i]) do assert(allow[k], 'non-whitelisted field ' .. tostring(k)) end
  end
end)

check('Editor save rejects a card carrying a non-whitelisted field', function()
  local g = newGame()
  S(g).progress.hardCleared = true
  g:action('open_deck_editor')
  local ed = S(g).deckEditor
  for i = 1, 36 do g:action('champion_toggle', i) end
  ed.chosen[1].uid = 'tampered'
  local ok, err = g:action('champion_save')
  is_false(ok); eq(err, 'invalid_arg')
end)

check('Editor can be reloaded, preselected from the saved 36, and re-saved', function()
  local g = newGame()
  S(g).progress.hardCleared = true
  g:action('open_deck_editor')
  for i = 1, 36 do g:action('champion_toggle', i) end
  is_true(g:action('champion_save'))
  local first = S(g).championCards
  is_true(g:action('close_deck_editor'))
  eq(S(g).state, 'title'); eq(S(g).deckEditor, nil)
  is_true(g:action('open_deck_editor'))
  local ed2 = S(g).deckEditor
  eq(ed2.selectedCount, 36)
  eq(ed2.preselected, 36)
  eq(ed2.loadedFromSave, true)
  eq(ed2.savedCount, 36)
  local sigs = {}
  for i = 1, #first do sigs[M.signature(first[i])] = true end
  for i = 1, #ed2.chosen do assert(sigs[M.signature(ed2.chosen[i])], 'preselect mismatch at ' .. i) end
  is_true(g:action('champion_toggle', 1))
  eq(ed2.selectedCount, 35)
  is_true(g:action('champion_toggle', 40))
  eq(ed2.selectedCount, 36)
  is_true(g:action('champion_save'))
  eq(#S(g).championCards, 36)
  eq(#g._g.persist:readCollection().cards, 36)
end)

check('Editor preselects from an in-memory champion deck when no save exists', function()
  local g = newGame()
  S(g).progress.hardCleared = true
  local pool = DT.championPool()
  local live = {}
  for i = 1, 36 do live[i] = DT.clone(pool[i].card) end
  S(g).championCards = live
  is_true(g:action('open_deck_editor'))
  eq(S(g).deckEditor.selectedCount, 36)
  eq(S(g).deckEditor.preselected, 36)
  eq(S(g).deckEditor.loadedFromSave, false)
end)

check('Editor filter validates group keys', function()
  local g = newGame()
  S(g).progress.hardCleared = true
  g:action('open_deck_editor')
  is_true(g:action('champion_filter', 'basic'))
  eq(S(g).deckEditor.filter, 'basic')
  is_true(g:action('champion_filter', 'all'))
  eq(S(g).deckEditor.filter, 'all')
  local ok, err = g:action('champion_filter', 'nope')
  is_false(ok); eq(err, 'invalid_arg')
end)

check('Persisted writes stay on the injected memory fs (no saves21 pollution)', function()
  local g, files = newGame()
  S(g).progress.hardCleared = true
  g:action('open_deck_editor')
  for i = 1, 36 do g:action('champion_toggle', i) end
  g:action('champion_save')
  local n = 0
  for k in pairs(files) do
    n = n + 1
    assert(k:sub(1, 8) == 'saves21/', 'unexpected write path ' .. tostring(k))
  end
  assert(n >= 1, 'expected at least one memory write')
end)

print(string.format('meta_acceptance: PASS=%d FAIL=%d', pass, #failures))
if #failures > 0 then error(table.concat(failures, '\n')) end
