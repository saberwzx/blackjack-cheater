-- ui/screens/shop.lua : 商店（每 5 回合；5 个货架 + 重掷 + 锻造）
local Theme = require("ui.theme")
local lg = love.graphics
local Draw = require("ui.draw")
local Fonts = require("ui.fonts")
local W = require("ui.widgets")
local C = require("ui.screens.common")
local Motifs = require("ui.motifs")
local Cards = require("ui.cards")
local Hot = require("ui.hot")
local UI = require("ui.ui")

local S = {}

local RARITY_CN = { common = "普通", uncommon = "罕见", rare = "稀有", legendary = "传说", cursed = "诅咒" }
local SIZE_CN = { small = "小型", medium = "中型", large = "大型", x = "特殊" }

local function shelvesOf(sh)
  return (sh and sh.shelves) or {}
end

local function relicSlotsUsed(st)
  local n = 0
  for _, r in ipairs(st.relics or {}) do
    if not (r._sold) then n = n + 1 end
  end
  return n
end

function S.draw(g, st)
  local sh = st.shop or {}
  local cx, cy, cw, ch = C.modal("商 店", {
    w = 1220, h = 664, id = "shop",
    subtitle = "每 5 回合开张 · 重掷费用翻倍 · 每店最多锻造一次",
    closeAction = "leave_shop", closeTip = "离开商店（ESC）",
  })

  local chips = st.chips or 0
  Draw.text("筹码 " .. C.money(chips), cx + Theme.v(20), cy + Theme.v(8), Theme.px(18), Theme.colors.goldBright, "left")
  Draw.text(string.format("遗物 %d / %d", relicSlotsUsed(st), st.relicSlotMax or 5),
    cx + Theme.v(230), cy + Theme.v(12), Theme.px(13), Theme.colors.textDim, "left")
  local rc = sh.rerollCost or 200
  Draw.text(string.format("重掷费用 %s（已重掷 %d 次）", C.money(rc), sh.rerolls or 0),
    cx + cw - Theme.v(20), cy + Theme.v(12), Theme.px(13), Theme.colors.textDim, "right")

  local list = shelvesOf(sh)
  local n = math.max(1, #list)
  local gap = Theme.v(12)
  local iw = (cw - Theme.v(40) - (n - 1) * gap) / n
  local ih = ch - Theme.v(132)
  local x0 = cx + Theme.v(20)
  local y0 = cy + Theme.v(38)

  for i = 1, n do
    local s = list[i]
    local x = x0 + (i - 1) * (iw + gap)
    local hovered = Hot.isHover("shop.card." .. i)
    local sold = s and s.sold
    local afford = s and not sold and chips >= (s.price or 0)
    local rar = (s and s.rarity and Theme.rarityColor(s.rarity)) or Theme.colors.goldDim
    Draw.set({ 0, 0, 0, 0.5 })
    lg.rectangle("fill", x + Theme.v(3), y0 + Theme.v(4), iw, ih, Theme.v(8), Theme.v(8))
    Draw.panel(x, y0, iw, ih, Theme.v(8), {
      bgTop = { 0.13 + rar[1] * 0.09, 0.075 + rar[2] * 0.06, 0.075 + rar[3] * 0.06, 1 },
      bgBot = { 0.045, 0.028, 0.032, 1 },
      edge = sold and Theme.colors.greyDim or (hovered and Theme.colors.goldBright or rar),
      edgeA = sold and 0.5 or 0.9, lw = Theme.v(1.4),
    })
    -- 折扣角标（跟随货架位，不跟随物品）
    if sh.discountIndex == i and sh.discountFactor then
      local pct = math.floor((1 - sh.discountFactor) * 100 + 0.5)
      Draw.set(0.85, 0.15, 0.15, 0.92)
      lg.rectangle("fill", x + Theme.v(6), y0 + Theme.v(6), Theme.v(56), Theme.v(20), Theme.v(4), Theme.v(4))
      Draw.text(string.format("-%d%%", pct), x + Theme.v(34), y0 + Theme.v(8), Theme.px(12), Theme.colors.white, "center")
    end

    if s == nil then
      Draw.text("空空如也", x + iw * 0.5, y0 + ih * 0.5, Theme.px(15), Theme.colors.textDim, "center", iw)
    else
      local label = (s.kind == "deck") and "牌 组" or "遗 物"
      Draw.text(label, x + Theme.v(12), y0 + Theme.v(10), Theme.px(11), s.kind == "deck" and Theme.colors.blue or Theme.colors.gold, "left")
      if s.rarity then
        Draw.text(RARITY_CN[s.rarity] or s.rarity, x + iw - Theme.v(12), y0 + Theme.v(10), Theme.px(11), rar, "right")
      end
      if s.kind == "relic" then
        local icw, ich = Theme.v(86), Theme.v(64)
        Motifs.relicIcon(x + (iw - icw) * 0.5, y0 + Theme.v(30), icw, ich, s, { grey = sold })
      else
        Cards.drawBack(x + iw * 0.5 - Theme.v(22), y0 + Theme.v(28), Theme.v(44), Theme.v(62), Theme.v(4), sold and 0.4 or 1)
        Draw.text(SIZE_CN[s.size] or "", x + iw * 0.5, y0 + Theme.v(94), Theme.px(11), Theme.colors.textDim, "center", iw)
      end
      Draw.hline(x + Theme.v(14), y0 + Theme.v(100), iw - Theme.v(28), rar, 0.45, 1)
      Draw.textOutline(s.name or "?", x + iw * 0.5, y0 + Theme.v(108), Theme.px(16), Theme.colors.goldBright,
        { 0.10, 0.04, 0.02, 0.95 }, "center", iw - Theme.v(14), Theme.v(1.1))
      local font = Fonts.get(Theme.px(11.5))
      local lines = Fonts.wrap(s.desc or "", font, iw - Theme.v(22))
      local lh = Fonts.height(font, Theme.v(3.5))
      for k, ln in ipairs(lines) do
        if k > 10 then break end
        Draw.text(ln, x + iw * 0.5, y0 + Theme.v(136) + (k - 1) * lh, Theme.px(11.5), Theme.colors.text, "center", iw - Theme.v(20))
      end

      local py = y0 + ih - Theme.v(56)
      if sold then
        W.banner("已 售 出", x + Theme.v(12), py - Theme.v(6), iw - Theme.v(24), Theme.v(30), "dark")
      else
        W.priceTag(x + Theme.v(12), py - Theme.v(4), s.price or 0, afford, { size = 14 })
        W.button({
          id = "shop.buy." .. i, x = x + Theme.v(12), y = py + Theme.v(22), w = iw - Theme.v(24), h = Theme.v(34),
          label = (s.kind == "deck") and "购入牌组" or "购入遗物",
          tone = afford and "gold" or "dark", size = 14, hotkey = tostring(i),
          enabled = true,
          tip = afford and "购买该商品" or ("筹码不足，需要 " .. C.money(s.price or 0)),
          tipTitle = s.name, data = { slot = i, kind = s.kind },
        })
      end
      Hot.btn({ id = "shop.card." .. i, x = x, y = y0, w = iw, h = ih - Theme.v(70), kind = "shop",
        data = { slot = i, kind = s.kind }, tip = (s.desc or ""), tipTitle = s.name })
    end
  end

  -- 底部：重掷 / 锻造 / 离开
  local by = cy + ch - Theme.v(58)
  local canReroll = chips >= rc
  W.button({
    id = "shop.reroll", x = cx + Theme.v(20), y = by, w = Theme.v(214), h = Theme.v(44),
    label = "重掷货架", sub = C.money(rc) .. " · R", tone = canReroll and "blue" or "dark", size = 15,
    tip = "重新生成全部未售出货架；费用翻倍", tipTitle = "重掷",
  })
  local fo = sh.forgeOffer
  if fo and #fo > 0 and not sh.forgeUsed then
    W.button({
      id = "shop.forge", x = cx + Theme.v(246), y = by, w = Theme.v(214), h = Theme.v(44),
      label = "锻造台", sub = C.money(10000), tone = "purple", size = 15, hotkey = "F",
      tip = "将一件消耗品变为永久遗物（每店一次）", tipTitle = "锻造",
    })
  else
    W.button({
      id = "shop.forged", x = cx + Theme.v(246), y = by, w = Theme.v(214), h = Theme.v(44),
      label = sh.forgeUsed and "本店已锻造" or "本店无锻造台", tone = "dark", size = 14, enabled = false,
      tip = "锻造台每间商店最多使用一次", tipTitle = "锻造",
    })
  end
  Draw.text("提示：R 重掷 · 1-5 购买 · ESC 离开", cx + cw - Theme.v(20) - Theme.v(210), by + Theme.v(14), Theme.px(12),
    Theme.colors.textDim, "left")
  W.button({
    id = "shop.leave", x = cx + cw - Theme.v(196), y = by, w = Theme.v(176), h = Theme.v(44),
    label = "离开商店", tone = "gold", size = 16, hotkey = "Esc",
    tip = "进入下一小局", tipTitle = "离开",
  })

  -- 锻造候选面板
  if sh.forgeOpen then
    local pw, phh = Theme.v(560), Theme.v(320)
    local px = Theme.vx(640) - pw * 0.5
    local py = Theme.vy(360) - phh * 0.5
    Draw.set({ 0, 0, 0, 0.6 }); lg.rectangle("fill", 0, 0, Theme.W, Theme.H)
    Draw.panel(px, py, pw, phh, Theme.v(8), {
      bgTop = { 0.16, 0.08, 0.16, 1 }, bgBot = { 0.05, 0.03, 0.06, 1 },
      edge = Theme.colors.purple, edgeA = 0.9, lw = Theme.v(1.6), shadowA = 0.7,
    })
    Draw.text("选择要锻造的消耗品", px + pw * 0.5, py + Theme.v(12), Theme.px(17), Theme.colors.goldBright, "center", pw - Theme.v(20))
    local sel = sh.forgeSel
    for i = 1, math.min(#fo, 6) do
      local c = fo[i]
      local ry = py + Theme.v(48) + (i - 1) * Theme.v(38)
      local on = sel and ((sel.kind == c.kind) and (sel.id == c.id or sel.index == c.index))
      W.button({
        id = "shop.forge.sel." .. i, x = px + Theme.v(18), y = ry, w = pw - Theme.v(36), h = Theme.v(32),
        label = (c.kind == "mark" and "特殊标记 · " or "") .. (c.name or c.id or "?"),
        tone = on and "purple" or "dark", size = 14,
        data = { kind = c.kind, id = c.id, index = c.index },
        tip = "选择该项进行锻造", tipTitle = "锻造候选",
      })
    end
    W.button({
      id = "shop.forge.confirm", x = px + Theme.v(18), y = py + phh - Theme.v(48), w = Theme.v(240), h = Theme.v(36),
      label = "确认锻造 " .. C.money(10000), tone = "purple", size = 14,
      tip = "花费 10,000 筹码，永久化该消耗品", tipTitle = "确认锻造",
    })
    W.button({
      id = "shop.forge.cancel", x = px + pw - Theme.v(158), y = py + phh - Theme.v(48), w = Theme.v(140), h = Theme.v(36),
      label = "取消", tone = "dark", size = 14, hotkey = "Esc",
    })
  end
end

local function buy(g, st, slot)
  local s = shelvesOf(st.shop)[slot]
  if not s or s.sold then return true end
  local name = s.kind == "deck" and "buy_deck" or "buy_relic"
  local ok, err = g:action(name, slot)
  if ok == false or (ok == nil and err ~= nil) then
    local map = {
      not_enough_chips = "筹码不足。",
      relic_slots_full = "遗物栏已满（5 件）。",
      action_unavailable = "该商品当前不可购买。",
      invalid_arg = "该商品无效。",
    }
    UI.notify(map[err] or ("购买失败：" .. tostring(err)), "error")
  else
    UI.notify("已购入：" .. tostring(s.name or ""), "success")
  end
  return true
end

function S.onClick(g, st, hs)
  local id = hs.id
  if id == "shop.leave" then g:action("leave_shop"); return true end
  if id == "shop.reroll" then
    local ok, err = g:action("reroll")
    if ok == false or (ok == nil and err ~= nil) then UI.notify("重掷失败：" .. tostring(err), "error") end
    return true
  end
  if id == "shop.forge" then g:action("open_forge"); return true end
  if id == "shop.forge.confirm" then
    local ok, err = g:action("confirm_forge")
    if ok == false or (ok == nil and err ~= nil) then UI.notify("锻造失败：" .. tostring(err), "error") else UI.notify("锻造完成。", "success") end
    return true
  end
  if id == "shop.forge.cancel" then g:action("cancel_forge"); return true end
  local sel = id:match("^shop%.forge%.sel%.(%d)$")
  if sel then
    g:action("forge_select", { kind = hs.data.kind, id = hs.data.id, index = hs.data.index })
    return true
  end
  local slot = id:match("^shop%.buy%.(%d)$")
  if slot then return buy(g, st, tonumber(slot)) end
  local card = id:match("^shop%.card%.(%d)$")
  if card then return buy(g, st, tonumber(card)) end
  return false
end

function S.onKey(g, st, key)
  if key == "escape" then g:action("leave_shop"); return true end
  if key == "r" then
    local sh = st.shop or {}
    local ok, err = g:action("reroll")
    if ok == false or (ok == nil and err ~= nil) then UI.notify("重掷失败：" .. tostring(err), "error") end
    return true
  end
  if key == "f" then
    local sh = st.shop or {}
    if sh.forgeOffer and not sh.forgeUsed then g:action("open_forge") end
    return true
  end
  local i = tonumber(key)
  if i and i >= 1 and i <= 5 then return buy(g, st, i) end
  return false
end

function S.onWheel(g, st, dy) end

return S
