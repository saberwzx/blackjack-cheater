-- src/meta_actions.lua
-- 元系统独立实现（由 src/game_state.lua 底部 pcall require，并在 return 前 install(GS)）。
-- 只覆盖「教程运行器」与「冠军牌组编辑器」相关方法，不改动核心状态机源码。
--
-- 设计要点：
--  * 教程运行器：st.tutorialRun（Tutorial 实例，内部） + st.tutorial（UI 投影）。
--    UI 投影字段与 docs/API.md §4.11、ui/demo.lua:224-244 完全一致：
--      { active, step, total, phase={index,title,text,requireAction,actionHint}, done }
--  * 6 个动作门（GDD §19.3）：bet / round_end / open_deck / close_deck / pick_relic / activate_relic。
--    只在真实动作发生且不越过层级时推进；tutorial_advance 在动作门上恒返回
--    false,'tutorial_action_required'（禁止用「继续」、ESC/close_top 等捷径跳过）。
--  * 冠军编辑器：牌池取附录 C4 的明确分项（345 张，而非 GDD 正文合计 290），
--    解锁条件 hardCleared，保存必须恰 36 张且逐张白名单校验，支持重复加载/保存/预选。
--
-- install(GS) 幂等；测试可直接：
--   local GS = require('src.game_state'); require('src.meta_actions').install(GS)

local Tutorial = require('src.tutorial')
local Champion = require('src.champion')
local DT = require('src.deck_types')
local Relics = require('src.relics')

local M = {}
M.VERSION = 1

-- 触发动作门的核心方法（方法级包装，直接调用也能推进）
local GATE_BY_METHOD = {
  bet_confirm = 'bet',
  finalizeRound = 'round_end',
  pick_relic = 'pick_relic',
  use_relic = 'activate_relic',
  toggle_relic = 'activate_relic',
}

-- 走 GS:action 直通分支的动作门（核心里 open_deck/close_deck 不过 tutorialNotify）
local GATE_BY_ACTION = {
  open_deck = 'open_deck',
  close_deck = 'close_deck',
}

-- 进入步骤时可由当前状态直接判定「已发生」的门（用于下注即自然 21 直接结算、
-- 或进入 open_deck 步骤前牌堆已经打开等情况，避免教程卡死）
local AUTO_GATES = { round_end = true, open_deck = true }

-- 教程第 10 步的确定性三选一：全部为 active 消耗品，保证第 11 步可真实激活。
M.TUTORIAL_RELIC_IDS = { 'peek_1', 'burn_1', 'discard_rinse' }

-- 与 src/persist.lua CARD_FIELDS 完全一致（冠军牌组持久化白名单）
local CARD_FIELDS = {
  'rank', 'suit', 'kind', 'label', 'value',
  'is_67', 's67_rank', 'is_rps', 'rps_symbol',
  'is_blackhole', 'is_cage', 'is_chip', 'mult_bonus',
  'is_basic', 'is_synthetic',
}

-- 签名：把牌面映射为稳定字符串，用于「已保存的 36 张 -> 牌池牌面」匹配。
-- 只用白名单中有语义的字段（label 是派生显示名，不进签名）。
local SIG_FIELDS = {
  'rank', 'suit', 'kind', 'is_67', 's67_rank', 'is_rps', 'rps_symbol',
  'is_blackhole', 'is_cage', 'is_chip', 'mult_bonus', 'is_basic', 'is_synthetic',
}

local function fmtNum(v)
  if v ~= v or v == math.huge or v == -math.huge then return 'nan' end
  if v == math.floor(v) and math.abs(v) < 1e15 then return string.format('%d', v) end
  return string.format('%.6g', v)
end

local function signature(c)
  if type(c) ~= 'table' then return '' end
  local parts = {}
  for i = 1, #SIG_FIELDS do
    local f = SIG_FIELDS[i]
    local v = c[f]
    local t = type(v)
    if t == 'number' then parts[#parts + 1] = f .. '=' .. fmtNum(v)
    elseif t == 'boolean' then parts[#parts + 1] = f .. '=' .. (v and '1' or '0')
    elseif t == 'string' then parts[#parts + 1] = f .. '=' .. v
    else parts[#parts + 1] = f .. '=nil' end
  end
  return table.concat(parts, '|')
end
M.signature = signature

local function countSelected(sel)
  local n = 0
  if type(sel) == 'table' then for _ in pairs(sel) do n = n + 1 end end
  return n
end

local function selectedFaces(ed)
  local faces = {}
  for face, on in pairs(ed.selected or {}) do if on then faces[#faces + 1] = face end end
  table.sort(faces)
  return faces
end

local function buildChosen(ed)
  local out = {}
  local faces = selectedFaces(ed)
  for i = 1, #faces do
    local face = ed.pool[faces[i]]
    if face then out[#out + 1] = DT.clone(face.card) end
  end
  return out
end

local function refreshEditor(ed)
  ed.selectedFaces = selectedFaces(ed)
  ed.selectedCount = #ed.selectedFaces
  ed.chosen = buildChosen(ed)
  if ed.preselected == nil then ed.preselected = ed.selectedCount end
  ed.dirty = (ed.selectedCount ~= ed.preselected)
  return ed
end

-- ===================== 教程 =====================

local function relicCandidates()
  local out = {}
  for i = 1, #M.TUTORIAL_RELIC_IDS do
    local d = Relics.byId(M.TUTORIAL_RELIC_IDS[i])
    if d then
      out[#out + 1] = {
        id = d.id, name = d.name, desc = d.desc, rarity = d.rarity, price = d.price,
        def = d, consumable = (d.consumes == true),
      }
    end
  end
  return out
end
M.relicCandidates = relicCandidates

local function syncTutorialView(st)
  local run = st.tutorialRun
  local view = st.tutorial
  if type(view) ~= 'table' then view = {} end
  if not run then
    view.active = false
    view.done = true
    view.total = view.total or (Tutorial.count or #Tutorial.PHASES)
    view.step = view.step or view.total
    st.tutorial = view
    return view
  end
  local step = run:current()
  local done = run:isDone()
  view.active = not done
  view.done = done
  view.step = run:stepNumber()
  view.total = #(run.steps or Tutorial.PHASES)
  view.lastRejected = run.lastRejected
  if step then
    view.phase = {
      index = view.step,
      id = step.id,
      title = step.title or '',
      text = step.text or '',
      requireAction = (step.type == 'requireAction') and step.action or nil,
      actionHint = step.actionHint or '',
    }
  end
  st.tutorial = view
  return view
end

local function gateAutoSatisfied(self, gate)
  local st = self.state
  if gate == 'round_end' then return st.result ~= nil end
  if gate == 'open_deck' then return st.deckOpen == true end
  return false
end

local function advanceGateRaw(self, gate)
  local run = self.state.tutorialRun
  if not run then return false end
  local ok = run:advance(gate)
  if ok == false then return false end
  self.state.lastAction = gate
  if run:isDone() then self.state.tutorialRun = nil end
  return true
end

-- 进入「选遗物」步骤时，在下注阶段弹出确定性三选一；其余时机挂起，
-- 由随后的 beginBet（例如结算后点「继续」）自然衔接弹出。
local function trySpawnTutorialRelic(self)
  local st = self.state
  local run = st.tutorialRun
  if not run then st.tutorialPendingRelic = nil; return false end
  local step = run:current()
  if not step or step.action ~= 'pick_relic' then st.tutorialPendingRelic = nil; return false end
  if st.relicSelect then return true end
  if st.state == 'bet' then
    st.relicSelect = { candidates = relicCandidates(), picked = nil }
    self:setState('relic_select')
    st.tutorialPendingRelic = nil
    return true
  end
  st.tutorialPendingRelic = true
  return false
end

local function syncAndCascade(self, allowCascade)
  local st = self.state
  if allowCascade then
    local guard = 0
    while st.tutorialRun and guard < 6 do
      guard = guard + 1
      local run = st.tutorialRun
      if run:isDone() then break end
      local step = run:current()
      if not step or step.type ~= 'requireAction' then break end
      if not AUTO_GATES[step.action] or not gateAutoSatisfied(self, step.action) then break end
      if not advanceGateRaw(self, step.action) then break end
    end
  end
  if st.tutorialRun and st.tutorialRun:isDone() then st.tutorialRun = nil end
  local completed = (st.tutorialRun == nil)
  syncTutorialView(st)
  if completed and not st._tutorialCompletedMsg then
    st._tutorialCompletedMsg = true
    self:msg('教程完成，祝你好运。', 'success')
  end
  if st.tutorialRun then
    local step = st.tutorialRun:current()
    if step and step.type == 'requireAction' and step.action == 'pick_relic' then
      trySpawnTutorialRelic(self)
    end
  end
  return completed
end

-- 动作门判定：只在当前步骤正好要求该门、且后置条件成立时推进。
local function metaObserve(self, gate)
  local st = self.state
  local run = st.tutorialRun
  if not run then return false end
  local step = run:current()
  if not step or step.type ~= 'requireAction' or step.action ~= gate then return false end
  if gate == 'open_deck' and st.deckOpen ~= true then return false end
  if gate == 'close_deck' and st.deckOpen == true then return false end
  if gate == 'activate_relic' and #(st.relics or {}) == 0 then return false end
  if not advanceGateRaw(self, gate) then return false end
  syncAndCascade(self, true)
  return true
end

local function startTutorial(self)
  self:resetState()
  local st = self.state
  st.mode = 'normal'
  st.playerClass = nil
  st.class = nil
  st.dealerClass = nil
  st.stage = 1
  self:applyStage(1)
  st.chips = Tutorial.START_CHIPS or 2500
  st.relics = {}
  st.relicSlotMax = 5
  st.tutorialPendingRelic = nil
  st._tutorialCompletedMsg = nil
  st.lastAction = nil
  st.tutorialRun = Tutorial.new()
  st.tutorial = {}
  syncTutorialView(st)
  st.state = 'bet'
  self:beginBet()
  syncAndCascade(self, true)
  self:msg('教程开始：' .. tostring(Tutorial.PHASES[1].title), 'info')
  return true
end

local function tutorialAdvance(self)
  local st = self.state
  local run = st.tutorialRun
  if not run then return true end
  local step = run:current()
  if not step then
    st.tutorialRun = nil
    syncTutorialView(st)
    return true
  end
  if step.type == 'requireAction' then
    run.lastRejected = { id = step.id, need = step.action, hint = step.actionHint }
    syncTutorialView(st)
    return self:fail('tutorial_action_required')
  end
  local ok = run:advance('manual')
  if ok == false then
    run.lastRejected = { id = step.id, need = step.action, hint = step.actionHint }
    syncTutorialView(st)
    return self:fail('tutorial_action_required')
  end
  syncAndCascade(self, true)
  return true
end

-- ===================== 冠军牌组编辑器 =====================

local function isUnlocked(self)
  if Champion.canEdit and Champion.canEdit(self.progress) then return true end
  local st = self.state
  if st.progress and st.progress.hardCleared == true then return true end
  return false
end

local function openDeckEditor(self)
  if not isUnlocked(self) then return self:fail('locked') end
  local st = self.state
  local pool = DT.championPool()
  local saved
  if self.persist and self.persist.readCollection then
    saved = self.persist:readCollection()
  end
  if type(saved) ~= 'table' then saved = { version = 1, cards = {}, savedAt = 0, size = 'small' } end
  local savedCards = saved.cards or {}

  -- 预选来源：当前内存中的 36 张优先，否则用已保存的 36 张
  local source = nil
  if #(st.championCards or {}) == Champion.SIZE then source = st.championCards
  elseif #savedCards == Champion.SIZE then source = savedCards end

  local selected = {}
  if source then
    local used = {}
    for i = 1, #source do
      local sig = signature(source[i])
      for fi = 1, #pool do
        if not used[fi] and signature(pool[fi].card) == sig then
          used[fi] = true
          selected[fi] = true
          break
        end
      end
    end
  end

  local ed = {
    pool = pool,
    groups = DT.championGroupCounts(),
    selected = selected,
    max = Champion.SIZE,
    unlocked = true,
    filter = 'all',
    saved = saved,
    savedCards = savedCards,
    savedCount = #savedCards,
    loadedFromSave = (#savedCards == Champion.SIZE),
    preselected = countSelected(selected),
    message = '',
  }
  refreshEditor(ed)
  ed.preselected = ed.selectedCount
  ed.dirty = false
  st.deckEditor = ed
  -- 已达到「上架」条件的 36 张同步为当前冠军牌组，供 buildShoe 使用
  if #savedCards == Champion.SIZE then st.championCards = savedCards end
  self:setState('deckEditor')
  return true
end

local function closeDeckEditor(self)
  self.state.deckEditor = nil
  self:setState('title')
  return true
end

local function championToggle(self, index)
  local ed = self.state.deckEditor
  if not ed then return self:fail('action_unavailable') end
  local face = tonumber(index)
  if not face or not ed.pool[face] then return self:fail('invalid_arg') end
  if ed.selected[face] then
    ed.selected[face] = nil
  else
    if countSelected(ed.selected) >= (ed.max or Champion.SIZE) then
      ed.message = '最多 ' .. tostring(ed.max or Champion.SIZE) .. ' 张，请先取消一张'
      return self:fail('champion_full')
    end
    ed.selected[face] = true
  end
  refreshEditor(ed)
  return true
end

local function championClear(self)
  local ed = self.state.deckEditor
  if not ed then return self:fail('action_unavailable') end
  ed.selected = {}
  refreshEditor(ed)
  return true
end

local function championFilter(self, key)
  local ed = self.state.deckEditor
  if not ed then return self:fail('action_unavailable') end
  key = key or 'all'
  if key ~= 'all' then
    local ok = false
    for i = 1, #(ed.groups or {}) do
      if ed.groups[i].key == key then ok = true; break end
    end
    if not ok then return self:fail('invalid_arg') end
  end
  ed.filter = key
  return true
end

local function championSave(self)
  local st = self.state
  local ed = st.deckEditor
  if not ed then return self:fail('action_unavailable') end
  if not isUnlocked(self) then return self:fail('locked') end

  local chosen = ed.chosen or buildChosen(ed)
  local ok, n = Champion.validate(chosen)
  if not ok then
    ed.message = '需要恰好 ' .. tostring(Champion.SIZE) .. ' 张（当前 ' .. tostring(n) .. '）'
    return self:fail('champion_size')
  end
  -- 逐张校验：必须是牌池中的合法牌面，且字段不越出持久化白名单
  for i = 1, #chosen do
    local c = chosen[i]
    if type(c) ~= 'table' or (c.rank == nil and c.kind == nil) then return self:fail('invalid_arg') end
    for k in pairs(c) do
      local allowed = false
      for j = 1, #CARD_FIELDS do
        if CARD_FIELDS[j] == k then allowed = true; break end
      end
      if not allowed then return self:fail('invalid_arg') end
    end
  end

  if not (self.persist and self.persist.writeCollection) then return self:fail('save_failed') end
  local wrote = self.persist:writeCollection({
    version = 1, cards = chosen, savedAt = os.time and os.time() or 0, size = 'small',
  })
  if wrote == false then return self:fail('save_failed') end

  local stored = self.persist:readCollection()
  local storedCards = (type(stored) == 'table' and stored.cards) or {}
  st.championCards = storedCards
  ed.saved = stored
  ed.savedCards = storedCards
  ed.savedCount = #storedCards
  ed.loadedFromSave = true
  ed.preselected = ed.selectedCount
  ed.dirty = false
  ed.message = '已保存 ' .. tostring(#storedCards) .. ' 张'
  self:msg('冠军牌组已保存（' .. tostring(#storedCards) .. ' 张）。', 'success')
  return true
end

-- ===================== install =====================

function M.install(GS)
  if not GS then return false end
  if GS.__metaActionsV1 then return true end
  GS.__metaActionsV1 = true

  -- 教程运行器（替换核心的 st.tutorial 对象用法为 UI 投影）
  GS.start_tutorial = function(self) return startTutorial(self) end
  GS.tutorial_advance = function(self) return tutorialAdvance(self) end
  GS.tutorialNotify = function(self, name)
    -- 只记录诊断名；真正的门判定在方法/动作包装里，避免双推进
    local st = self.state
    if st then st.lastAction = name end
    return true
  end

  -- 方法级门包装：直接调用方法也能推进
  local function gateWrap(name, gate)
    local orig = GS[name]
    if type(orig) ~= 'function' then return end
    GS[name] = function(self, ...)
      local a, b = orig(self, ...)
      if a ~= false then metaObserve(self, gate) end
      return a, b
    end
  end
  gateWrap('bet_confirm', GATE_BY_METHOD.bet_confirm)
  gateWrap('finalizeRound', GATE_BY_METHOD.finalizeRound)
  gateWrap('pick_relic', GATE_BY_METHOD.pick_relic)
  gateWrap('use_relic', GATE_BY_METHOD.use_relic)
  gateWrap('toggle_relic', GATE_BY_METHOD.toggle_relic)

  -- 选遗物步骤的自然衔接点
  local origBeginBet = GS.beginBet
  GS.beginBet = function(self, ...)
    local a, b = origBeginBet(self, ...)
    if a ~= false then trySpawnTutorialRelic(self) end
    return a, b
  end

  -- 动作级门：核心对 open_deck/close_deck 走直通分支，不过 tutorialNotify
  local origAction = GS.action
  GS.action = function(self, name, arg)
    local eff = name
    if type(name) == 'string' and GS.ALIASES and GS.ALIASES[name] then eff = GS.ALIASES[name] end
    local a, b = origAction(self, name, arg)
    if a ~= false and eff and GATE_BY_ACTION[eff] then
      metaObserve(self, GATE_BY_ACTION[eff])
    end
    return a, b
  end

  -- 冠军牌组编辑器
  GS.open_deck_editor = function(self) return openDeckEditor(self) end
  GS.close_deck_editor = function(self) return closeDeckEditor(self) end
  GS.champion_toggle = function(self, index) return championToggle(self, index) end
  GS.champion_clear = function(self) return championClear(self) end
  GS.champion_filter = function(self, key) return championFilter(self, key) end
  GS.champion_save = function(self) return championSave(self) end

  GS.metaActions = M
  return true
end

return M
