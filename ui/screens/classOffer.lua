-- ui/screens/classOffer.lua : 覆盖层 —— 职阶遗物：三选一 / 术士两段替换
-- 契约：st.classOffer = { mode, source, purpose, phase, candidates, targetCandidates }
--   phase == 'target' 时显示 targetCandidates（当前持有的遗物），再次调用 take_class_offer(i)
--   选择要被替换掉的那一件；source ∈ {caster, caster_shard, shard}；
--   purpose ∈ {caster_replace, caster_shard}。选择/跳过后由核心回到 result。
local Theme = require("ui.theme")
local Draw = require("ui.draw")
local Fonts = require("ui.fonts")
local W = require("ui.widgets")
local C = require("ui.screens.common")
local Motifs = require("ui.motifs")
local Hot = require("ui.hot")
local UI = require("ui.ui")

local S = {}

local RARITY_CN = { common = "普通", uncommon = "罕见", rare = "稀有", legendary = "传说", cursed = "诅咒" }

local function itemOf(entry)
  if not entry then return nil end
  if entry.relic then return entry.relic end
  if entry.def then return entry.def end
  if entry.id or entry.name then return entry end
  return nil
end

function S.draw(g, st)
  local co = st.classOffer or {}
  local isTarget = (co.phase == "target")
  local list = (isTarget and co.targetCandidates) or co.candidates or {}
  local source = co.source or (co.mode == "classOffer" and "shard") or nil

  local title, sub
  if isTarget then
    title = "选 择 替 换 目 标"
    sub = "已选好新遗物；现在点一件你现有的遗物，用新遗物替换它。点「放弃」可取消这次替换。"
  else
    title = "职 阶 遗 物"
    if source == "caster" then
      sub = "术士 · 三连胜奖励：选择一件新遗物，下一步再选被替换的现有遗物。"
    elseif source == "caster_shard" then
      sub = "术士碎片：选择一件新遗物，下一步再选被替换的现有遗物。"
    elseif source == "shard" then
      sub = "职阶碎片：选择一件遗物加入遗物栏。"
    else
      sub = "选择一件遗物。"
    end
  end

  local cx, cy, cw, ch = C.modal(title, {
    w = isTarget and 1040 or 900, h = 560, id = "co", subtitle = sub,
    closeAction = "skip_class_offer", closeTip = isTarget and "放弃本次替换" or "跳过本次机会",
  })

  local n = math.max(1, #list)
  local iw = math.min(Theme.v(isTarget and 208 or 248), (cw - Theme.v(60) - (n - 1) * Theme.v(18)) / n)
  local x0 = cx + (cw - (n * iw + (n - 1) * Theme.v(18))) * 0.5
  local y0 = cy + Theme.v(26)
  local ih = ch - Theme.v(120)

  for i = 1, n do
    local r = itemOf(list[i]) or {}
    local x = x0 + (i - 1) * (iw + Theme.v(18))
    local hovered = Hot.isHover("co.card." .. i)
    local rar = Theme.rarityColor(r.rarity or "common")
    Draw.panel(x, y0, iw, ih, Theme.v(8), {
      bgTop = { 0.13 + rar[1] * 0.10, 0.075 + rar[2] * 0.07, 0.075 + rar[3] * 0.07, 1 },
      bgBot = { 0.045, 0.028, 0.032, 1 },
      edge = hovered and Theme.colors.goldBright or rar, edgeA = 0.9, lw = Theme.v(1.4),
    })
    Draw.text(RARITY_CN[r.rarity or "common"] or "普通", x + iw - Theme.v(12), y0 + Theme.v(10), Theme.px(11.5), rar, "right")
    local icw, ich = Theme.v(90), Theme.v(68)
    Motifs.relicIcon(x + (iw - icw) * 0.5, y0 + Theme.v(26), icw, ich, r, {})
    Draw.hline(x + Theme.v(20), y0 + Theme.v(102), iw - Theme.v(40), rar, 0.45, 1)
    Draw.textOutline(r.name or "?", x + iw * 0.5, y0 + Theme.v(112), Theme.px(17), Theme.colors.goldBright,
      { 0.10, 0.04, 0.02, 0.95 }, "center", iw - Theme.v(18), Theme.v(1.1))
    local font = Fonts.get(Theme.px(12))
    local lines = Fonts.wrap(r.desc or "", font, iw - Theme.v(26))
    local lh = Fonts.height(font, Theme.v(4))
    for k, ln in ipairs(lines) do
      if k > 8 then break end
      Draw.text(ln, x + iw * 0.5, y0 + Theme.v(142) + (k - 1) * lh, Theme.px(12), Theme.colors.text, "center", iw - Theme.v(24))
    end
    W.button({
      id = "co.pick." .. i, x = x + Theme.v(18), y = y0 + ih - Theme.v(50), w = iw - Theme.v(36), h = Theme.v(38),
      label = isTarget and "替换它" or (source == "shard" and "获得" or "选择"), tone = isTarget and "red" or "gold",
      size = 15, hotkey = tostring(i),
      tip = isTarget and "用新遗物替换这件" or "选择该遗物", tipTitle = r.name or "遗物", data = { index = i },
    })
    Hot.btn({ id = "co.card." .. i, x = x, y = y0, w = iw, h = ih - Theme.v(58), kind = "relic",
      data = { index = i }, tip = r.desc or "", tipTitle = r.name })
  end

  W.button({
    id = "co.skip", x = cx + cw * 0.5 - Theme.v(90), y = cy + ch - Theme.v(56), w = Theme.v(180), h = Theme.v(38),
    label = isTarget and "放弃替换" or "跳过", tone = "dark", size = 15, hotkey = "Esc",
    tip = isTarget and "取消替换，保留现有遗物" or "放弃本次机会", tipTitle = "跳过",
  })
end

function S.onClick(g, st, hs)
  local id = hs.id
  if id == "co.skip" or id == "co.close" then
    g:action("skip_class_offer")
    return true
  end
  local i = id:match("^co%.pick%.(%d+)$") or id:match("^co%.card%.(%d+)$")
  if i then
    local ok, err = g:action("take_class_offer", tonumber(i))
    if ok == false or (ok == nil and err ~= nil) then
      UI.notify("无法选择：" .. tostring(err or "不可用"), "error")
    end
    return true
  end
  return false
end

function S.onKey(g, st, key)
  if key == "escape" then
    g:action("skip_class_offer")
    return true
  end
  local co = st.classOffer or {}
  local list = (co.phase == "target" and co.targetCandidates) or co.candidates or {}
  local i = tonumber(key)
  if i and i >= 1 and i <= #list then
    g:action("take_class_offer", i)
    return true
  end
  return false
end

function S.onBackdrop(g, st, x, y) end

return S
