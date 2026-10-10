-- ui/screens/settings.lua : 设置页（ESC 打开；通过 UI.settingsOpen 绘制，独占输入）
local Theme = require("ui.theme")
local Draw = require("ui.draw")
local W = require("ui.widgets")
local C = require("ui.screens.common")
local UI = require("ui.ui")

local S = {}

local RES = {
  { label = "800x600",   value = "800x600" },
  { label = "1280x720",  value = "1280x720" },
  { label = "1600x900",  value = "1600x900" },
  { label = "1920x1080", value = "1920x1080" },
}

local function settings(st)
  return st.settings or {}
end

function S.draw(g, st)
  local cfg = settings(st)
  local cx, cy, cw, ch = C.modal("设置", {
    w = 920, h = 600, id = "set",
    subtitle = "黑杰克 · 千王之路  v1.0",
    closeAction = "close_top", closeTip = "关闭设置（ESC）",
  })

  local lx = cx + Theme.v(46)
  local rx = cx + Theme.v(230)
  local y = cy + Theme.v(34)
  local rowH = Theme.v(66)

  -- 音量
  Draw.text("音量", lx, y + Theme.v(6), Theme.px(16), Theme.colors.goldPale, "left")
  Draw.text("全局音效与音乐音量", lx, y + Theme.v(26), Theme.px(11), Theme.colors.textDim, "left")
  local vol = cfg.volume or 0.6
  W.slider({
    id = "set.volume", x = rx, y = y + Theme.v(4), w = Theme.v(430), h = Theme.v(24),
    min = 0, max = 1, step = 0.05, value = vol,
    fmt = function(v) return string.format("%d%%", math.floor(v * 100 + 0.5)) end,
    onChange = function(v) if g and g.action then g:action("set_setting", { key = "volume", value = v }) end end,
    tip = "拖动调整全局音量（0% - 100%）", tipTitle = "音量",
  })
  y = y + rowH

  -- 分辨率
  Draw.text("分辨率", lx, y + Theme.v(6), Theme.px(16), Theme.colors.goldPale, "left")
  Draw.text("窗口尺寸；全屏时使用该分辨率", lx, y + Theme.v(26), Theme.px(11), Theme.colors.textDim, "left")
  local cur = tostring(cfg.resolution or "1280x720")
  local bw, bh = Theme.v(118), Theme.v(36)
  for i, r in ipairs(RES) do
    local on = (cur == r.value)
    W.button({
      id = "set.res." .. tostring(i), x = rx + (i - 1) * (bw + Theme.v(8)), y = y, w = bw, h = bh,
      label = r.label, tone = on and "gold" or "dark", size = 14,
      data = { res = r.value },
      tip = on and "当前分辨率" or ("切换到 " .. r.label), tipTitle = "分辨率",
    })
  end
  y = y + rowH

  -- 全屏
  Draw.text("全屏", lx, y + Theme.v(6), Theme.px(16), Theme.colors.goldPale, "left")
  Draw.text("以全屏模式运行", lx, y + Theme.v(26), Theme.px(11), Theme.colors.textDim, "left")
  W.toggle({
    id = "set.fullscreen", x = rx, y = y + Theme.v(4), w = Theme.v(96), h = Theme.v(30),
    value = cfg.fullscreen == true, color = Theme.colors.blue, label = cfg.fullscreen and "开" or "关",
    tip = "切换全屏（Alt+Enter 亦可）", tipTitle = "全屏",
  })
  y = y + rowH

  -- 筹码耗尽自动结束
  Draw.text("筹码耗尽自动结束", lx, y + Theme.v(6), Theme.px(16), Theme.colors.goldPale, "left")
  Draw.text("关闭后进入信贷模式：破产不立即结束本局", lx, y + Theme.v(26), Theme.px(11), Theme.colors.textDim, "left")
  W.toggle({
    id = "set.autoend", x = rx, y = y + Theme.v(4), w = Theme.v(96), h = Theme.v(30),
    value = cfg.autoEndOnBroke ~= false, color = Theme.colors.gold, label = (cfg.autoEndOnBroke ~= false) and "开" or "关",
    tip = "筹码归零时是否自动结束本周目", tipTitle = "筹码耗尽自动结束",
  })
  y = y + Theme.v(76)

  -- 重置存档
  Draw.hline(lx, y, cw - Theme.v(92), Theme.colors.goldDim, 0.5, 1)
  y = y + Theme.v(16)
  Draw.text("存档", lx, y + Theme.v(6), Theme.px(16), Theme.colors.goldPale, "left")
  Draw.text("删除 saves21/ 下的进度与冠军牌组", lx, y + Theme.v(26), Theme.px(11), Theme.colors.textDim, "left")
  W.button({
    id = "set.reset", x = rx, y = y, w = Theme.v(180), h = Theme.v(38),
    label = "重置存档", tone = "red", size = 15,
    tip = "清空通关记录与冠军牌组，不可撤销", tipTitle = "重置存档",
  })
  local ph = st.progress or {}
  Draw.text(string.format("通关困难 %d 次 · 最高阶段 %d · 最高筹码 %s",
    ph.hardClearCount or 0, ph.maxStage or 0, C.money(ph.maxChips or 0)),
    rx + Theme.v(196), y + Theme.v(12), Theme.px(12), Theme.colors.textDim, "left")

  -- 底部说明
  Draw.text("存档目录：游戏目录内 saves21/（便携模式，不写入系统用户目录）",
    cx + cw * 0.5, cy + ch - Theme.v(34), Theme.px(11), Theme.colors.textDim, "center", cw - Theme.v(80))
  W.button({
    id = "set.close", x = cx + cw * 0.5 - Theme.v(80), y = cy + ch - Theme.v(70), w = Theme.v(160), h = Theme.v(40),
    label = "返回游戏", tone = "dark", size = 15, hotkey = "Esc",
    tip = "关闭设置", tipTitle = "关闭",
  })
end

function S.onClick(g, st, hs)
  local id = hs.id
  if id == "set.close" then
    UI.settingsOpen = false
    return true
  end
  if id == "set.reset" then
    UI.confirm({
      title = "重置存档", danger = true,
      text = "将删除通关记录、最高筹码与冠军牌组，且无法撤销。确定继续吗？",
      yesLabel = "重置", noLabel = "取消",
      onYes = function()
        if g.action then g:action("reset_progress") end
        UI.notify("存档已重置。", "success")
      end,
    })
    return true
  end
  local n = id:match("^set%.res%.(%d)$")
  if n then
    local r = RES[tonumber(n)]
    if r and g.action then g:action("set_setting", { key = "resolution", value = r.value }) end
    return true
  end
  if id == "set.fullscreen" then
    if g.action then g:action("toggle_setting", "fullscreen") end
    return true
  end
  if id == "set.autoend" then
    if g.action then g:action("toggle_setting", "autoEndOnBroke") end
    return true
  end
  return false
end

function S.onKey(g, st, key)
  -- 设置页独占：ESC 由 UI.keypressed 提前处理，这里只接快捷切换
  if key == "f" then if g.action then g:action("toggle_setting", "fullscreen") end; return true end
  return false
end

function S.onWheel(dy) end

return S
