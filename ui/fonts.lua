-- ui/fonts.lua : CJK font loading with Windows system-font fallback.
-- cjk-regular.otf is a static Regular face; cjk.ttf is a variable font that
-- FreeType can render as an ultra-thin weight, so it is only the second choice.
local Fonts = {}

local SOURCE_FONTS = {
  "assets/fonts/cjk-regular.otf",
  "assets/fonts/cjk.ttf",
}
local SYSTEM_FONTS = {
  "C:/Windows/Fonts/msyh.ttc",
  "C:/Windows/Fonts/msyh.ttf",
  "C:/Windows/Fonts/msyhbd.ttc",
  "C:/Windows/Fonts/simhei.ttf",
  "C:/Windows/Fonts/simsun.ttc",
  "C:/Windows/Fonts/Deng.ttf",
  "C:/Windows/Fonts/msjh.ttc",
}

local baseData = nil      -- FileData or false
local cache = {}
local variants = {}       -- key -> font (bold passed separately for future)
Fonts.kind = "none"

local function loadBaseData()
  if baseData ~= nil then return baseData or nil end
  -- 1. bundled CJK font
  for _, path in ipairs(SOURCE_FONTS) do
    local ok, info = pcall(love.filesystem.getInfo, path)
    if ok and info then
      local ok2, fd = pcall(love.filesystem.newFileData, path)
      if ok2 and fd then
        baseData = fd
        Fonts.kind = path
        return baseData
      end
    end
  end
  -- 2. Windows system fallback
  for _, p in ipairs(SYSTEM_FONTS) do
    local f = io.open(p, "rb")
    if f then
      local data = f:read("*a")
      f:close()
      if data and #data > 2048 then
        local ok2, fd = pcall(love.filesystem.newFileData, data, "sysfont.ttf")
        if ok2 and fd then
          baseData = fd
          Fonts.kind = "system:" .. p
          return baseData
        end
      end
    end
  end
  baseData = false
  Fonts.kind = "default"
  return nil
end
Fonts.loadBaseData = loadBaseData

function Fonts.get(size)
  size = math.max(8, math.floor((size or 14) + 0.5))
  local f = cache[size]
  if f then return f end
  local fd = loadBaseData()
  local ok, font
  if fd then
    ok, font = pcall(love.graphics.newFont, fd, size)
  end
  if not ok or not font then
    ok, font = pcall(love.graphics.newFont, size)
  end
  if not ok or not font then font = love.graphics.getFont() end
  pcall(function() font:setFilter("linear", "linear") end)
  cache[size] = font
  return font
end

function Fonts.wrap(text, font, width)
  text = tostring(text or "")
  local out = {}
  for para in (text .. "\n"):gmatch("([^\n]*)\n") do
    if font:getWidth(para) <= width then
      out[#out + 1] = para
    else
      local line = ""
      local i = 1
      local n = #para
      while i <= n do
        local b = para:byte(i)
        local len = 1
        if b >= 240 then len = 4
        elseif b >= 224 then len = 3
        elseif b >= 192 then len = 2 end
        local ch = para:sub(i, i + len - 1)
        if font:getWidth(line .. ch) > width and #line > 0 then
          out[#out + 1] = line
          line = ch
        else
          line = line .. ch
        end
        i = i + len
      end
      out[#out + 1] = line
    end
  end
  return out
end

function Fonts.height(font, extra)
  return font:getHeight() * (extra or 1) + font:getHeight() * 0.28
end

return Fonts
