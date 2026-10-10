-- ui/screens/relicSelect.lua : 开局三选一（仅消耗品）
local Theme = require("ui.theme")
local lg = love.graphics
local Draw = require("ui.draw")
local Fonts = require("ui.fonts")
local W = require("ui.widgets")
local C = require("ui.screens.common")
local Motifs = require("ui.motifs")
local Hot = require("ui.hot")

local S = {}

local RARITY_CN = { common = "普通", uncommon = "罕见", rare = "稀有", legendary = "传说", cursed = "诅咒" }

local function itemOf(entry)
  if not entry then return nil end
  if entry.relic then return entry.relic end
  if entry.id or entry.name then return entry end
  return nil
end

function S.draw(g, st)
  C.bg(st)
  local top = C.topBar(st, {})
  Draw.text("遗 物 精 选", Theme.vx(640), Theme.vy(112), Theme.px(30), Theme.colors.goldBright, "center", Theme.v(600))
  Draw.text("三选一 · 仅含消耗品 · 本局生效", Theme.vx(640), Theme.vy(150), Theme.px(14), Theme.colors.textDim, "center", Theme.v(600))

  local list = (st.relicSelect and st.relicSelect.candidates) or {}
  local cw, chh = Theme.v(276), Theme.v(400)
  local gap = Theme.v(28)
  local n = math.max(1, #list)
  local totalW = n * cw + (n - 1) * gap
  local x0 = Theme.vx(640) - totalW * 0.5
  local y0 = Theme.vy(190)

  for i = 1, n do
    local r = itemOf(list[i]) or {}
    local x = x0 + (i - 1) * (cw + gap)
    local hovered = Hot.isHover("relsel.card." .. i) or Hot.isHover("relsel." .. i)
    local lift = hovered and Theme.v(8) or 0
    local y = y0 - lift
    local rar = Theme.rarityColor(r.rarity or "common")
    Draw.set({ 0, 0, 0, 0.5 })
    lg.rectangle("fill", x + Theme.v(4), y + Theme.v(6), cw, chh, Theme.v(9), Theme.v(9))
    Draw.panel(x, y, cw, chh, Theme.v(9), {
      bgTop = { 0.13 + rar[1] * 0.10, 0.075 + rar[2] * 0.07, 0.075 + rar[3] * 0.07, 1 },
      bgBot = { 0.045, 0.028, 0.032, 1 },
      edge = hovered and Theme.colors.goldBright or rar, edgeA = 0.9, lw = Theme.v(1.5),
    })
    if hovered then Draw.glow(x + cw * 0.5, y + Theme.v(80), cw * 0.55, { rar[1], rar[2], rar[3], 0.22 }, 1, Theme.v(90)) end

    Draw.text(RARITY_CN[r.rarity or "common"] or "普通", x + cw - Theme.v(12), y + Theme.v(10), Theme.px(11.5),
      rar, "right")

    local iw, ih = Theme.v(104), Theme.v(78)
    Motifs.relicIcon(x + (cw - iw) * 0.5, y + Theme.v(30), iw, ih, r, {})
    Draw.hline(x + Theme.v(24), y + Theme.v(122), cw - Theme.v(48), rar, 0.45, 1)

    Draw.textOutline(r.name or "?", x + cw * 0.5, y + Theme.v(132), Theme.px(19), Theme.colors.goldBright,
      { 0.10, 0.04, 0.02, 0.95 }, "center", cw - Theme.v(24), Theme.v(1.2))

    local font = Fonts.get(Theme.px(12.5))
    local lines = Fonts.wrap(r.desc or "", font, cw - Theme.v(34))
    local lh = Fonts.height(font, Theme.v(4))
    local ty = y + Theme.v(168)
    for k, ln in ipairs(lines) do
      if k > 9 then break end
      Draw.text(ln, x + cw * 0.5, ty + (k - 1) * lh, Theme.px(12.5), Theme.colors.text, "center", cw - Theme.v(30))
    end

    if r.group == "shard" then
      Draw.text("职阶碎片", x + cw * 0.5, y + chh - Theme.v(66), Theme.px(11), Theme.colors.purple, "center", cw)
    end
    W.button({
      id = "relsel." .. i, x = x + Theme.v(24), y = y + chh - Theme.v(56), w = cw - Theme.v(48), h = Theme.v(42),
      label = "选择", sub = "按 " .. i, tone = "gold", size = 16, hotkey = tostring(i),
      tip = (r.desc or "") .. (r._consumable and ("\n消耗品 · 剩余 " .. tostring(r._usesLeft or 0) .. " 次") or ""),
      tipTitle = r.name or "遗物", data = { index = i },
    })
    -- whole card is a hotspot aliasing the same pick
    Hot.btn({ id = "relsel.card." .. i, x = x, y = y, w = cw, h = chh - Theme.v(70), kind = "relic",
      data = { index = i }, tip = r.desc or "", tipTitle = r.name })
  end

  C.hints({ { "1-3", "选择遗物" }, { "Enter", "确认" } }, 646)
  return top
end

function S.onClick(g, st, hs)
  local id = hs.id
  local i = id:match("^relsel%.(%d)$") or id:match("^relsel%.card%.(%d)$")
  if i then
    local ok, err = g:action("pick_relic", tonumber(i))
    if ok == false or (ok == nil and err ~= nil) then
      require("ui.ui").notify("无法选择该遗物：" .. tostring(err or "不可用"), "error")
    end
    return true
  end
  return false
end

function S.onKey(g, st, key)
  local i = tonumber(key)
  local list = (st.relicSelect and st.relicSelect.candidates) or {}
  if i and i >= 1 and i <= #list then
    g:action("pick_relic", i)
    return true
  end
  return false
end

return S
