-- ui/hot.lua : single hotspot registry (immediate-mode). The UI writes rects at draw time;
-- the click/wheel handlers only read the SAME cached table -- never recompute coordinates.
local Hot = {}

Hot.btns = {}          -- array of hotspot tables, in draw order
Hot.frame = 0
Hot.mx, Hot.my = 0, 0
Hot.hover = nil        -- hotspot under the cursor this frame
Hot.tooltip = nil      -- {title, text, x, y, w}
Hot.drag = nil         -- {move=fn(mx,my), end=fn(), id=...}
Hot.scrolls = {}       -- id -> scroll region
Hot.blockList = {}     -- id prefixes made inert while a modal/overlay owns input
Hot.allowModal = {}    -- id prefixes always clickable regardless of blockList
Hot.scrollBlockList = {} -- scroll-region ids made inert under the same modal scope
Hot.registry = {}      -- id -> stable hotspot table (identity survives frames)

function Hot.begin()
  Hot.btns = {}
  Hot.scrolls = {}
  Hot.tooltip = nil
  -- Hot.hover intentionally survives: widgets compare it while drawing and it is
  -- recomputed by Hot.finish(); identity is stable thanks to Hot.registry.
  Hot.blockList = {}
  Hot.allowModal = {}
  Hot.scrollBlockList = {}
end

-- Make every hotspot whose id begins with prefix inert (modal exclusivity).
function Hot.block(prefix) Hot.blockList[#Hot.blockList + 1] = prefix end
-- Same scope rule for scroll regions: a region owned by a covered layer is inert.
function Hot.scrollBlock(id) Hot.scrollBlockList[#Hot.scrollBlockList + 1] = tostring(id) end
-- Keep a prefix clickable even while blocked (e.g. the topmost modal).
function Hot.allow(prefix) Hot.allowModal[#Hot.allowModal + 1] = prefix end
function Hot.blockedCount() return #Hot.blockList end

function Hot.finish()
  Hot.frame = Hot.frame + 1
  if Hot.frame % 180 == 0 then
    for id, tab in pairs(Hot.registry) do
      if not tab._frame or Hot.frame - tab._frame > 3 then Hot.registry[id] = nil end
    end
  end
  Hot.hover = Hot.hit(Hot.mx, Hot.my)
  if Hot.hover and Hot.hover.tip then
    Hot.tooltip = {
      text = type(Hot.hover.tip) == "table" and Hot.hover.tip.text or Hot.hover.tip,
      title = Hot.hover.tipTitle or (type(Hot.hover.tip) == "table" and Hot.hover.tip.title) or nil,
      x = Hot.hover.x, y = Hot.hover.y, w = Hot.hover.w, h = Hot.hover.h,
    }
  end
end

-- register a hotspot; returns the (possibly updated) table.
-- The table for a given id keeps its identity across frames so that
-- "Hot.hover == hs" comparisons made during draw remain meaningful.
function Hot.btn(t)
  t.enabled = (t.enabled ~= false)
  local id = tostring(t.id or "")
  local cur = Hot.registry[id]
  if cur then
    for k in pairs(cur) do if k ~= "_frame" and t[k] == nil then cur[k] = nil end end
    for k, v in pairs(t) do cur[k] = v end
    cur.enabled = t.enabled
    cur.id = t.id
    cur._frame = Hot.frame
    Hot.btns[#Hot.btns + 1] = cur
    return cur
  end
  t._frame = Hot.frame
  Hot.registry[id] = t
  Hot.btns[#Hot.btns + 1] = t
  return t
end

local function matches(id, prefix) return id:sub(1, #prefix) == prefix end

local function blocked(t)
  local id = tostring(t.id or "")
  if t.allowModal then return false end
  if #Hot.blockList == 0 then return false end
  for _, a in ipairs(Hot.allowModal) do if matches(id, a) then return false end end
  for _, b in ipairs(Hot.blockList) do if matches(id, b) then return true end end
  return false
end

function Hot.hit(x, y)
  local list = Hot.btns
  for i = #list, 1, -1 do
    local t = list[i]
    if t.w and t.w > 0 and t.enabled and not blocked(t) then
      if x >= t.x and x <= t.x + t.w and y >= t.y and y <= t.y + t.h then return t end
    end
  end
  return nil
end

-- Hit test including disabled ones (needed to swallow clicks on disabled buttons)
function Hot.isHover(id)
  return Hot.hover ~= nil and tostring(Hot.hover.id) == tostring(id)
end

function Hot.hitAny(x, y)
  local list = Hot.btns
  for i = #list, 1, -1 do
    local t = list[i]
    if t.w and t.w > 0 and not blocked(t) then
      if x >= t.x and x <= t.x + t.w and y >= t.y and y <= t.y + t.h then return t end
    end
  end
  return nil
end

-- Hot.btn with drag support: t.drag = { move=fn(mx,my), end=fn() }
function Hot.press(hs, mx, my)
  if not hs then return false end
  if hs.drag then
    Hot.drag = { id = hs.id, move = hs.drag.move, ["end"] = hs.drag["end"], data = hs.drag }
    if hs.drag.move then hs.drag.move(mx, my) end
    return true
  end
  return false
end

function Hot.dragMove(mx, my)
  if Hot.drag and Hot.drag.move then Hot.drag.move(mx, my) end
end

function Hot.dragEnd()
  local d = Hot.drag
  Hot.drag = nil
  if d and d["end"] then d["end"]() end
end

function Hot.scrollRegion(id, x, y, w, h, maxScroll, get, set, step)
  Hot.scrolls[id] = { id = id, x = x, y = y, w = w, h = h, max = maxScroll, get = get, set = set, step = step or 1 }
end

local function scrollInert(r)
  if #Hot.scrollBlockList == 0 then return false end
  local id = tostring(r.id or "")
  for _, b in ipairs(Hot.scrollBlockList) do
    if id == b or id:sub(1, #b) == b then return true end
  end
  return false
end

function Hot.scrollAt(mx, my)
  local best = nil
  for _, r in pairs(Hot.scrolls) do
    if r.max and r.max > 0 and not scrollInert(r)
      and mx >= r.x and mx <= r.x + r.w and my >= r.y and my <= r.y + r.h then
      best = r
    end
  end
  return best
end

function Hot.setTooltip(text, title, x, y, w, h)
  Hot.tooltip = { text = text, title = title, x = x, y = y, w = w, h = h }
end

return Hot
