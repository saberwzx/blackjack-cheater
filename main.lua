-- main.lua : Blackjack Cheater UI entry point (LÖVE 11.5)
-- Owned by the UI layer. Renders src.game state via ui/ui.lua.
--
-- CLI:
--   love .                     normal run (requires src/game.lua)
--   love . --ui-demo[=scene]   explicit art harness; NEVER used implicitly
--   love . --smoke=table       real core init + drive to <scene>, screenshot, quit
--   love . --smoke-all         every smoke scene in sequence, then quit
--   love . --test              run tests/run.lua inside LÖVE, then exit with its code
--
-- Real saves always live inside the product directory (portable_fs.lua); there is
-- deliberately NO fallback to the LÖVE save directory. --smoke / --test inject an
-- in-memory filesystem so real progress is never touched.

local Theme = require("ui.theme")
local Fonts = require("ui.fonts")
local UI = require("ui.ui")
local Audio = require("ui.audio")
local Hot = require("ui.hot")

local SMOKE_SCENES = {
  "title", "relic", "table", "shop", "shoe", "deck", "bar", "gift", "pick",
  "ending", "editor", "settings", "tutorial", "stageClear", "class", "victory",
  "forceExit", "cheat_tells", "flow", "modal",
}

local CLI = { demo = nil, smoke = nil, smokeAll = false, test = false, seed = 20261001, size = nil }

local function parseArgs(argv)
  local i = 1
  while i <= #argv do
    local a = argv[i]
    local key, val = a:match("^%-%-([%w%-]+)=(.+)$")
    if key then
      if key == "ui-demo" then CLI.demo = val
      elseif key == "smoke" then CLI.smoke = val
      elseif key == "size" then CLI.size = val
      elseif key == "seed" then CLI.seed = tonumber(val) or CLI.seed end
    elseif a == "--ui-demo" then CLI.demo = "table"
    elseif a == "--smoke-all" then CLI.smokeAll = true
    elseif a == "--smoke" then
      local nxt = argv[i + 1]
      if nxt and not nxt:match("^%-%-") then CLI.smoke = nxt; i = i + 1 else CLI.smoke = "title" end
    elseif a == "--test" or a == "--tests" then CLI.test = true
    end
    i = i + 1
  end
end

-- Portable artifact directory: fused executables and .love archives put artifacts/
-- beside the executable (getSourceBaseDirectory), a source run uses getSource().
-- No machine-specific fallback: the packaged build ships an artifacts/ directory.
local function artifactsDir()
  local base
  local fused = love.filesystem.isFused and love.filesystem.isFused()
  local src = love.filesystem.getSource and love.filesystem.getSource()
  if fused or (type(src) == "string" and src:lower():sub(-5) == ".love") then
    base = love.filesystem.getSourceBaseDirectory and love.filesystem.getSourceBaseDirectory()
  end
  if type(base) ~= "string" or base == "" then base = src end
  if type(base) ~= "string" or base == "" then base = "." end
  base = base:gsub("\\", "/"):gsub("/+$", "")
  if base == "" then base = "." end
  return base .. "/artifacts/"
end

local function print_(...)
  print(...)
  io.stdout:flush()
end

-- ===== game instance =====
local M = { g = nil, cli = CLI, smoke = nil, demoMode = false, tests = nil, sceneFailures = {} }

-- In-memory filesystem for --smoke / --test: the real progress is never touched.
local function makeMemFs()
  local files = {}
  return {
    read = function(path) return files[path] end,
    write = function(path, data) files[path] = data; return true end,
    getInfo = function(path) if files[path] then return { type = "file" } end return nil end,
    mkdir = function() return true end,
    remove = function(path) files[path] = nil; return true end,
    createDirectory = function() return true end,
  }
end

-- portable_fs.lua (root) keeps real saves inside the product directory. Absence is
-- a hard error: falling back to love.filesystem would write to AppData, which the
-- product requirement forbids.
local function makePortableFs()
  local ok, mod = pcall(require, "portable_fs")
  if not (ok and type(mod) == "table" and type(mod.new) == "function") then
    print_("[blackjack-cheater] FATAL: portable_fs.lua unavailable -> " .. tostring(mod))
    error("portable_fs.lua is required so saves stay inside the product directory", 0)
  end
  local ok2, fs = pcall(mod.new)
  if not ok2 or not fs then
    print_("[blackjack-cheater] FATAL: portable_fs.new() failed -> " .. tostring(fs))
    error("portable_fs.new() failed", 0)
  end
  return fs
end

local function newRealGame(inMemory)
  local ok, Game = pcall(require, "src.game")
  if not ok then
    print_("[blackjack-cheater] FATAL: cannot load src.game ->")
    print_(tostring(Game))
    error("src.game unavailable; use --ui-demo for the art harness", 0)
  end
  local opts = {}
  if inMemory then opts.filesystem = makeMemFs() else opts.filesystem = makePortableFs() end
  return Game.new(opts)
end

local function addSceneFailure(msg)
  M.sceneFailures[#M.sceneFailures + 1] = tostring(msg)
  print_("[blackjack-cheater] SCENE_FAIL " .. tostring(msg))
end

-- ===== smoke scene driver =====
-- Test scenes run a REAL src.game on an in-memory filesystem. A scene may set
-- test-only progression fields (chips / stage / hardCleared) so a branch can be
-- reached deterministically, but every state change itself still goes through
-- g:action or the real timer loop (pumped with g:update).
local function driveScene(scene, seed)
  local g = M.g
  local function cur() return g.state.state end
  local function act(name, arg, expect)
    local ok, err = g:action(name, arg)
    local bad = (ok == false) or (ok == nil and err ~= nil)
    if bad then
      addSceneFailure(string.format("%s: action %s failed: %s", tostring(scene), name, tostring(err)))
      return false
    end
    if expect and g.state.state ~= expect then
      addSceneFailure(string.format("%s: after %s expected state %s, got %s",
        tostring(scene), name, expect, tostring(g.state.state)))
      return false
    end
    return true
  end
  local function start(mode, s)
    local ok, err = g:start(mode, s or seed)
    if ok == false or (ok == nil and err ~= nil) then
      addSceneFailure(string.format("%s: start(%s) failed: %s", tostring(scene), mode, tostring(err)))
      return false
    end
    return true
  end
  -- Real timers (self:after) only advance inside g:update, so a scene that wants
  -- to finish a round must pump the core.
  local function pump(seconds, pred)
    local t = 0
    while t < seconds do
      if pred and pred() then return true end
      local ok, err = pcall(function() g:update(1 / 30) end)
      if not ok then
        addSceneFailure(string.format("%s: g:update raised %s", tostring(scene), tostring(err)))
        return false
      end
      t = t + 1 / 30
    end
    return pred and pred() or true
  end
  local function field(fn, dflt)
    local ok, v = pcall(fn, g.state)
    if ok and v ~= nil then return v end
    return dflt
  end
  local function defaultBet()
    local chips = field(function(st) return st.chips end, 2500) or 2500
    local minB = field(function(st) return st.betMin end, 50) or 50
    if (field(function(st) return st.stage end, 1) or 1) >= 3 then
      minB = math.max(minB, math.floor(chips * 0.5))
    end
    local maxB = field(function(st) return st.betMax end, chips) or chips
    local b = 200
    if b < minB then b = minB end
    if maxB > 0 and b > maxB then b = maxB end
    return math.max(1, b)
  end
  local function beginRound()
    if cur() ~= "bet" then return true end
    g:action("bet_set", defaultBet())
    return act("bet_confirm")
  end
  local function toResult()
    if cur() == "player" then g:action("stand") end
    pump(10, function() return cur() == "result" end)
    return cur() == "result"
  end
  local function finishRound()
    toResult()
    if cur() == "result" then act("continue") end
  end
  -- 商店每 SHOP_EVERY 局开一次（阶段 1 为第 5 局），只能真实打满轮数。
  local function reachShop()
    local guard = 0
    while cur() ~= "shop" and guard < 14 do
      guard = guard + 1
      beginRound()
      finishRound()
      if cur() == "stageClear" or cur() == "victory" or cur() == "forceExit" then break end
    end
  end
  -- 酒吧：只有选择类技能会进入 bar_pick，用不同种子寻找一个真实可触发的那杯。
  local SELECTION = {
    swap_hand_card = true, swap_with_dealer = true,
    peek_sink_pick = true, pick_from_champion = true,
  }
  local function barToPlayer()
    if cur() == "bar_gift" then act("bar_gift_pick", 1) end
    return cur() == "player"
  end
  local function driveBarPick()
    local found = false
    for attempt = 0, 80 do
      start("bar", (seed or 1) + attempt)
      act("bar_begin")
      barToPlayer()
      local cup = field(function(st) return st.bar and st.bar.cups and st.bar.cups[1] end)
      local special = cup and cup.ability and cup.ability.special
      if special and SELECTION[special] then
        found = true
        act("bar_drink", 1)
        act("bar_ability", { id = cup.drink or cup.id }, "bar_pick")
        break
      end
    end
    if not found then addSceneFailure("pick: no selection cocktail within 80 seeds") end
  end
  local function driveBarEnding()
    start("bar", seed)
    act("bar_begin")
    barToPlayer()
    local guard = 0
    while cur() == "player" and guard < 40 do
      guard = guard + 1
      local n = field(function(st) return st.bar and #st.bar.cups end, 0) or 0
      local drank = false
      for i = 1, n do
        local cup = field(function(st) return st.bar and st.bar.cups and st.bar.cups[i] end)
        if cup and (cup.mouth or 0) < 5 and cur() == "player" then
          g:action("bar_drink", i)
          drank = true
        end
      end
      if not drank then break end
    end
  end
  -- 出千痕迹只在阶段 2/3 出现；把阶段推到 3（45% 出千率）后真实对局，直到核心
  -- 真的发出至少一个 tell 事件（绝不手工造 trace）。
  local function fxHasTell()
    local fx = (g.state.fx) or (rawget(g, "_g") and rawget(g, "_g").fx) or {}
    for i = 1, #fx do
      local e = fx[i]
      if type(e) == "table" and e.kind == "tell" then return true end
    end
    return false
  end
  -- Stop as soon as a real tell is queued, BEFORE the result overlay covers the
  -- table, so the screenshot actually shows the trace.
  local function driveCheatTells()
    local found = false
    local guard = 0
    while not found and guard < 60 do
      guard = guard + 1
      local st = g.state
      st.stage = 3
      st.stageTarget = 2000000
      st.chips = 2500
      if cur() == "bet" then beginRound() end
      if cur() == "player" then g:action("stand") end
      local t = 0
      -- stop on the first queued tell, while the table is still on screen
      while not found and t < 8 and cur() ~= "result" do
        local ok = pcall(function() g:update(1 / 30) end)
        if not ok then break end
        t = t + 1 / 30
        found = fxHasTell()             -- A / E deal tells, B / C / D dealer tells
      end
      if not found then
        pump(6, function() return cur() == "result" end)
        if cur() == "result" then act("continue") end
        if cur() == "stageClear" or cur() == "forceExit" then act("continue") end
      end
    end
    if not found then addSceneFailure("cheat_tells: no tell event within 60 rounds") end
  end

  if scene == "title" then return true end
  -- UI 脚本场景：设置完真实 Game 后由 runUIScript 用真实按键/鼠标驱动。
  if scene == "flow" or scene == "modal" then return true end
  if scene == "editor" then
    g.state.progress = g.state.progress or {}
    g.state.progress.hardCleared = true
    act("open_deck_editor", nil, "deckEditor")
    return true
  end
  if scene == "tutorial" then
    g:action("start_tutorial")
    return true
  end
  if scene == "relic" then
    start("normal")
    return true
  end
  if scene == "bar" then
    start("bar", seed)
    act("bar_begin")
    barToPlayer()
    return true
  end
  if scene == "gift" then
    start("bar", seed)
    act("bar_begin")
    return true
  end
  if scene == "pick" then
    driveBarPick()
    return true
  end
  if scene == "ending" then
    driveBarEnding()
    return true
  end

  if not start("normal") then return true end
  act("pick_relic", 1)

  if scene == "table" then
    beginRound()
    return true
  end
  if scene == "shop" then
    reachShop()
    return true
  end
  if scene == "shoe" then
    beginRound()
    act("open_shoe")
    return true
  end
  if scene == "deck" then
    beginRound()
    act("open_deck")
    return true
  end
  if scene == "settings" then
    beginRound()
    M.forceSettings = true
    return true
  end
  if scene == "cheat_tells" then
    driveCheatTells()
    return true
  end
  if scene == "stageClear" or scene == "class" or scene == "victory" or scene == "forceExit" then
    beginRound()
    if cur() ~= "player" then
      addSceneFailure(scene .. ": expected player state, got " .. tostring(cur()))
      return true
    end
    if scene == "class" then g.state.stage = 2 end
    if scene == "victory" then g.state.stage = 3 end
    if scene == "class" or scene == "stageClear" then
      g.state.roundsInStage = g.state.stageRounds
    end
    if scene ~= "forceExit" then
      g.state.chips = math.max(g.state.chips or 0, g.state.stageTarget or 0) + 1000
    end
    toResult()
    if scene == "forceExit" then g.state.afterResult = "forceExit" end
    if cur() == "result" then act("continue") end
    -- stage 2/3 show the stageClear panel first; a second continue advances
    if (scene == "victory" or scene == "class") and cur() == "stageClear" then act("continue") end
    return true
  end
  return true
end

-- Expected post-setup state per smoke scene; a mismatch is a real failure.
local SCENE_EXPECT = {
  title = function(g) return g.state.state == "title" end,
  relic = function(g) return g.state.state == "relic_select" end,
  table = function(g) return g.state.state == "player" or g.state.state == "dealer" or g.state.state == "result" end,
  shop = function(g) return g.state.state == "shop" end,
  shoe = function(g) return g.state.shoeOpen == true end,
  deck = function(g) return g.state.deckOpen == true end,
  bar = function(g) return g.state.mode == "bar" and g.state.state == "player" end,
  gift = function(g) return g.state.state == "bar_gift" end,
  pick = function(g) return g.state.state == "bar_pick" end,
  ending = function(g) return g.state.state == "bar_ending" end,
  editor = function(g) return g.state.state == "deckEditor" end,
  settings = function(g) return UI.settingsOpen == true end,
  tutorial = function(g) return g.state.tutorial ~= nil and g.state.tutorial.active == true end,
  stageClear = function(g) return g.state.state == "stageClear" end,
  class = function(g) return g.state.state == "classSelect" end,
  victory = function(g) return g.state.state == "victory" end,
  forceExit = function(g) return g.state.state == "forceExit" end,
  cheat_tells = function(g) return g.state.state == "player" or g.state.state == "dealer" or g.state.state == "result" end,
}

local function verifyScene(scene)
  local fn = SCENE_EXPECT[scene]
  if not fn then return end
  local ok, res = pcall(fn, M.g)
  if not ok or not res then
    addSceneFailure(string.format("%s: unexpected state %s (mode %s)", tostring(scene),
      tostring(M.g and M.g.state and M.g.state.state), tostring(M.g and M.g.state and M.g.state.mode)))
  end
end

function M.setupScene(scene)
  M.sceneFailures = {}
  local seed = CLI.seed
  M.forceSettings = false
  if CLI.demo then
    local Demo = require("ui.demo")
    M.g = Demo.new(scene)
    M.demoMode = true
  else
    M.g = newRealGame(CLI.smoke ~= nil or CLI.smokeAll or CLI.test)
    local ok, err = pcall(driveScene, scene, seed)
    if not ok then addSceneFailure(tostring(scene) .. ": driveScene raised " .. tostring(err)) end
  end
  UI.settingsOpen = (M.forceSettings == true) or (UI.settingsOpen == true) or false
  M.forceSettings = false
  if not CLI.demo then verifyScene(scene) end
  UI.init(M.g)
  local st = M.g.state
  if st and st.settings then
    Audio.setVolume(st.settings.volume or 0.6)
  end
  UI.applyBGMForState()
  -- flow/modal are driven through the real input chain after the first draw
  -- (see runUIScript), once Hot.registry holds this frame's hotspots.
  M.scriptScene = (scene == "flow" or scene == "modal") and scene or nil
  M.uiScript = nil
  return #M.sceneFailures == 0
end

-- ===== tests =====
-- Contract: tests.run({...}) returns (ok, report); report = {pass, fail, errors, logs, reproducible}.
local function runTests()
  local ok, mod = pcall(require, "tests.run")
  if not ok then
    print_("[blackjack-cheater] FATAL: cannot load tests.run -> " .. tostring(mod))
    return 2
  end
  local runner = (type(mod) == "table" and type(mod.run) == "function" and mod.run) or (type(mod) == "function" and mod) or nil
  if not runner then
    print_("[blackjack-cheater] FATAL: tests.run has no callable .run()")
    return 2
  end
  local called, a, b = pcall(runner, { verbose = false })
  if not called then
    print_("[blackjack-cheater] FATAL: tests.run raised -> " .. tostring(a))
    return 2
  end
  local report = nil
  if type(a) == "table" then
    report = a
  elseif type(a) == "boolean" then
    -- (ok, report) form
    report = (type(b) == "table") and b or { pass = a and 1 or 0, fail = a and 0 or 1 }
  elseif type(a) == "nil" and type(b) == "table" then
    report = b
  else
    print_("[blackjack-cheater] FATAL: unexpected tests.run return type " .. type(a))
    return 2
  end
  local fails = tonumber(report.fail or 0) or 0
  local passes = tonumber(report.pass or 0) or 0
  print_(string.format("[blackjack-cheater] TESTS pass=%s fail=%s reproducible=%s",
    tostring(passes), tostring(fails), tostring(report.reproducible)))
  local errs = report.errors
  if type(errs) == "table" then
    local n = 0
    for k, e in pairs(errs) do
      n = n + 1
      if n > 40 then print_("  ... more errors truncated"); break end
      print_(string.format("  FAIL %s %s", tostring(k), tostring(e)))
    end
    if fails == 0 and n > 0 then fails = n end
  end
  if fails > 0 then return 1 end
  return 0
end

-- ===== screenshot =====
-- LuaJIT's io.open uses the ANSI API and fails on non-ASCII install paths
-- (e.g. Chinese project folders), so artifact writes fall back to the
-- wide-char CRT through the LuaJIT FFI.
local ffiOk, ffi = pcall(require, "ffi")
local wideWrite = false
if ffiOk and jit and jit.os == "Windows" then
  wideWrite = pcall(ffi.cdef, [[
    void *_wfopen(const wchar_t *path, const wchar_t *mode);
    size_t fwrite(const void *ptr, size_t size, size_t count, void *stream);
    int fclose(void *stream);
    int MultiByteToWideChar(unsigned int codePage, unsigned long flags,
      const char *multiByteStr, int multiByteLen, wchar_t *wideStr, int wideLen);
  ]])
end
local kernel32 = ffiOk and wideWrite and ffi.load("kernel32") or nil

local function utf8ToWide(s)
  local n = kernel32.MultiByteToWideChar(65001, 0, s, #s, nil, 0)
  local buf = ffi.new("wchar_t[?]", n + 1)
  kernel32.MultiByteToWideChar(65001, 0, s, #s, buf, n)
  buf[n] = 0
  return buf
end

local function writeFilePortable(path, data)
  local f = io.open(path, "wb")
  if f then
    f:write(data)
    f:close()
    return true
  end
  if wideWrite then
    local w = ffi.C._wfopen(utf8ToWide(path), utf8ToWide("wb"))
    if w ~= nil then
      ffi.C.fwrite(data, 1, #data, w)
      ffi.C.fclose(w)
      return true
    end
  end
  return false
end

local function savePng(img, path)
  local fd = img:encode("png")
  if writeFilePortable(path, fd:getString()) then return true end
  return false, "cannot open " .. path
end

local smokeState = {
  scenes = {}, index = 0, frame = 0, requested = false, saved = false,
  shotCount = 0, failed = {}, crashed = false,
}

local uiScript = nil
local function uiResetScript() uiScript = nil end

local function beginScene(scene)
  uiResetScript()
  smokeState.frame = 0
  smokeState.requested = false
  smokeState.saved = false
  UI.settingsOpen = false
  UI.toasts = {}
  M.setupScene(scene)
  for _, f in ipairs(M.sceneFailures) do smokeState.failed[#smokeState.failed + 1] = f end
  smokeState.current = scene
end

local function finishSmoke(code)
  local ok = (code == nil) and (smokeState.shotCount > 0 and #smokeState.failed == 0 and not smokeState.crashed)
  local exit = code
  if exit == nil then exit = ok and 0 or 1 end
  print_(string.format("[blackjack-cheater] SMOKE_DONE shots=%d failed=%d", smokeState.shotCount, #smokeState.failed))
  for _, f in ipairs(smokeState.failed) do print_("  FAILED " .. f) end
  love.event.quit(exit)
end

-- ===== real-input smoke scripts =====
-- One real input chain (title -> mode -> relic -> bet -> action -> result ->
-- continue) plus the key modal-exclusivity checks. Everything goes through the
-- same UI.keypressed / UI.mousepressed the player uses -- no direct state jumps.
local function uiFail(msg)
  smokeState.failed[#smokeState.failed + 1] = msg
  print_("[blackjack-cheater] UIFAIL " .. msg)
end

-- Click the registered hotspot with this id through the real mouse chain.
local function uiClick(id)
  local hs = Hot.registry[tostring(id)]
  if not (hs and hs.enabled ~= false) then return false end
  local x, y
  if hs.r then
    x, y = hs.x, hs.y
  else
    x, y = (hs.x or 0) + (hs.w or 0) * 0.5, (hs.y or 0) + (hs.h or 0) * 0.5
  end
  UI.mousepressed(x, y, 1)
  UI.mousereleased(x, y, 1)
  return true
end

local function uiHandCount(side)
  local st = M.g.state
  local ent = (side == "dealer") and st.dealer or st.player
  return (ent and ent.hand and #ent.hand) or 0
end

-- A modal is exclusive: pressing H while it is open must not move a card.
local function uiVeiled(what, before)
  local now = uiHandCount("player")
  if now ~= before then
    uiFail("modal: 打开" .. what .. "时按 H 改变了手牌数(" .. before .. "→" .. now .. ")")
    return false
  end
  return true
end

local function buildScript(scene)
  local steps = {}
  local function step(desc, fn) steps[#steps + 1] = { desc = desc, fn = fn } end

  step("标题 Enter → 模式选择", function()
    UI.keypressed("return")
    return UI.localScreen == "modeSelect"
  end)
  step("模式选择：点基础模式", function()
    if not uiClick("mode.pick.normal") then return false end
    return M.g.state.state == "relic_select"
  end)
  step("遗物三选一：点第一张", function()
    if not uiClick("relsel.1") then return false end
    return M.g.state.state == "bet"
  end)
  step("下注：点 $200 预设", function()
    if not uiClick("tbl.preset.3") then return false end
    return M.g.state.bet == 200
  end)
  step("下注：确认", function()
    if not uiClick("tbl.confirm") then return false end
    return M.g.state.state == "player"
  end)

  if scene == "flow" then
    step("对局：按 H 要牌", function()
      local st = M.g.state
      local before = uiHandCount("player")
      UI.keypressed("h")
      if uiHandCount("player") > before then return true end
      -- 自然 21 时核心会拒绝要牌，这不是 UI 没出手
      return (st.player and st.player.blackjack == true)
    end)
    step("对局：按 S 停牌", function()
      if M.g.state.state == "player" then UI.keypressed("s") end
      return M.g.state.state == "dealer" or M.g.state.state == "result"
    end)
    step("结果：等待结算", function()
      return M.g.state.state == "result"
    end)
    step("结果：点继续", function()
      return uiClick("tbl.continue")
    end)
    return steps
  end

  -- modal scene
  step("设置：F1 打开", function()
    if not UI.settingsOpen then UI.keypressed("f1") end
    return UI.settingsOpen == true
  end)
  step("设置模态独占：H 不得出手", function()
    local before = uiHandCount("player")
    UI.keypressed("h")
    return uiVeiled("设置", before)
  end)
  step("设置：Esc 关闭", function()
    UI.keypressed("escape")
    return UI.settingsOpen == false
  end)
  step("情报：I 打开", function()
    if not M.g.state.shoeOpen then UI.keypressed("i") end
    return M.g.state.shoeOpen == true
  end)
  step("情报模态独占：H 不得出手", function()
    local before = uiHandCount("player")
    UI.keypressed("h")
    if not uiVeiled("情报", before) then return true end
    return M.g.state.shoeOpen == true
  end)
  step("情报：Esc 关闭", function()
    UI.keypressed("escape")
    return M.g.state.shoeOpen ~= true
  end)
  step("教程：start_tutorial", function()
    M.g:action("start_tutorial")
    return M.g.state.tutorial ~= nil and M.g.state.tutorial.active == true
  end)
  step("教程：完成下注门进入对局", function()
    if M.g.state.state == "bet" then
      uiClick("tbl.preset.3")
      uiClick("tbl.confirm")
    end
    return M.g.state.state == "player"
  end)
  step("教程独占：Enter 由教程消费（不得触发停牌）", function()
    local st0 = M.g.state.state
    UI.keypressed("return")
    if M.g.state.state ~= st0 then
      uiFail("modal: 教程打开时 Enter 穿透到底层（" .. st0 .. "→" .. M.g.state.state .. "）")
    end
    return true
  end)
  step("教程不锁玩法：H 仍可要牌", function()
    local st = M.g.state
    local before = uiHandCount("player")
    UI.keypressed("h")
    if uiHandCount("player") > before then return true end
    -- 自然 21 / 已经不在玩家回合：核心拒绝要牌，不算教程锁玩法
    if st.player and st.player.blackjack then return true end
    if st.state ~= "player" then return true end
    return false
  end)
  return steps
end

-- Runs after UI.draw so Hot.registry holds this frame's live hotspots.
local function runUIScript()
  if not M.g or M.tests or not M.scriptScene then return end
  if uiScript and uiScript.scene ~= M.scriptScene then uiScript = nil end
  if not uiScript then
    uiScript = { steps = buildScript(M.scriptScene), index = 1, scene = M.scriptScene }
  end
  if uiScript.done then return end
  while uiScript.index <= #uiScript.steps do
    local stp = uiScript.steps[uiScript.index]
    local ok, res = pcall(stp.fn)
    if not ok then
      uiFail(uiScript.scene .. " UI 步骤失败 [" .. stp.desc .. "]: " .. tostring(res))
      uiScript.done = true
      break
    end
    if res then
      uiScript.index = uiScript.index + 1
      uiScript.stall = 0
      uiScript.stallStep = nil
    else
      if uiScript.stallStep ~= stp.desc then uiScript.stallStep = stp.desc; uiScript.stall = 0 end
      uiScript.stall = (uiScript.stall or 0) + 1
      if uiScript.stall == 90 then
        local st = M.g.state
        print_(string.format("[blackjack-cheater] UISTALL %s [%s] state=%s local=%s bet=%s hand=%d shoeOpen=%s settings=%s tut=%s",
          tostring(uiScript.scene), tostring(stp.desc), tostring(st.state), tostring(UI.localScreen),
          tostring(st.bet), uiHandCount("player"), tostring(st.shoeOpen), tostring(UI.settingsOpen),
          tostring(st.tutorial and st.tutorial.active and st.tutorial.step or false)))
      end
      break
    end
  end
  if uiScript.index > #uiScript.steps then
    uiScript.done = true
    print_("[blackjack-cheater] UI_SCRIPT_DONE " .. tostring(uiScript.scene))
  end
end

M.uiScriptDone = function() return (M.scriptScene == nil) or (uiScript ~= nil and uiScript.done == true) end

-- ===== error handling =====
local defaultErrorHandler = love.errorhandler

local function writeErrorLog(text)
  local path = artifactsDir() .. "last_error.txt"
  if writeFilePortable(path, text) then return path end
  return nil
end

local function headlessMode()
  return (CLI.smoke or CLI.smokeAll or CLI.test) and true or false
end

-- --smoke/--test must never park on LÖVE's blue error page (that deadlocks the
-- calling job): log the failure, record it and exit non-zero. A normal run
-- keeps the default error page so a developer can read it interactively.
function love.errorhandler(msg)
  local text = tostring(msg)
  local trace = debug.traceback(text, 2)
  print_("[blackjack-cheater] FATAL: " .. text)
  print_(trace)
  if #smokeState.scenes > 0 or M.tests then
    smokeState.crashed = true
    smokeState.failed[#smokeState.failed + 1] = text
  end
  if headlessMode() then
    local p = writeErrorLog("[blackjack-cheater] FATAL: " .. text .. "\n" .. trace .. "\n")
    if p then print_("[blackjack-cheater] ERROR_LOG " .. p) end
    love.event.quit(1)
    return function() love.event.quit(1) end
  end
  if defaultErrorHandler then
    local ok, res = pcall(defaultErrorHandler, msg)
    if ok and res then return res end
  end
  love.event.quit(1)
  return function() love.event.quit(1) end
end

local function coreError(where, err)
  local msg = string.format("core %s error: %s", where, tostring(err))
  print_("[blackjack-cheater] FATAL: " .. msg)
  print_(debug.traceback(msg, 2))
  if headlessMode() then
    local p = writeErrorLog("[blackjack-cheater] FATAL: " .. msg .. "\n" .. debug.traceback("", 2) .. "\n")
    if p then print_("[blackjack-cheater] ERROR_LOG " .. p) end
  end
  smokeState.failed[#smokeState.failed + 1] = msg
  smokeState.crashed = true
  M.updateErrCount = (M.updateErrCount or 0) + 1
  if #smokeState.scenes > 0 or M.tests then
    love.event.quit(1)
  elseif M.updateErrCount >= 3 then
    error(msg, 0)
  end
end

-- ===== love callbacks =====
local function loadBody(argv)
  parseArgs(argv or {})
  love.graphics.setDefaultFilter("linear", "linear", 4)
  love.math.setRandomSeed(CLI.seed)
  -- --size=WxH pins the window for screenshot passes (800x600 / 1280x720 / ...).
  if CLI.size then
    local w, h = tostring(CLI.size):match("^(%d+)x(%d+)$")
    if w then
      pcall(function()
        love.window.setMode(tonumber(w), tonumber(h),
          { resizable = true, vsync = 1, minwidth = 800, minheight = 600 })
      end)
    end
  end
  Theme.setSize(love.graphics.getWidth(), love.graphics.getHeight())
  Fonts.loadBaseData()

  if CLI.test then
    M.tests = true
    return
  end

  if CLI.smokeAll then
    smokeState.scenes = {}
    for _, s in ipairs(SMOKE_SCENES) do table.insert(smokeState.scenes, s) end
  elseif CLI.smoke then
    smokeState.scenes = { CLI.smoke }
  end

  if #smokeState.scenes > 0 then
    smokeState.index = 1
    beginScene(smokeState.scenes[1])
  elseif CLI.demo then
    smokeState.scenes = { CLI.demo }
    smokeState.index = 1
    smokeState.interactive = true
    beginScene(CLI.demo)
  else
    -- normal run: build the real game and show the title screen
    M.setupScene("title")
  end
end

function love.load(argv)
  local ok, err = pcall(loadBody, argv)
  if not ok then
    print_("[blackjack-cheater] FATAL: startup error: " .. tostring(err))
    print_(debug.traceback(tostring(err), 2))
    M.startupFailed = true
    if headlessMode() then
      smokeState.failed[#smokeState.failed + 1] = "startup: " .. tostring(err)
      local p = writeErrorLog("[blackjack-cheater] FATAL: startup error: " .. tostring(err) .. "\n")
      if p then print_("[blackjack-cheater] ERROR_LOG " .. p) end
      love.event.quit(1)
    else
      error(err, 0)
    end
  end
end

function love.update(dt)
  if dt > 0.1 then dt = 0.1 end
  if M.startupFailed then return end
  if M.tests then return end
  if M.g and M.g.update then
    local ok, err = pcall(function() M.g:update(dt) end)
    if not ok then coreError("update", err) end
  end
  UI.update(dt)
  M.applyVideo()
end

function love.draw()
  if M.startupFailed then love.event.quit(1); return end
  love.graphics.clear(Theme.colors.bg0)
  UI.draw()

  runUIScript()

  local inSmoke = #smokeState.scenes > 0 and not smokeState.interactive
  if inSmoke then
    smokeState.frame = smokeState.frame + 1
    if smokeState.frame >= 26 and M.uiScriptDone() and not smokeState.requested and not smokeState.saved then
      smokeState.requested = true
      local dir = artifactsDir()
      local sizeTag = CLI.size and ("_" .. CLI.size) or ""
      local path = dir .. "smoke_" .. tostring(smokeState.current) .. sizeTag .. ".png"
      local fired = false
      love.graphics.captureScreenshot(function(img)
        if fired then return end
        fired = true
        local ok, err = savePng(img, path)
        if ok then
          smokeState.shotCount = smokeState.shotCount + 1
          smokeState.saved = true
          print_("[blackjack-cheater] SMOKE_SHOT " .. path)
        else
          smokeState.failed[#smokeState.failed + 1] = tostring(smokeState.current) .. ": " .. tostring(err)
          smokeState.saved = true
        end
      end)
    elseif smokeState.saved and smokeState.frame >= 30 then
      if smokeState.index < #smokeState.scenes then
        smokeState.index = smokeState.index + 1
        beginScene(smokeState.scenes[smokeState.index])
      else
        finishSmoke()
      end
    elseif smokeState.frame > 600 then
      smokeState.failed[#smokeState.failed + 1] = tostring(smokeState.current) .. ": timeout"
      finishSmoke(1)
    end
  end

  if M.tests then
    local code = runTests()
    love.event.quit(code)
  end
end

-- Resolution is a ProjectSettings string like "1280x720" (legacy numeric 1..4 is
-- still accepted). Never infer it from a font or window size.
local RESOLUTIONS = {
  ["800x600"] = { 800, 600 }, ["1280x720"] = { 1280, 720 },
  ["1600x900"] = { 1600, 900 }, ["1920x1080"] = { 1920, 1080 },
  [1] = { 800, 600 }, [2] = { 1280, 720 }, [3] = { 1600, 900 }, [4] = { 1920, 1080 },
}

function M.applyVideo()
  if CLI.size then return end
  if not M.g then return end
  local st = M.g.state
  if not st or not st.settings then return end
  local s = st.settings
  local res = s.resolution
  local target = RESOLUTIONS[res] or RESOLUTIONS["1280x720"]
  local full = s.fullscreen and true or false
  if M._lastRes ~= res or M._lastFull ~= full then
    M._lastRes, M._lastFull = res, full
    local ok = pcall(function()
      love.window.setMode(target[1], target[2],
        { resizable = true, fullscreen = full, vsync = 1, minwidth = 800, minheight = 600 })
    end)
    if ok then Theme.setSize(love.graphics.getWidth(), love.graphics.getHeight()) end
  end
end

function love.resize(w, h)
  Theme.setSize(w, h)
end

function love.keypressed(key)
  if M.tests then return end
  if UI and UI.g then UI.keypressed(key) end
end

function love.mousepressed(x, y, button)
  if M.tests then return end
  if UI and UI.g then UI.mousepressed(x, y, button) end
end

function love.mousemoved(x, y, dx, dy)
  if UI and UI.g then UI.mousemoved(x, y) end
end

function love.mousereleased(x, y, button)
  if UI and UI.g then UI.mousereleased(x, y, button) end
end

function love.wheelmoved(dx, dy)
  if M.tests then return end
  if UI and UI.g then UI.wheelmoved(dx, dy) end
end

function love.quit()
  return false
end

M.smokeState = smokeState
return M
