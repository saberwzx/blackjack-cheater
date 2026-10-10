-- ui/screens/shoeInfo.lua : 情报面板（覆盖层）—— 顺序带 / 成分 / 爆率 / 弃牌堆
local Theme = require("ui.theme")
local lg = love.graphics
local Draw = require("ui.draw")
local Fonts = require("ui.fonts")
local W = require("ui.widgets")
local C = require("ui.screens.common")
local Cards = require("ui.cards")
local Hot = require("ui.hot")

local S = {}

S.tab = "order"
S.scroll = { order = 0, composition = 0, odds = 0, discard = 0 }

local TABS = {
  { id = "order", label = "顺序带" },
  { id = "composition", label = "成分" },
  { id = "odds", label = "爆率" },
  { id = "discard", label = "弃牌堆" },
}

local REASON_CN = {
  unknown_cards = "待抽牌含不定值牌（骰子 / 石头剪刀布），无法精确枚举。",
  no_known_cards = "没有可枚举的已知值牌。",
  no_upcard = "缺少庄家明牌，无法计算。",
  unknown_upcard = "庄家明牌为不定值牌，无法估值。",
  no_standard_cards = "待抽牌靴没有可枚举的标准桶。",
  budget_exceeded = "枚举超预算，已放弃精确值。",
  depth_exceeded = "枚举超深度上限，已放弃精确值。",
  error = "计算失败。",
}

local function pct(v)
  if type(v) ~= "number" then return "--" end
  return string.format("%.1f%%", v * 100)
end

local function drawMiniCard(card, x, y, w, h, revealed, opt)
  opt = opt or {}
  if revealed and card then
    Cards.draw(card, x, y, w, h, { mark = opt.mark, markColor = opt.markColor, dim = opt.dim, hover = opt.hover })
  else
    Cards.drawBack(x, y, w, h, Theme.v(3), 1)
    Draw.text("?", x + w * 0.5, y + h * 0.5 - Theme.px(9), Theme.px(16), { 0.85, 0.75, 0.5, 0.5 }, "center", w)
  end
end

function S.draw(g, st)
  local shoe = st.shoe or {}
  local cx, cy, cw, ch = C.modal("情 报 面 板", {
    w = 1150, h = 646, id = "shoe",
    subtitle = st.rodMode and (st.rodMode == "swap" and (st.rodFirst and "换位钓具：请选择第二张已标记牌" or "换位钓具：依次点击两张已标记牌") or "钓具已启用：点击已标记牌执行移动") or "顺序带仅供参考：未揭示的牌以背面显示，绝不泄露牌靴顺序",
    closeAction = "close_shoe", closeTip = "关闭情报面板（I / ESC）",
  })

  local tab = st.shoeTab or S.tab
  if not S.scroll[tab] then S.scroll[tab] = 0 end

  -- 顶部统计
  Draw.text(string.format("牌堆剩余 %d · 弃牌 %d · 移出 %d", shoe.remaining or 0, shoe.discardCount or 0, shoe.removedCount or 0),
    cx + Theme.v(20), cy + Theme.v(10), Theme.px(13), Theme.colors.textDim, "left")
  local peek = st.peekDepth or 0
  Draw.text(peek > 0 and ("可预览深度 " .. peek) or "无预览深度", cx + cw - Theme.v(20), cy + Theme.v(10), Theme.px(13),
    peek > 0 and Theme.colors.cyan or Theme.colors.textDim, "right")

  W.tabs("shoe.tab", cx + Theme.v(20), cy + Theme.v(34), cw - Theme.v(40), Theme.v(34), TABS, tab)
  local bodyY = cy + Theme.v(80)
  local bodyH = ch - (bodyY - cy) - Theme.v(16)
  local bodyX, bodyW = cx + Theme.v(20), cw - Theme.v(40)

  if tab == "order" then
    local order = shoe.order or {}
    local mw, mh = Theme.v(Theme.metrics.miniCardW), Theme.v(Theme.metrics.miniCardH)
    local per = 15
    local gapx = Theme.v(4)
    local stepX = math.min(mw + gapx, (bodyW - Theme.v(10)) / per)
    local rows = math.ceil(math.max(1, #order) / per)
    local rowH = mh + Theme.v(30)
    local contentH = rows * rowH + Theme.v(30)
    local sc = S.scroll.order
    W.scrollArea("shoe.scroll.order", bodyX, bodyY, bodyW, bodyH, contentH,
      function() return sc end, function(v) sc = v; S.scroll.order = v end)

    for i = 1, #order do
      local it = order[i]
      local col = (i - 1) % per
      local row = math.floor((i - 1) / per)
      local x = bodyX + col * stepX
      local y = bodyY + row * rowH - sc + Theme.v(20)
      if y + mh > bodyY - Theme.v(6) and y < bodyY + bodyH then
        Draw.text(tostring(i), x + mw * 0.5, y - Theme.v(14), Theme.px(10.5),
          it.revealed and Theme.colors.goldPale or Theme.colors.textDim, "center", mw)
        local isHover = Hot.isHover("shoe.slot." .. i)
        drawMiniCard(it.card, x, y, mw, mh, it.revealed, {
          mark = it.marked, markColor = Theme.colors.cyan, hover = isHover,
        })
        Hot.btn({ id = "shoe.slot." .. i, x = x, y = y, w = mw, h = mh, kind = "card",
          data = { zone = "shoe", index = i, uid = it.card and it.card.uid },
          tip = (it.revealed and (it.label or "?") or "未揭示")
            .. (st.rodMode and "\n（钓具选择：只接受已标记牌）" or (it.marked and "\n（已标记：再次点击可移除标记）" or "\n（点击标记该牌）")),
          tipTitle = "第 " .. i .. " 张" })
      end
    end
    Draw.text(st.rodMode and "钓具模式 · 点击已标记牌操作；换位钓具须选择两张牌" or "自牌堆顶开始计数 · 仅前 30 张可见 · 点击可打墨水标记（需对应消耗品）",
      bodyX, bodyY + bodyH + Theme.v(2), Theme.px(11), Theme.colors.textDim, "left")
  elseif tab == "composition" then
    local comp = shoe.composition or {}
    local buckets = comp.buckets or {}
    local order = comp.order or { "A", "2", "3", "4", "5", "6", "7", "8", "9", "10" }
    local n = #order
    local bw = (bodyW - (n - 1) * Theme.v(8)) / n
    local bh = Theme.v(150)
    local total = 0
    for _, b in ipairs(order) do total = total + (buckets[b] or 0) end
    local maxv = 1
    for _, b in ipairs(order) do maxv = math.max(maxv, buckets[b] or 0) end
    for i, b in ipairs(order) do
      local x = bodyX + (i - 1) * (bw + Theme.v(8))
      local v = buckets[b] or 0
      Draw.panel(x, bodyY, bw, bh, Theme.v(6), { bgTop = { 0.13, 0.07, 0.07, 0.95 }, bgBot = { 0.05, 0.03, 0.035, 0.95 } })
      local frac = v / maxv
      local fh = math.max(Theme.v(3), (bh - Theme.v(48)) * frac)
      Draw.set(Theme.colors.gold[1], Theme.colors.gold[2], Theme.colors.gold[3], 0.85)
      lg.rectangle("fill", x + Theme.v(4), bodyY + bh - Theme.v(34) - fh, bw - Theme.v(8), fh, Theme.v(3), Theme.v(3))
      Draw.text(b, x + bw * 0.5, bodyY + Theme.v(8), Theme.px(17), Theme.colors.goldBright, "center", bw)
      Draw.text(tostring(v), x + bw * 0.5, bodyY + bh - Theme.v(26), Theme.px(16), Theme.colors.goldPale, "center", bw)
      if total > 0 then
        Draw.text(string.format("%.0f%%", v / total * 100), x + bw * 0.5, bodyY + bh - Theme.v(12), Theme.px(10),
          Theme.colors.textDim, "center", bw)
      end
    end
    local yy = bodyY + bh + Theme.v(16)
    Draw.text("成分统计将 J / Q / K 并入 10 点，A 单独计。总计 " .. tostring(total) .. " 张。",
      bodyX, yy, Theme.px(13), Theme.colors.text, "left")
    if (comp.unknown or 0) > 0 then
      Draw.text(string.format("非标准牌 %d 张未计入标准桶：%s", comp.unknown, comp.coverageGap or ""),
        bodyX, yy + Theme.v(22), Theme.px(12.5), Theme.colors.orange, "left", bodyW)
    end
  elseif tab == "odds" then
    local y = bodyY + Theme.v(6)
    local function oddsRow(label, value, info, desc)
      Draw.panel(bodyX, y, bodyW, Theme.v(96), Theme.v(7), { bgTop = { 0.13, 0.07, 0.07, 0.95 }, bgBot = { 0.05, 0.03, 0.035, 0.95 } })
      Draw.text(label, bodyX + Theme.v(18), y + Theme.v(14), Theme.px(16), Theme.colors.goldPale, "left")
      local known = type(value) == "number"
      Draw.text(known and pct(value) or "--", bodyX + bodyW - Theme.v(18), y + Theme.v(26), Theme.px(30),
        known and Theme.colors.goldBright or Theme.colors.grey, "right")
      Draw.text(known and desc or ((info and REASON_CN[info.reason]) or "未知（覆盖不足），显示 -- 而非 0。"),
        bodyX + Theme.v(18), y + Theme.v(52), Theme.px(12.5),
        known and Theme.colors.textDim or Theme.colors.orange, "left", bodyW - Theme.v(140))
      y = y + Theme.v(108)
    end
    oddsRow("下一张爆牌概率", shoe.nextBustOdds, shoe.nextBustOddsInfo,
      string.format("以你当前 %d 点、按真实规则无放回递归枚举。", st.player and st.player.total or 0))
    oddsRow("庄家爆牌概率", shoe.dealerBustOdds, shoe.dealerBustOddsInfo,
      "以庄家明牌与已知牌靴递归枚举（暗牌未知时按未知处理）。")
    if shoe.coverageGap and shoe.coverageGap ~= "" then
      Draw.text("覆盖说明：" .. shoe.coverageGap, bodyX, bodyY + Theme.v(238), Theme.px(12),
        Theme.colors.orange, "left", bodyW)
    end
    Draw.text("情报为纯计算，不消耗任何随机数，也不改变牌靴。", bodyX, bodyY + Theme.v(266), Theme.px(12),
      Theme.colors.textDim, "left", bodyW)
  else
    local disc = (st.deck and st.deck.discardPile) or {}
    local mw, mh = Theme.v(Theme.metrics.miniCardW), Theme.v(Theme.metrics.miniCardH)
    local per = 15
    local gapx = Theme.v(4)
    local stepX = math.min(mw + gapx, (bodyW - Theme.v(10)) / per)
    local rows = math.ceil(math.max(1, #disc) / per)
    local rowH = mh + Theme.v(20)
    local contentH = rows * rowH + Theme.v(20)
    local sc = S.scroll.discard
    W.scrollArea("shoe.scroll.discard", bodyX, bodyY, bodyW, bodyH, contentH,
      function() return sc end, function(v) sc = v; S.scroll.discard = v end)
    if #disc == 0 then
      Draw.text("弃牌堆为空。", bodyX + bodyW * 0.5, bodyY + Theme.v(40), Theme.px(15), Theme.colors.textDim, "center", bodyW)
    end
    for i = 1, #disc do
      local col = (i - 1) % per
      local row = math.floor((i - 1) / per)
      local x = bodyX + col * stepX
      local y = bodyY + row * rowH - sc + Theme.v(12)
      if y + mh > bodyY - Theme.v(6) and y < bodyY + bodyH then
        local isHover = Hot.isHover("shoe.disc." .. i)
        drawMiniCard(disc[i], x, y, mw, mh, true, { hover = isHover, mark = disc[i] and (disc[i].marked or nil) })
        Hot.btn({ id = "shoe.disc." .. i, x = x, y = y, w = mw, h = mh, kind = "card",
          data = { zone = "discard", index = i, uid = disc[i] and disc[i].uid },
          tip = "点击标记该弃牌（需对应消耗品）", tipTitle = "弃牌 " .. i })
      end
    end
    Draw.text("弃牌堆顺序为最近弃置在上。", bodyX, bodyY + bodyH + Theme.v(2), Theme.px(11), Theme.colors.textDim, "left")
  end
end

function S.onClick(g, st, hs)
  local id = hs.id
  local tab = id:match("^shoe%.tab%.(%a+)$")
  if tab then
    S.tab = tab
    g:action("shoe_tab", tab)
    return true
  end
  if id == "shoe.close" then
    g:action("close_shoe")
    return true
  end
  local slot = id:match("^shoe%.slot%.(%d+)$")
  if slot then
    g:action("mark_card", { zone = "shoe", index = tonumber(slot), uid = hs.data and hs.data.uid })
    return true
  end
  local disc = id:match("^shoe%.disc%.(%d+)$")
  if disc then
    g:action("mark_card", { zone = "discard", index = tonumber(disc), uid = hs.data and hs.data.uid })
    return true
  end
  return false
end

function S.onKey(g, st, key)
  if key == "escape" then g:action("close_shoe"); return true end
  if key == "i" then g:action("close_shoe"); return true end
  if key == "left" or key == "a" then g:action("shoe_tab", "order"); S.tab = "order"; return true end
  if key == "right" or key == "d" then g:action("close_shoe"); return true end
  return false
end

function S.onWheel(g, st, dy)
  local tab = st.shoeTab or S.tab
  local cur = S.scroll[tab] or 0
  S.scroll[tab] = math.max(0, cur - dy * Theme.v(26))
end

function S.onBackdrop(g, st, x, y) end

return S
