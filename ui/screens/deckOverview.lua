-- ui/screens/deckOverview.lua : 覆盖层 —— 牌堆总览
-- 只做纯展示：本靴构成（deckItems / removedDeckIds）与实际计数，
-- 不使用 DT.generate / roster（避免任何随机），也不展示牌靴顺序。
local Theme = require("ui.theme")
local Draw = require("ui.draw")
local Fonts = require("ui.fonts")
local W = require("ui.widgets")
local C = require("ui.screens.common")
local Hot = require("ui.hot")

local S = { scroll = 0 }

local SIZE_CN = { small = "小型", medium = "中型", large = "大型", x = "特殊" }

local DECK_DESC = {
  decimal = "小数牌：牌面为小数值，结算按牌面价值累计。",
  negative = "负整数牌：牌面为负值，会拉低手牌点数。",
  multiplier = "倍率牌：每张提供 +0.5 倍率加成。",
  s67 = "6 与 7 凑齐即触发 67 组合：必定不被爆、必赢并 ×67。",
  rps = "石头剪刀布牌：本身 0 点；双方各出一张时以石头剪刀布定胜负，平局算你赢。",
  remove = "删除牌组：从牌靴中移除 1/2/3 副标准牌（不会删到 0）。",
  blackhole = "黑洞牌：继承你上一张牌的牌面关键词。",
  cage = "牢笼牌：作为最后一张可见牌时封锁你的要牌。",
  chip = "筹码牌：胜利或和局时按点数 ×100 折算额外筹码。",
  dice6 = "六面骰子：按骰点结算（单次 $600 类效果）。",
  dice20 = "二十面骰子：按骰点结算（单次 $200 类效果）。",
  champion = "冠军牌组：使用你自己编辑并上架的 36 张牌。",
}

local function dtInfo(key)
  local ok, DT = pcall(require, "src.deck_types")
  if not ok or not DT or not DT.info then return nil, nil end
  return DT
end

local function deckName(key)
  local DT = dtInfo()
  if DT then
    local info = DT.info(key)
    if info and info.name then return info.name end
  end
  return tostring(key)
end

local function sizeCount(size)
  local DT = dtInfo()
  if DT and DT.sizeCount then return DT.sizeCount(size) end
  return ({ small = 6, medium = 12, large = 18 })[size] or 6
end

function S.draw(g, st)
  local cx, cy, cw, ch = C.modal("牌 堆 总 览", {
    w = 1060, h = 620, id = "deck",
    subtitle = "本靴构成与特殊牌组 · 仅显示数量与种类，不显示牌靴顺序",
    closeAction = "close_deck", closeTip = "关闭牌堆总览（D / ESC）",
  })

  local deck = st.deck or {}
  local dp = #(deck.drawPile or {})
  local disc = #(deck.discardPile or {})
  local removed = #(deck.removed or {})
  local stage = st.stage or 1

  -- 左栏：计数 + 构成
  local lw = Theme.v(470)
  local y = cy + Theme.v(6)
  C.sectionTitle("牌靴计数", cx + Theme.v(14), y, lw)
  y = y + Theme.v(28)
  local rows = {
    { "牌靴剩余", tostring(dp), Theme.colors.goldBright },
    { "弃牌堆", tostring(disc), Theme.colors.text },
    { "本靴移出", tostring(removed), Theme.colors.textDim },
    { "洗牌次数", tostring(deck.shuffleCount or 0), Theme.colors.text },
    { "合成牌", tostring(deck.syntheticCount or 0), Theme.colors.cyan },
  }
  for _, r in ipairs(rows) do
    Draw.text(r[1], cx + Theme.v(20), y, Theme.px(13), Theme.colors.textDim, "left")
    Draw.text(r[2], cx + lw, y, Theme.px(15), r[3], "right")
    y = y + Theme.v(24)
  end

  y = y + Theme.v(10)
  C.sectionTitle("本靴构成", cx + Theme.v(14), y, lw)
  y = y + Theme.v(28)
  local entries = {}
  entries[#entries + 1] = { "基础牌（" .. stage .. " 副）", 52 * stage, Theme.colors.text }
  for _, it in ipairs(st.deckItems or {}) do
    local n = (it.key == "champion" and st.championCards and #st.championCards or sizeCount(it.size))
    if it.key == "champion" then
      n = math.max(n, 0)
      if (it.size == "medium") then n = n * 2 elseif (it.size == "large") then n = n * 3 end
    end
    entries[#entries + 1] = { deckName(it.key) .. "（" .. (SIZE_CN[it.size] or tostring(it.size)) .. "）", n, Theme.colors.goldPale }
  end
  local removedCards = 0
  for _, it in ipairs(st.removedDeckIds or {}) do
    local okd, DT = pcall(require, "src.deck_types")
    local n = (okd and DT and DT.removedDecks) and DT.removedDecks(it.key, it.size) or 0
    removedCards = removedCards + (tonumber(n) or 0)
    entries[#entries + 1] = { "删除牌组（" .. (SIZE_CN[it.size] or "") .. "）", -n, Theme.colors.negative }
  end
  for _, r in ipairs(entries) do
    Draw.text(r[1], cx + Theme.v(20), y, Theme.px(13), Theme.colors.text, "left", lw - Theme.v(90))
    Draw.text((r[2] >= 0 and tostring(r[2]) or tostring(r[2])), cx + lw, y, Theme.px(14), r[3], "right")
    y = y + Theme.v(23)
  end
  if removedCards > 0 then
    y = y + Theme.v(6)
    Draw.text("删除牌组从标准牌中移除 " .. removedCards .. " 张后洗入牌靴。", cx + Theme.v(20), y, Theme.px(11.5),
      Theme.colors.negative, "left", lw - Theme.v(30))
    y = y + Theme.v(20)
  end

  -- 右栏：特殊牌组说明 + 标准桶
  local rx = cx + cw * 0.5 + Theme.v(14)
  local rw = cw * 0.5 - Theme.v(28)
  local ry = cy + Theme.v(6)
  C.sectionTitle("特殊牌组效果", rx, ry, rw)
  ry = ry + Theme.v(28)
  local font = Fonts.get(Theme.px(12))
  local lh = Fonts.height(font, Theme.v(3))
  local items = st.deckItems or {}
  if #items == 0 then
    Draw.text("本靴只有基础标准牌。", rx, ry, Theme.px(12.5), Theme.colors.textDim, "left", rw)
    ry = ry + Theme.v(24)
  end
  for _, it in ipairs(items) do
    Draw.text(deckName(it.key), rx, ry, Theme.px(14), Theme.colors.goldBright, "left", rw)
    ry = ry + Theme.v(20)
    local desc = DECK_DESC[it.key] or ""
    for _, ln in ipairs(Fonts.wrap(desc, font, rw)) do
      Draw.text(ln, rx, ry, Theme.px(12), Theme.colors.text, "left", rw)
      ry = ry + lh
    end
    ry = ry + Theme.v(8)
  end

  ry = ry + Theme.v(4)
  C.sectionTitle("标准桶分布（本靴）", rx, ry, rw)
  ry = ry + Theme.v(28)
  local comp = (st.shoe and st.shoe.composition) or {}
  local buckets = comp.buckets or {}
  local order = comp.order or { "A", "2", "3", "4", "5", "6", "7", "8", "9", "10" }
  local parts = {}
  for _, b in ipairs(order) do parts[#parts + 1] = b .. ":" .. tostring(buckets[b] or 0) end
  for _, ln in ipairs(Fonts.wrap(table.concat(parts, "  "), font, rw)) do
    Draw.text(ln, rx, ry, Theme.px(12.5), Theme.colors.text, "left", rw)
    ry = ry + lh
  end
  if (comp.unknown or 0) > 0 then
    Draw.text("非标准牌 " .. comp.unknown .. " 张未计入标准桶。", rx, ry, Theme.px(11.5), Theme.colors.orange, "left", rw)
    ry = ry + lh
  end
end

function S.onClick(g, st, hs)
  if hs.id == "deck.close" then g:action("close_deck"); return true end
  return false
end

function S.onKey(g, st, key)
  if key == "escape" or key == "d" then g:action("close_deck"); return true end
  return false
end

function S.onWheel(g, st, dy) end
function S.onBackdrop(g, st, x, y) end

return S
