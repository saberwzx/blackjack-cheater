-- ui/screens/bar.lua : 酒吧模式的所有界面
--   bar_brief  开场简报（两页）
--   bar_gift   酒保赠礼三选一
--   bar_pick   技能选择覆盖层（两步 / 勾选 / 冠军挑牌）
--   bar_ending 结局
-- 另外导出 tableOverlay(g, st)：牌桌上的"简报覆盖层"与宿醉全屏滤镜（纯显示）。
local Theme = require("ui.theme")
local Draw = require("ui.draw")
local Hot = require("ui.hot")
local W = require("ui.widgets")
local Cards = require("ui.cards")
local Motifs = require("ui.motifs")
local Fonts = require("ui.fonts")
local Audio = require("ui.audio")
local C = require("ui.screens.common")
local lg = love.graphics

local Bar = {}

Bar.briefPage = 1
Bar.briefOpen = false
Bar.pickScroll = 0
Bar._lastPending = nil
Bar._endedKey = nil

local function ui() return require("ui.ui") end

-- ===== helpers =====
local function colorOf(c)
  if type(c) == "table" then
    local r = c.r or c[1]
    local g = c.g or c[2]
    local b = c.b or c[3]
    if r then return { r, g or r, b or r } end
  end
  return { 0.85, 0.60, 0.30 }
end

local function glassKind(glass)
  if glass == "martini" or glass == "flute" or glass == "hurricane" or glass == "coupe" then return "martini" end
  if glass == "wine" or glass == "goblet" then return "wine" end
  return "rocks"
end

local function panelRect(w, h)
  local pw, ph = Theme.v(w), Theme.v(h)
  return Theme.vx((1280 - w) * 0.5), Theme.vy((720 - h) * 0.5), pw, ph
end

local function header(title, sub, y)
  Draw.textOutline(title, Theme.vx(640), y, Theme.px(30), Theme.colors.goldBright, { 0.10, 0.04, 0.02, 0.95 }, "center", Theme.v(900), Theme.v(1.6))
  if sub then
    Draw.text(sub, Theme.vx(640), y + Theme.px(34), Theme.px(13), Theme.colors.textDim, "center", Theme.v(900))
  end
end

-- ===== 简报 =====
local BRIEF_PAGES = {
  {
    title = "今晚的规矩",
    lines = {
      "不赌筹码，只赌酒量：桌上 6 杯酒，每杯 5 口。",
      "喝一口：该杯酒的技能解锁 5 局。重复喝只刷新时间，不会叠加。",
      "每一局你只能使用一次已解锁的技能（杯位右侧的「技」按钮）。",
      "出牌手段和普通模式一样：H 要牌 / S 停牌。加倍恒为灰色，没有指认、没有投降，也没有遗物与下注。",
      "输掉一局：酒保会强行请你喝一口（随机一杯）。",
      "空酒杯会离开桌面；六杯全空，今晚就结束了。",
    },
  },
  {
    title = "赠礼 · 宿醉 · 结局",
    lines = {
      "赠礼：基础 1% 概率，每赢一局 +0.5%；第 1 / 20 / 40 / 60 / 80 / 100 局必定赠礼，三选一，只给没见过的酒。",
      "宿醉：技能计时结束后的一局，画面会被过期的酒色浸染、牌面也会发花——那只是视觉效果，点数计算完全照常。",
      "共 100 局。结算时按剩余酒量决定结局：",
      "只剩最后一口 → 约会；六杯都还有余 → 变成鱼；其余仍有剩余 → 酒友；全部喝光 → 被请出去。",
      "酒吧不写入存档，也不影响主线进度。放心喝。",
    },
  },
}

local function drawBriefBody(cx, cy, cw, ch)
  local page = math.max(1, math.min(#BRIEF_PAGES, Bar.briefPage))
  local body = BRIEF_PAGES[page]
  Draw.text(body.title, cx + cw * 0.5, cy + Theme.v(6), Theme.px(18), Theme.colors.goldBright, "center", cw)
  local f = Fonts.get(Theme.px(14))
  local y = cy + Theme.v(44)
  for _, line in ipairs(body.lines) do
    for _, wrapped in ipairs(Fonts.wrap(line, f, cw - Theme.v(28))) do
      Draw.set({ 0.85, 0.68, 0.30, 0.85 })
      lg.circle("fill", cx + Theme.v(6), y + Theme.px(7), Theme.px(2.6), 10)
      Draw.text(wrapped, cx + Theme.v(18), y, Theme.px(14), Theme.colors.text, "left", cw - Theme.v(28))
      y = y + Theme.v(23)
    end
    y = y + Theme.v(6)
  end
  -- 页码指示
  local dots = #BRIEF_PAGES
  local dw = Theme.v(16)
  local dx0 = cx + cw * 0.5 - (dots - 1) * dw * 0.5
  for i = 1, dots do
    local on = (i == page)
    Draw.circleFill(dx0 + (i - 1) * dw, cy + ch - Theme.v(14), Theme.v(on and 4.5 or 3.2),
      on and Theme.colors.goldBright or Theme.colors.greyDim, on and 1 or 0.7)
  end
  local tabs = {}
  for i = 1, #BRIEF_PAGES do tabs[i] = { id = "p" .. i, label = "第 " .. i .. " 页" } end
  W.tabs("bar.briefpage", cx + cw * 0.5 - Theme.v(120), cy + ch - Theme.v(44), Theme.v(240), Theme.v(30), tabs, "p" .. page)
end

local function drawBrief(g, st)
  local b = st.bar or {}
  local x, y, w, h = panelRect(940, 500)
  Draw.panel(x, y, w, h, Theme.v(10), {
    bgTop = { 0.14, 0.066, 0.072, 1 }, bgBot = { 0.035, 0.020, 0.026, 1 },
    edge = Theme.colors.gold, edgeA = 0.75, lw = Theme.v(1.6), shadowA = 0.7,
  })
  Draw.ornateFrame(x, y, w, h, Theme.v(10), Theme.colors.goldDim, 0.85)
  header("酒 吧 模 式", "不赌筹码，只赌酒量 · 共 " .. tostring(b.totalRounds or 100) .. " 局", y + Theme.v(16))
  drawBriefBody(x + Theme.v(44), y + Theme.v(84), w - Theme.v(88), h - Theme.v(84) - Theme.v(70))
  W.button({ id = "bar.begin", x = x + w * 0.5 - Theme.v(130), y = y + h - Theme.v(54), w = Theme.v(260), h = Theme.v(44),
    label = "开始今晚", sub = "Enter", tone = "gold", size = 18, hotkey = "Enter", pulse = true,
    tip = "进入酒吧第一局。", tipTitle = "开始" })
end

-- ===== 赠礼 =====
local function drawGift(g, st)
  local b = st.bar or {}
  local opts = b.pendingGift or b.giftOptions or {}
  local n = math.max(1, #opts)
  header("第 " .. tostring(b.round or 1) .. " 局 · 酒保赠礼", "三选一 · 只给没见过的酒", Theme.vy(58))
  local cw, chh = Theme.v(300), Theme.v(360)
  local gap = Theme.v(30)
  local totalW = n * cw + (n - 1) * gap
  local x0 = Theme.vx(640) - totalW * 0.5
  local y0 = Theme.vy(160)
  for i = 1, n do
    local opt = opts[i] or {}
    local def = opt.def or opt
    local col = colorOf(def.color or opt.color)
    local x = x0 + (i - 1) * (cw + gap)
    local id = "bar.gift." .. i
    local hovered = Hot.isHover(id)
    Draw.set({ 0, 0, 0, 0.42 }); lg.rectangle("fill", x + Theme.v(3), y0 + Theme.v(4), cw, chh, Theme.v(8), Theme.v(8))
    Draw.gradientV(x, y0, cw, chh,
      { 0.13 + col[1] * 0.12, 0.07 + col[2] * 0.10, 0.07 + col[3] * 0.10 }, { 0.05, 0.030, 0.034 })
    if hovered then
      Draw.glow(x + cw * 0.5, y0 + chh * 0.5, cw * 0.72, { col[1], col[2], col[3], 0.24 }, 1, chh * 0.62)
    end
    Draw.frame(x, y0, cw, chh, Theme.v(8), hovered and Theme.colors.goldBright or col, 1)
    Motifs.glass(x + cw * 0.5, y0 + Theme.v(74), Theme.v(70), glassKind(def.glass), 1, col, Theme.time)
    Draw.text(tostring(opt.name or def.name or "?"), x + cw * 0.5, y0 + Theme.v(126), Theme.px(21),
      Theme.colors.goldPale, "center", cw - Theme.v(20))
    Draw.text(tostring(opt.en or def.en or ""), x + cw * 0.5, y0 + Theme.v(154), Theme.px(11),
      Theme.colors.textDim, "center", cw - Theme.v(20))
    local f = Fonts.get(Theme.px(13))
    local yy = y0 + Theme.v(186)
    local gift = opt.gift or def.gift or def.desc or ""
    for _, ln in ipairs(Fonts.wrap(tostring(gift), f, cw - Theme.v(36))) do
      Draw.text(ln, x + cw * 0.5, yy, Theme.px(13), Theme.colors.text, "center", cw - Theme.v(30))
      yy = yy + Theme.v(21)
    end
    W.button({ id = id, x = x + Theme.v(40), y = y0 + chh - Theme.v(56), w = cw - Theme.v(80), h = Theme.v(42),
      label = "选它", sub = tostring(i), tone = "gold", size = 16, hotkey = tostring(i),
      tip = "收下「" .. tostring(opt.name or "") .. "」。", tipTitle = "赠礼", data = { index = i } })
  end
end

-- ===== 技能选择覆盖层 =====
local PICK_SPEC = {
  swap_hand_card = { title = "换牌", step1 = "换牌 · 选择你的一张手牌", step2 = "换牌 · 选择换进来的牌" },
  swap_with_dealer = { title = "掉包", step1 = "掉包 · 选择你的一张手牌", step2 = "掉包 · 选择庄家的一张明牌" },
  peek_sink_pick = { title = "透牌 · 沉底", step1 = "透牌 · 勾选要沉底的牌" },
  pick_from_champion = { title = "错乱 · 挑牌", step1 = "错乱 · 从冠军牌组中挑一张" },
}

local function candLabel(cand)
  if not cand then return "?" end
  if cand.name and cand.label then return tostring(cand.name) .. " · " .. tostring(cand.label) end
  return tostring(cand.name or cand.label or cand.kind or cand.index or "?")
end

local function drawCandidate(cand, x, y, w, h, selected)
  if cand and cand.card then
    Cards.draw(cand.card, x, y, w, h, { selected = selected })
  else
    Cards.drawBack(x, y, w, h, 1)
    Draw.text(candLabel(cand), x + w * 0.5, y + h * 0.5 - Theme.px(7), Theme.px(10),
      Theme.colors.goldPale, "center", w - Theme.v(6))
  end
  if selected then
    local g = Theme.colors.goldBright
    Draw.set({ g[1], g[2], g[3], 1 }); lg.setLineWidth(Theme.v(2.2))
    lg.rectangle("line", x - Theme.v(3), y - Theme.v(3), w + Theme.v(6), h + Theme.v(6), Theme.v(4), Theme.v(4))
    lg.setLineWidth(1)
    Draw.circleFill(x + w - Theme.v(6), y + Theme.v(6), Theme.v(8), g, 1)
    Draw.text("选", x + w - Theme.v(6), y, Theme.px(10), { 0.12, 0.06, 0.02, 1 }, "center")
  end
end

local function pickHint(p)
  if p.interaction == "checklist" then
    local n = 0
    for _ in pairs(p.picks or {}) do n = n + 1 end
    return "已勾选 " .. n .. " 张（可多选），确认后生效。"
  elseif p.interaction == "pick_champion" then
    return "点击一张选中，然后确认。"
  elseif p.interaction == "two_step" then
    if p.step == 1 then return "先选择你的一张手牌。" end
    if p.special == "swap_with_dealer" then return "再选择庄家的一张明牌，然后确认。" end
    return "再选择换进来的那张牌，然后确认。"
  end
  return "选择后确认。"
end

function Bar.pickOverlay(g, st)
  local b = st.bar or {}
  local p = b.pending
  if not p then
    local cx, cy, cw, ch = C.modal("酒吧技能", { id = "bar.pick", w = 520, h = 220 })
    Draw.text("技能正在结算…", cx + cw * 0.5, cy + Theme.v(50), Theme.px(15), Theme.colors.text, "center", cw)
    W.button({ id = "bar.pick.cancel", x = cx + cw * 0.5 - Theme.v(80), y = cy + ch - Theme.v(56),
      w = Theme.v(160), h = Theme.v(42), label = "返回", sub = " ESC", tone = "dark", size = 15,
      tip = "回到牌桌。", tipTitle = "返回" })
    return
  end
  if Bar._lastPending ~= p then Bar._lastPending = p; Bar.pickScroll = 0 end

  local spec = PICK_SPEC[p.special] or { title = p.special or "技能" }
  local title = spec.step1 or spec.title or "技能"
  if p.interaction == "two_step" and p.step == 2 then title = spec.step2 or title end
  local list = p.candidates or {}
  local wide = #list > 40
  local mw, mh = (wide and 1160 or 900), (wide and 620 or 560)
  local cx, cy, cw, ch = C.modal(title, {
    id = "bar.pick", w = mw, h = mh,
    subtitle = (p.interaction == "two_step") and ("第 " .. tostring(p.step or 1) .. " 步 / 共 2 步") or pickHint(p),
  })

  local cardW, cardH = Theme.v(56), Theme.v(80)
  local gapX, gapY = Theme.v(14), Theme.v(16)
  local availW = cw - Theme.v(28)
  local cols = math.max(1, math.floor((availW + gapX) / (cardW + gapX)))
  local rows = math.ceil(math.max(1, #list) / cols)
  local contentH = rows * (cardH + gapY) + Theme.v(12)
  local viewY = cy + Theme.v(8)
  local viewH = ch - Theme.v(76)

  W.scrollArea("bar.pick.scroll", cx + Theme.v(14), viewY, availW, viewH, contentH,
    function() return Bar.pickScroll end, function(v) Bar.pickScroll = v end)
  local maxScroll = math.max(0, contentH - viewH)
  Bar.pickScroll = math.max(0, math.min(maxScroll, Bar.pickScroll))

  lg.setScissor(cx + Theme.v(14), viewY, availW, viewH)
  for i, cand in ipairs(list) do
    local col = (i - 1) % cols
    local row = math.floor((i - 1) / cols)
    local x = cx + Theme.v(14) + col * (cardW + gapX)
    local y = viewY - Bar.pickScroll + row * (cardH + gapY)
    local selected = (p.choice == i) or (p.handIndex == i) or ((type(p.picks) == "table") and p.picks[i])
    if y + cardH > viewY - Theme.v(2) and y < viewY + viewH + Theme.v(2) then
      drawCandidate(cand, x, y, cardW, cardH, selected)
      Hot.btn({ id = "bar.pick." .. i, x = x, y = y, w = cardW, h = cardH, kind = "card",
        tip = candLabel(cand) .. "\n点击选择。", tipTitle = "候选", data = { index = i } })
    end
  end
  lg.setScissor()

  if #list == 0 then
    Draw.text("没有可选目标。", cx + cw * 0.5, viewY + Theme.v(20), Theme.px(14), Theme.colors.textDim, "center", cw)
  end

  local canConfirm
  if p.interaction == "checklist" then
    canConfirm = (type(p.picks) == "table") and (next(p.picks) ~= nil)
  else
    canConfirm = p.choice ~= nil
  end
  W.button({ id = "bar.pick.cancel", x = cx + Theme.v(16), y = cy + ch - Theme.v(54), w = Theme.v(150), h = Theme.v(42),
    label = "返回", sub = "ESC", tone = "dark", size = 15,
    tip = "取消这次技能选择（不消耗本局技能）。", tipTitle = "返回" })
  W.button({ id = "bar.pick.confirm", x = cx + cw - Theme.v(166), y = cy + ch - Theme.v(54), w = Theme.v(150), h = Theme.v(42),
    label = "确认", sub = "Enter", tone = "gold", size = 16, enabled = canConfirm, pulse = canConfirm,
    tip = "确认并结算技能效果。", tipTitle = "确认" })
  Draw.text(pickHint(p), cx + cw * 0.5, cy + ch - Theme.v(44), Theme.px(11.5), Theme.colors.textDim, "center", cw - Theme.v(360))
end

-- ===== 结局 =====
local ENDINGS = {
  date = { title = "约 会", tone = "hot", text = "你只留下最后一口，恰好留给了对的人。" },
  fish = { title = "变 成 鱼", tone = "cyan", text = "六只杯子都还有剩——今夜你是条鱼。" },
  buddies = { title = "酒 友", tone = "goldBright", text = "喝到最后还有余量，酒保记住了你。" },
  fail = { title = "被 请 出 去 了", tone = "negative", text = "杯子全空，今晚到此为止。" },
}

local function drawEnding(g, st)
  local b = st.bar or {}
  local e = ENDINGS[b.ending] or ENDINGS.buddies
  local col = Theme.colors[e.tone] or Theme.colors.goldBright
  if Bar._endedKey ~= b.ending then
    Bar._endedKey = b.ending
    Audio.play(b.ending == "fail" and "lose" or "win")
    local u = ui()
    if u and u.particles then
      u.particles:emit(Theme.vx(640), Theme.vy(220), {
        count = b.ending == "fail" and 24 or 60, spread = Theme.v(360), angle = -math.pi / 2, arc = 0.7,
        speed = Theme.v(120), life = 1.4, size = Theme.v(3), color = col, kind = "spark", drag = 0.9,
      })
    end
  end
  local k = 1 + 0.02 * math.sin(Theme.time * 3)
  Draw.textOutline(e.title, Theme.vx(640), Theme.vy(120), Theme.px(40) * k, col,
    { 0.08, 0.03, 0.02, 0.95 }, "center", Theme.v(900), Theme.v(1.8))
  Draw.text(e.text, Theme.vx(640), Theme.vy(180), Theme.px(15), Theme.colors.text, "center", Theme.v(760))

  local rows = {
    { "剩余酒量", tostring(b.endingTotal or 0) .. " 口" },
    { "酒杯数", tostring(b.endingCups or b.cupCount or 0) .. " / 6" },
    { "酒局胜 / 负", tostring(b.wins or 0) .. " / " .. tostring(b.losses or 0) },
    { "使用技能", tostring(b.abilitiesUsed or 0) .. " 次" },
  }
  local x, y, w, h = panelRect(520, 240)
  Draw.panel(x, y, w, h, Theme.v(9), {
    bgTop = { 0.12, 0.06, 0.07, 0.94 }, bgBot = { 0.035, 0.020, 0.026, 0.94 },
    edge = Theme.colors.gold, edgeA = 0.6,
  })
  local cy = y + Theme.v(20)
  for _, r in ipairs(rows) do
    Draw.text(r[1], x + Theme.v(24), cy, Theme.px(13), Theme.colors.textDim, "left")
    Draw.text(r[2], x + w - Theme.v(24), cy, Theme.px(15), Theme.colors.goldPale, "right")
    cy = cy + Theme.v(30)
  end
  if b.endingLine and b.endingLine ~= "" then
    local f = Fonts.get(Theme.px(13))
    Draw.hline(x + Theme.v(18), cy, w - Theme.v(36), Theme.colors.goldDim, 0.5, 1)
    cy = cy + Theme.v(12)
    for _, ln in ipairs(Fonts.wrap(b.endingLine, f, w - Theme.v(48))) do
      Draw.text(ln, x + w * 0.5, cy, Theme.px(13), Theme.colors.text, "center", w - Theme.v(48))
      cy = cy + Theme.v(20)
    end
  end
  W.button({ id = "bar.end.continue", x = Theme.vx(640) - Theme.v(130), y = Theme.vy(580), w = Theme.v(260), h = Theme.v(46),
    label = "回到主菜单", tone = "gold", size = 17, hotkey = "Enter", pulse = true,
    tip = "结束今晚，回到标题界面。", tipTitle = "继续" })
end

-- ===== 主绘制 =====
function Bar.draw(g, st)
  if st.state == "bar_pick" then return Bar.pickOverlay(g, st) end
  C.bg(st, {})
  local s = st.state
  if s == "bar_gift" then drawGift(g, st)
  elseif s == "bar_ending" then drawEnding(g, st)
  else drawBrief(g, st) end
end

-- ===== 牌桌上的简报覆盖层 + 宿醉滤镜 =====
function Bar.toggleBrief()
  Bar.briefOpen = not Bar.briefOpen
  if Bar.briefOpen then Bar.briefPage = 1 end
end

function Bar.isBriefOpen() return Bar.briefOpen == true end

function Bar.setBriefPage(n)
  Bar.briefPage = math.max(1, math.min(#BRIEF_PAGES, tonumber(n) or 1))
end

function Bar.onBriefClick(id)
  if id == "bar.brief.close" then Bar.briefOpen = false; return true end
  local p = tostring(id):match("^bar%.briefpage%.p(%d)$")
  if p then Bar.setBriefPage(tonumber(p)); return true end
  return false
end

local function blockTableInput()
  for i = 1, #Hot.btns do
    local id = Hot.btns[i].id
    if id then Hot.block(tostring(id)) end
  end
  for id in pairs(Hot.scrolls) do Hot.scrollBlock(id) end
end

function Bar.tableOverlay(g, st)
  local b = st.bar
  if b and b.hangover then
    local c = colorOf(b.hangoverColor)
    Draw.set({ c[1], c[2], c[3], 0.20 })
    lg.rectangle("fill", 0, 0, Theme.W, Theme.H)
    Draw.set({ c[1] * 0.7, c[2] * 0.7, c[3] * 0.7, 0.08 })
    local off = (Theme.time * 40) % 90
    for i = 0, 30 do
      local sx = Theme.vx(-260 + i * 90 + off)
      lg.polygon("fill", sx, 0, sx + Theme.v(38), 0, sx - Theme.v(118), Theme.H, sx - Theme.v(156), Theme.H)
    end
  end
  if Bar.briefOpen then
    blockTableInput()
    local x, y, w, h = C.modal("酒吧简报", { id = "bar.brief", w = 940, h = 520, closeTip = "关闭简报（ESC）" })
    drawBriefBody(x + Theme.v(44), y + Theme.v(10), w - Theme.v(88), h - Theme.v(24))
  end
end

-- ===== 输入 =====
function Bar.onClick(g, st, hs)
  local id = tostring(hs.id or "")
  local s = st.state
  if Bar.onBriefClick(id) then return true end
  if s == "bar_gift" then
    local i = id:match("^bar%.gift%.(%d+)$")
    if i then g:action("bar_gift_pick", tonumber(i)); return true end
    return false
  elseif s == "bar_ending" then
    if id == "bar.end.continue" then g:action("continue"); return true end
    return false
  elseif s == "bar_pick" then
    if id == "bar.pick.cancel" then g:action("bar_pick", { cancel = true }); return true end
    if id == "bar.pick.confirm" then
      local p = st.bar and st.bar.pending
      if not p then return true end
      local ready
      if p.interaction == "checklist" then ready = type(p.picks) == "table" and next(p.picks) ~= nil
      else ready = p.choice ~= nil end
      if not ready then
        ui().notify("还没有选好：先点一个目标。", "warn")
        return true
      end
      g:action("bar_confirm")
      return true
    end
    local i = id:match("^bar%.pick%.(%d+)$")
    if i then g:action("bar_pick", { index = tonumber(i) }); return true end
    return false
  elseif s == "bar_brief" then
    if id == "bar.begin" then g:action("bar_begin"); return true end
    if id == "bar.briefpage.p1" or id == "bar.briefpage.p2" then return Bar.onBriefClick(id) end
    return false
  end
  return false
end

function Bar.onKey(g, st, key)
  local s = st.state
  if s == "bar_brief" then
    if key == "1" or key == "2" then Bar.setBriefPage(tonumber(key)); return true end
    if key == "left" then Bar.setBriefPage(Bar.briefPage - 1); return true end
    if key == "right" then Bar.setBriefPage(Bar.briefPage + 1); return true end
    if key == "return" or key == "kpenter" or key == "space" then g:action("bar_begin"); return true end
    return false
  elseif s == "bar_gift" then
    local opts = (st.bar and (st.bar.pendingGift or st.bar.giftOptions)) or {}
    local i = tonumber(key)
    if i and i >= 1 and i <= math.max(1, #opts) then g:action("bar_gift_pick", i); return true end
    return false
  elseif s == "bar_ending" then
    g:action("continue")
    return true
  elseif s == "bar_pick" then
    if key == "escape" then g:action("bar_pick", { cancel = true }); return true end
    if key == "return" or key == "kpenter" then
      local p = st.bar and st.bar.pending
      if p and p.choice ~= nil then g:action("bar_confirm") end
      return true
    end
    return true
  end
  return false
end

function Bar.onBackdrop(g, st, x, y)
  if st.state == "bar_pick" then
    g:action("bar_pick", { cancel = true })
    return true
  end
  if Bar.briefOpen then Bar.briefOpen = false; return true end
  return false
end

return Bar
