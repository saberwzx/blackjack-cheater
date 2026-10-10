-- Portable save adapter. Source and packaged builds keep saves beside the game.
local P = {}
function P.new(root)
  if not root then
    if love.filesystem.isFused() then root = love.filesystem.getSourceBaseDirectory()
    else
      root = love.filesystem.getSource()
      if root:lower():match("%.love$") then root = love.filesystem.getSourceBaseDirectory() end
    end
  end
  root = root:gsub("\\", "/"):gsub("/$", "")
  local function path(name)
    assert(name == "saves21/progress.lua" or name == "saves21/collection.lua", "invalid save path")
    return root .. "/" .. name
  end
  return {
    root = root .. "/saves21",
    read = function(name)
      local f = io.open(path(name), "rb")
      if not f then return nil end
      local data = f:read("*a"); f:close(); return data
    end,
    write = function(name, data)
      local f, err = io.open(path(name), "wb")
      if not f then return false, err end
      local ok, detail = f:write(data)
      local closed, closeErr = f:close()
      if not ok or not closed then return false, detail or closeErr end
      return true
    end,
    getInfo = function(name)
      local f = io.open(path(name), "rb")
      if not f then return nil end
      local size = f:seek("end"); f:close(); return {type="file",size=size}
    end,
    remove = function(name) return os.remove(path(name)) end,
    createDirectory = function(name) return name == "saves21" end,
    mkdir = function(name) return name == "saves21" end,
  }
end
return P
