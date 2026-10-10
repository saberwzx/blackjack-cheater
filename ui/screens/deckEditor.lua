-- ui/screens/deckEditor.lua : 冠军牌组编辑器（全屏）
-- 契约见 docs/meta-implementation.md §4：st.deckEditor.pool{group,groupName,card} 345，
-- selected 以全局序号 1..345 为键，champion_toggle 始终传全局序号（过滤不改序）。
local Theme = require("ui.theme")
local lg = love.graphics
local Draw = require("ui.draw")
local Fonts = require("ui.fonts")
local W = require("ui.widgets")
local C = require("ui.screens.common")
local Cards = require("ui.cards")
local Hot = require("ui.hot")
local UI = require("ui.ui")

local E = {}

local scroll = {}          -- 每个筛选各自的滚动量
local filterOpen = false
local tab = "all"

local GROUP_COLOR = {
  basic = { 0.86, 0.86, 0.90 },
  decimal = { 0.36, 0.80, 0.46 },
  negative = { 0.88, 0.34, 0.34 },
  multiplier = { 0.92, 0.76, 0.32 },
  s67 = { 0.66, 0.42, 0.92 },
  rps = { 0.42, 0.72, 0.94 },
  remove = { 0.62, 0.62, 0.66 },
  blackhole = { 0.30, 0.26, 0.44 },
  cage = { 0.58, 0.60, 0.66 },
  chip = { 0.86, 0.34, 0.40 },
  dice6 = { 0.94, 0.92, 0.82 },
  dice20 = { 0.42, 0.86, 0.72 },
  champion = { 0.92, 0.78, 0.36 },
}

local function groupColor(key)
  local c = GROUP_COLOR[key]
  if c then return { c[1], c[2], c[3], 1 } end
  return Theme.colors.gold
end

function E.draw(g, st)
  local ed = st.deckEditor
  C.bg(st, { noStars = false, noFlourish = false })
  if not ed then
    Draw.text("编辑器尚未就绪。", Theme.vx(640), Theme.vy(300), Theme.px(22), Theme.colors.text, "center")
    Hot.btn({ id = "ed.close", x = Theme.vx(540), y = Theme.vy(380), w = Theme.v(200), h = Theme.v(48), kind = "button" })
    Draw.panel(Theme.vx(540), Theme.vy(380), Theme.v(200), Theme.v(48), Theme.v(6), {})
    Draw.text("关闭（ESC）", Theme.vx(640), Theme.vy(388), Theme.px(16), Theme.colors.goldPale, "center")
    return
  end

  local pool = ed.pool or {}
  local groups = ed.groups or {}
  local max = ed.max or 36
  local selCount = ed.selectedCount or 0
  local filter = ed.filter or "all"
  if tab ~= filter then tab = filter; filterOpen = false end
  if scroll[filter] == nil then scroll[filter] = 0 end

  -- ===== 顶栏 =====
  Draw.gradientV(0, 0, Theme.vw2(), Theme.v(92), { 0.16, 0.06, 0.07, 0.98 }, { 0.06, 0.03, 0.04, 0.98 })
  Draw.hline(0, Theme.v(92), Theme.vw2(), Theme.colors.gold, 0.35)
  Draw.text("冠军牌组编辑器", Theme.v(16), Theme.v(12), Theme.px(28), Theme.colors.goldBright, "left")
  Draw.text("必须恰好 " .. max .. " 张方能保存上架 · 点牌面加入 / 再点移除 · 下拉筛选不影响全局序号",
    Theme.v(16), Theme.v(52), Theme.px(13), Theme.colors.textDim, "left")
  if not ed.unlocked then
    Draw.text("尚未解锁：通关困难模式后开放。", Theme.v(16), Theme.v(70), Theme.px(13), Theme.colors.orange, "left")
  end

  -- 已选进度
  Draw.text("已选", Theme.vw2() - Theme.v(420), Theme.v(16), Theme.px(14), Theme.colors.text, "left")
  Draw.text(selCount .. " / " .. max, Theme.vw2() - Theme.v(300), Theme.v(10), Theme.px(26),
    selCount == max and Theme.colors.green or Theme.colors.goldBright, "left")
  Draw.bar(Theme.vw2() - Theme.v(420), Theme.v(52), Theme.v(240), Theme.v(12), selCount / max, Theme.colors.gold, { 0.10, 0.06, 0.07, 0.9 }, Theme.v(6))
  if ed.loadedFromSave or ed.savedCards then
    Draw.text("存档已载入 " .. tostring(ed.savedCount or 0) .. " 张", Theme.vw2() - Theme.v(160), Theme.v(14), Theme.px(12),
      Theme.colors.textDim, "left")
  end
  if ed.dirty then
    Draw.text("有未保存修改", Theme.vw2() - Theme.v(160), Theme.v(34), Theme.px(12), Theme.colors.orange, "left")
  end
  if ed.message and ed.message ~= "" then
    Draw.text(ed.message, Theme.vw2() - Theme.v(160), Theme.v(56), Theme.px(12), Theme.colors.goldPale, "left", Theme.v(148))
  end

  -- ===== 筛选下拉 =====
  local fx, fy, fw, fh = Theme.v(16), Theme.v(100), Theme.v(240), Theme.v(32)
  local cur = "全部牌面（345）"
  if filter ~= "all" then
    for i = 1, #groups do
      if groups[i].key == filter then
        cur = groups[i].name .. "（" .. groups[i].count .. "）"
      end
    end
  end
  W.button({ id = "ed.filter", x = fx, y = fy, w = fw, h = fh, label = cur, tone = "dark", size = 14, hotkey = nil, tip = "按牌组筛选牌池" })
  Draw.text("▼", fx + fw - Theme.v(20), fy + Theme.v(9), Theme.px(12), Theme.colors.goldPale, "center")

  -- 状态一览（右上是保存 / 清空 / 关闭）
  local bw = Theme.v(120)
  W.button({ id = "ed.clear", x = Theme.vw2() - Theme.v(16) - bw * 3 - Theme.v(20), y = fy, w = bw, h = fh,
    label = "清空", tone = "red", size = 15, tip = "清空当前选择（可再次保存）", enabled = selCount > 0 })
  W.button({ id = "ed.save", x = Theme.vw2() - Theme.v(16) - bw * 2 - Theme.v(10), y = fy, w = bw, h = fh,
    label = "保存上架", tone = "green", size = 15,
    enabled = (selCount == max) and ed.unlocked ~= false,
    tip = selCount == max and "写入 saves21/collection.lua" or ("还需选择 " .. (max - selCount) .. " 张") })
  W.button({ id = "ed.close", x = Theme.vw2() - Theme.v(16) - bw, y = fy, w = bw, h = fh,
    label = "关闭", tone = "grey", size = 15, hotkey = "Esc", tip = "返回标题（ESC）" })

  -- ===== 牌池网格 =====
  local gx, gy, gw, gh = Theme.v(16), Theme.vy(144), Theme.v(880), Theme.vh2() - Theme.vy(160)
  local cols = 16
  local cw = gw / cols
  local chh = cw * 1.44
  local list = {}
  for i = 1, #pool do
    if filter == "all" or pool[i].group == filter then list[#list + 1] = i end
  end
  local rows = math.ceil(math.max(1, #list) / cols)
  local contentH = rows * (chh + Theme.v(8)) + Theme.v(8)
  local sc = scroll[filter]
  W.scrollArea("ed.scroll", gx, gy, gw, gh, contentH,
    function() return sc end, function(v) sc = v; scroll[filter] = v end)
  Draw.panel(gx - Theme.v(6), gy - Theme.v(6), gw + Theme.v(12), gh + Theme.v(12), Theme.v(8),
    { bgTop = { 0.07, 0.04, 0.05, 0.92 }, bgBot = { 0.04, 0.025, 0.03, 0.92 } })
  local drew = 0
  for k = 1, #list do
    local gi = list[k]
    local col = (k - 1) % cols
    local row = math.floor((k - 1) / cols)
    local x = gx + Theme.v(6) + col * cw
    local y = gy + row * (chh + Theme.v(8)) - sc
    if y + chh > gy - Theme.v(4) and y < gy + gh then
      drew = drew + 1
      local ent = pool[gi]
      local card = ent.card or ent
      local isSel = ed.selected and ed.selected[gi]
      local hovered = Hot.isHover("ed.face." .. gi)
      Cards.draw(card, x, y, cw - Theme.v(6), chh - Theme.v(6), {
        selected = isSel and true or false,
        dim = not isSel,
        dimA = 0.72,
      })
      if isSel then
        local w2, h2 = cw - Theme.v(6), chh - Theme.v(6)
        Draw.set(Theme.colors.green[1], Theme.colors.green[2], Theme.colors.green[3], 0.92)
        lg.setLineWidth(math.max(2, Theme.px(2.2)))
        lg.rectangle("line", x, y, w2, h2, Theme.v(3))
        lg.setLineWidth(1)
        Draw.set(1, 1, 1, 0.9)
        lg.circle("fill", x + w2 - Theme.v(9), y + Theme.v(9), Theme.v(7))
        Draw.text("✓", x + w2 - Theme.v(9), y + Theme.v(2), Theme.px(11), Theme.colors.bg0, "center")
      end
      Hot.btn({ id = "ed.face." .. gi, x = x, y = y, w = cw - Theme.v(6), h = chh - Theme.v(6), kind = "card",
        data = { index = gi },
        tip = (ent.groupName or ent.group or "") .. (isSel and "\n已选：点击移除" or "\n点击加入（全局 #" .. gi .. "）"),
        tipTitle = Cards.rankLabel and Cards.rankLabel(card) or "牌面" })
    end
  end
  Draw.text("共 " .. #list .. " 张候选 · 显示 " .. drew .. " 张 · 滚轮/↑↓/PgUp/PgDn 滚动",
    gx, gy + gh + Theme.v(2), Theme.px(11), Theme.colors.textDim, "left")

  -- ===== 右侧：已选 36 槽 =====
  local sx = Theme.vw2() - Theme.v(388)
  local sy = Theme.vy(144)
  local sw = Theme.v(372)
  local sh = Theme.vh2() - Theme.vy(160)
  Draw.panel(sx, sy, sw, sh, Theme.v(8), { bgTop = { 0.12, 0.06, 0.07, 0.95 }, bgBot = { 0.05, 0.03, 0.035, 0.95 } })
  Draw.text("已选牌组（按选择顺序）", sx + Theme.v(12), sy + Theme.v(8), Theme.px(15), Theme.colors.goldPale, "left")
  local cols2 = 6
  local slotW = (sw - Theme.v(24)) / cols2
  local slotH = slotW * 1.44
  local selFaces = ed.selectedFaces or {}
  for i = 1, max do
    local col = (i - 1) % cols2
    local row = math.floor((i - 1) / cols2)
    local x = sx + Theme.v(12) + col * slotW
    local y = sy + Theme.v(34) + row * (slotH + Theme.v(4))
    if y + slotH < sy + sh then
      local face = selFaces[i]
      if face then
        local card = pool[face] and (pool[face].card or pool[face])
        Cards.draw(card, x, y, slotW - Theme.v(4), slotH - Theme.v(4), {})
        Hot.btn({ id = "ed.slot." .. i, x = x, y = y, w = slotW - Theme.v(4), h = slotH - Theme.v(4), kind = "card",
          data = { index = face }, tip = "点击移除这张牌（全局 #" .. face .. "）", tipTitle = "第 " .. i .. " 张" })
      else
        Draw.set(0.35, 0.30, 0.24, 0.5)
        lg.rectangle("line", x, y, slotW - Theme.v(4), slotH - Theme.v(4), Theme.v(3))
        Draw.text(tostring(i), x + (slotW - Theme.v(4)) * 0.5, y + slotH * 0.5 - Theme.px(8), Theme.px(12),
          { 0.5, 0.44, 0.34, 0.7 }, "center", slotW - Theme.v(4))
      end
    end
  end

  -- ===== 筛选下拉浮层（最后绘制，独占网格点击） =====
  if filterOpen then
    local items = { { key = "all", name = "全部牌面", count = #pool } }
    for i = 1, #groups do items[#items + 1] = { key = groups[i].key, name = groups[i].name, count = groups[i].count } end
    local ih = Theme.v(28)
    local lh = #items * ih + Theme.v(8)
    local lx, ly = fx, fy + fh + Theme.v(4)
    if ly + lh > Theme.vh2() then ly = Theme.vh2() - lh - Theme.v(8) end
    Draw.panel(lx, ly, fw + Theme.v(120), lh, Theme.v(6), { bgTop = { 0.13, 0.08, 0.08, 0.99 }, bgBot = { 0.06, 0.04, 0.04, 0.99 } })
    for i = 1, #items do
      local it = items[i]
      local y = ly + Theme.v(4) + (i - 1) * ih
      local hovered = Hot.isHover("ed.fopt." .. it.key)
      if hovered then
        Draw.set(Theme.colors.gold[1], Theme.colors.gold[2], Theme.colors.gold[3], 0.16)
        lg.rectangle("fill", lx + Theme.v(4), y, fw + Theme.v(112), ih - Theme.v(2), Theme.v(4))
      end
      Draw.circleFill(lx + Theme.v(14), y + ih * 0.5 - Theme.v(1), Theme.v(5), groupColor(it.key))
      Draw.text(it.name .. "（" .. it.count .. "）", lx + Theme.v(26), y + Theme.v(4), Theme.px(14), Theme.colors.text, "left")
      Hot.btn({ id = "ed.fopt." .. it.key, x = lx + Theme.v(4), y = y, w = fw + Theme.v(112), h = ih - Theme.v(2), kind = "item", data = { key = it.key } })
    end
  end
end

local function save(g, ed)
  if (ed.selectedCount or 0) ~= (ed.max or 36) then
    UI.notify("必须恰好 " .. tostring(ed.max or 36) .. " 张才能保存（当前 " .. tostring(ed.selectedCount or 0) .. "）。", "warn")
    return
  end
  local ok, err = g:action("champion_save")
  if ok then
    UI.notify("冠军牌组已保存上架。", "success")
  else
    local CN = {
      champion_size = "张数不等于 36。",
      invalid_arg = "牌面字段非法。",
      save_failed = "存档写入失败（储存不可用）。",
      locked = "尚未解锁。",
      action_unavailable = "当前不能保存。",
    }
    UI.notify(CN[err] or ("保存失败：" .. tostring(err)), "error")
  end
end

function E.onClick(g, st, hs)
  local ed = st.deckEditor
  local id = hs.id
  if filterOpen and id:sub(1, 8) ~= "ed.fopt." then
    -- 下拉打开时，点击任意其它位置先收起
    if id ~= "ed.filter" then filterOpen = false end
  end
  local fopt = id:match("^ed%.fopt%.(.+)$")
  if fopt then
    filterOpen = false
    g:action("champion_filter", fopt)
    return true
  end
  if id == "ed.filter" then
    filterOpen = not filterOpen
    return true
  end
  if id == "ed.close" then g:action("close_deck_editor"); return true end
  if id == "ed.clear" then
    UI.confirm({ title = "清空牌组", text = "确定清空当前 36 张选择吗？清空后需重新选择才能保存。",
      yes = "清空", no = "取消", danger = true, onYes = function() g:action("champion_clear") end })
    return true
  end
  if id == "ed.save" then
    save(g, ed or {})
    return true
  end
  local face = id:match("^ed%.face%.(%d+)$") or id:match("^ed%.slot%.(%d+)$")
  if face then
    local ok, err = g:action("champion_toggle", tonumber(face))
    if not ok and err == "champion_full" then
      UI.notify("牌组已满 36 张，请先移除一张。", "warn")
    elseif not ok and err then
      UI.notify("无法选择该牌面：" .. tostring(err), "error")
    end
    return true
  end
  return false
end

function E.onKey(g, st, key)
  local ed = st.deckEditor or {}
  if key == "escape" then
    if filterOpen then filterOpen = false; return true end
    g:action("close_deck_editor"); return true
  end
  if key == "return" or key == "kpenter" then
    save(g, ed); return true
  end
  local tabk = st.deckEditor and st.deckEditor.filter or tab
  local cur = scroll[tabk] or 0
  local step = Theme.v(70)
  if key == "up" then scroll[tabk] = math.max(0, cur - step); return true end
  if key == "down" then scroll[tabk] = cur + step; return true end
  if key == "pageup" then scroll[tabk] = math.max(0, cur - step * 5); return true end
  if key == "pagedown" then scroll[tabk] = cur + step * 5; return true end
  if key == "home" then scroll[tabk] = 0; return true end
  return false
end

function E.onWheel(g, st, dy)
  local tabk = st.deckEditor and st.deckEditor.filter or tab
  local cur = scroll[tabk] or 0
  scroll[tabk] = math.max(0, cur - dy * Theme.v(48))
end

function E.onBackdrop(g, st, x, y) end

return E
