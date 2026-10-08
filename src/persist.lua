-- ============================================================
-- persist.lua — 存档模块（玩家游玩记录 + 收集情况）
--
-- 职责:
--   1. 定义存档目录（LÖVE save dir 下的独立子目录 saves21/）与两个存档文件
--   2. 纯 Lua 表序列化 / 反序列化（不引入任何第三方依赖）
--   3. 提供「删除 / 重置存档」入口
--   4. 提供 存档数据 <-> state 的双向映射
--
-- 依赖: love.filesystem（读盘/写盘/删文件）、love.window（应用分辨率与全屏）
-- 调用方:
--   main.lua      —— 启动时加载、模式选择开始新局时累计局数、点击分发
--   game_state.lua—— 通关写记录、破产/淘汰时记录最高到达阶段与最高筹码
--   ui/ui.lua     —— 设置项变更时写盘、设置页「重置存档」按钮
--
-- 文件划分（刻意分成两个文件，便于只重置进度而保留收集）:
--   saves21/progress.lua   游玩记录（易失：通关标记/最高记录/累计局数/设置）
--   saves21/collection.lua 收集情况（长期：冠军牌组 36 张）
--
-- 公共 API:
--   Persist.DIR / PROGRESS_PATH / COLLECTION_PATH  路径常量
--   Persist.defaultProgress()      默认游玩记录
--   Persist.init()                 读盘（文件不存在/损坏 → nil，绝不崩）
--   Persist.applyToState(state)    把存档合并进 state（含设置项）
--   Persist.saveProgress(state)    写游玩记录
--   Persist.saveCollection(state)  写冠军牌组
--   Persist.startRun(state)        累计游玩局数 +1 并写盘
--   Persist.recordRunStats(state)  刷新最高到达阶段/历史最高筹码并写盘
--   Persist.recordVictory(state)   记录通关（hard 口径）并写盘
--   Persist.reset(state)           删除整个存档目录并让 state 回默认值
--   Persist.getDir()               实际存档目录绝对路径（诊断/打印用）
--   Persist.dirExists()            存档目录是否存在
--
-- 禁止事项:
--   - 绝不在 love.update 里每帧写盘：只由事件驱动调用
--   - 绝不写游戏目录内的任何资源文件（只写 save dir 内的 saves21/）
--   - 不写 emoji 或 U+1F000 以上字符（字体不支持，会乱码）
--
-- 已踩过的坑:
--   - 存档目录在打包发布后可能不可写：读盘/写盘失败必须静默降级，不能报错退出游戏
--   - 单个文件损坏不能让另一个文件的数据一起丢：两个文件各自独立 pcall 解析
-- ============================================================

local Persist = {}

Persist.DIR             = "saves21"
Persist.PROGRESS_PATH   = "saves21/progress.lua"
Persist.COLLECTION_PATH = "saves21/collection.lua"

Persist.CHAMPION_SIZE = 36   -- 冠军牌组容量（与 champion.lua 一致，仅用于校验读盘结果）

-- ============================================================
-- 默认值
-- ============================================================
function Persist.defaultProgress()
    return {
        hardCleared    = false,  -- 是否通关过「困难模式」
        hardClearCount = 0,      -- 困难模式通关次数
        maxStage       = 1,      -- 历史最高到达阶段
        maxChips       = 0,      -- 历史最高筹码
        totalRuns      = 0,      -- 累计游玩局数
        bestRoundsBasic = 0,     -- 基础模式最快通关小局数（0 = 未通关，刷榜口径）
        bestRoundsHard  = 0,     -- 困难模式最快通关小局数（0 = 未通关）
        settings = {
            volume          = 0.6,
            resolutionIndex = 1,
            fullscreen      = false,
            autoEndOnBroke  = true,
        },
    }
end

local function defaultSettings()
    return Persist.defaultProgress().settings
end

-- ============================================================
-- 纯 Lua 表序列化（数字键升序 + 字符串键排序，保证同一份数据输出稳定）
-- ============================================================
local function serValue(v)
    local tv = type(v)
    if tv == "number" then
        if v ~= v then return "0" end                  -- NaN 兜底
        if v == math.huge then return "1e308" end
        if v == -math.huge then return "-1e308" end
        return string.format("%.14g", v)
    elseif tv == "string" then
        return string.format("%q", v)
    elseif tv == "boolean" then
        return tostring(v)
    elseif tv == "table" then
        local numKeys, strKeys = {}, {}
        for k in pairs(v) do
            if type(k) == "number" then table.insert(numKeys, k)
            elseif type(k) == "string" then table.insert(strKeys, k) end
        end
        table.sort(numKeys)
        table.sort(strKeys)
        local parts = {}
        for _, k in ipairs(numKeys) do
            parts[#parts + 1] = "[" .. string.format("%d", k) .. "]=" .. serValue(v[k])
        end
        for _, k in ipairs(strKeys) do
            parts[#parts + 1] = "[" .. string.format("%q", k) .. "]=" .. serValue(v[k])
        end
        return "{" .. table.concat(parts, ",") .. "}"
    end
    return "nil"
end

local function serialize(tbl)
    return "-- 自动生成的存档文件，请勿手改\nreturn " .. serValue(tbl) .. "\n"
end

-- 反序列化：解析失败一律返回 nil（调用方走默认值）
local function deserialize(str)
    if not str or str == "" then return nil end
    local chunk = loadstring(str)
    if not chunk then return nil end
    if setfenv then setfenv(chunk, {}) end   -- 沙箱：不给存档代码任何全局环境
    local ok, tbl = pcall(chunk)
    if not ok or type(tbl) ~= "table" then return nil end
    return tbl
end

-- ============================================================
-- 文件读写
-- ============================================================
local function readTable(path)
    local ok, contents = pcall(love.filesystem.read, path)
    if not ok or not contents then return nil end
    return deserialize(contents)
end

local function writeTable(path, tbl)
    -- createDirectory 递归创建；write 失败时返回 false 而不抛错，两个返回值都必须查
    local okC, resC = pcall(love.filesystem.createDirectory, Persist.DIR)
    if not okC then return false, "createDirectory 异常: " .. tostring(resC) end
    if resC == false then return false, "createDirectory 失败" end

    local okW, resW = pcall(love.filesystem.write, path, serialize(tbl))
    if not okW then return false, "write 异常: " .. tostring(resW) end
    if resW == false then return false, "write 失败（存档目录可能不可写）" end
    return true
end

function Persist.dirExists()
    local ok, info = pcall(love.filesystem.getInfo, Persist.DIR)
    return ok and info ~= nil
end

function Persist.getDir()
    local ok, dir = pcall(love.filesystem.getSaveDirectory)
    if not ok or not dir then return "(未知)" end
    return dir .. "/" .. Persist.DIR
end

-- ============================================================
-- 读盘
-- ============================================================
-- 返回 { progress = table|nil, collection = table|nil }，两个文件各自独立解析
function Persist.init()
    return {
        progress   = readTable(Persist.PROGRESS_PATH),
        collection = readTable(Persist.COLLECTION_PATH),
    }
end

-- ============================================================
-- 存档 → state
-- ============================================================
local function sanitizeNumber(v, default, minV, maxV)
    if type(v) ~= "number" or v ~= v then return default end
    if minV and v < minV then v = minV end
    if maxV and v > maxV then v = maxV end
    return v
end

local function sanitizeBool(v, default)
    if type(v) == "boolean" then return v end
    return default
end

-- 牌面字段白名单：读盘时只保留这些键，防止存档文件被塞进奇怪字段
-- 必须与 Champion.CARD_FIELDS（champion.lua）保持同字段集：
-- 漏 is_chip 会让筹码牌读盘后丢「结算点数 ×100」依据；漏 dice_token 会让骰子牌丢掷骰冻结令牌
local CARD_FIELDS = {
    "suit", "rank", "value", "kind", "mult_bonus", "original_rank",
    "isSpecial", "is_67", "is_rps", "is_blackhole", "is_cage", "is_chip", "is_champion",
    "rps_symbol", "s67_rank", "dice_token",
}

local function sanitizeCards(list)
    local out = {}
    if type(list) ~= "table" then return out end
    for _, c in ipairs(list) do
        if type(c) == "table" and (c.suit ~= nil or c.rank ~= nil) then
            local card = { faceUp = false }
            for _, f in ipairs(CARD_FIELDS) do
                if c[f] ~= nil then card[f] = c[f] end
            end
            table.insert(out, card)
        end
    end
    return out
end

-- 把存档合并进 state：缺字段用默认值补齐，非法值一律回默认（存档目录可能只读/为空）
function Persist.applyToState(state)
    if not state then return end
    local data = Persist.init()
    local d    = Persist.defaultProgress()
    local p    = type(data.progress) == "table" and data.progress or {}
    local ps   = type(p.settings) == "table" and p.settings or {}
    local ds   = d.settings

    state.progress = {
        hardCleared    = sanitizeBool(p.hardCleared, d.hardCleared),
        hardClearCount = math.floor(sanitizeNumber(p.hardClearCount, d.hardClearCount, 0)),
        maxStage       = math.floor(sanitizeNumber(p.maxStage, d.maxStage, 1)),
        maxChips       = math.floor(sanitizeNumber(p.maxChips, d.maxChips, 0)),
        totalRuns      = math.floor(sanitizeNumber(p.totalRuns, d.totalRuns, 0)),
        bestRoundsBasic = math.floor(sanitizeNumber(p.bestRoundsBasic, d.bestRoundsBasic, 0)),
        bestRoundsHard  = math.floor(sanitizeNumber(p.bestRoundsHard, d.bestRoundsHard, 0)),
        settings = {
            volume          = sanitizeNumber(ps.volume, ds.volume, 0, 1),
            resolutionIndex = math.floor(sanitizeNumber(ps.resolutionIndex, ds.resolutionIndex, 1, 4)),
            fullscreen      = sanitizeBool(ps.fullscreen, ds.fullscreen),
            autoEndOnBroke  = sanitizeBool(ps.autoEndOnBroke, ds.autoEndOnBroke),
        },
    }

    local coll = type(data.collection) == "table" and data.collection or {}
    state.championCards = sanitizeCards(coll.cards)

    -- 设置项落到 state.settings（游戏内读的就是这一份）
    if state.settings then
        state.settings.volume          = state.progress.settings.volume
        state.settings.resolutionIndex = state.progress.settings.resolutionIndex
        state.settings.fullscreen      = state.progress.settings.fullscreen
        state.settings.autoEndOnBroke  = state.progress.settings.autoEndOnBroke
    end
    return state.progress
end

-- ============================================================
-- state → 存档
-- ============================================================
local function snapshotProgress(state)
    local p = state.progress or Persist.defaultProgress()
    local ds = defaultSettings()
    local s  = state.settings or {}
    p.settings = {
        volume          = sanitizeNumber(s.volume, ds.volume, 0, 1),
        resolutionIndex = math.floor(sanitizeNumber(s.resolutionIndex, ds.resolutionIndex, 1, 4)),
        fullscreen      = sanitizeBool(s.fullscreen, ds.fullscreen),
        autoEndOnBroke  = sanitizeBool(s.autoEndOnBroke, ds.autoEndOnBroke),
    }
    state.progress = p
    return p
end

function Persist.saveProgress(state)
    if not state or not state.progress then return false, "state.progress 缺失" end
    return writeTable(Persist.PROGRESS_PATH, snapshotProgress(state))
end

function Persist.saveCollection(state)
    if not state then return false, "state 缺失" end
    local cards = {}
    for _, c in ipairs(sanitizeCards(state.championCards)) do table.insert(cards, c) end
    return writeTable(Persist.COLLECTION_PATH, { cards = cards })
end

-- 累计游玩局数 +1（模式选择里真正开一局时调用）
function Persist.startRun(state)
    if not state then return false end
    state.progress = state.progress or Persist.defaultProgress()
    state.progress.totalRuns = (state.progress.totalRuns or 0) + 1
    local stage = state.stage or 1
    state.progress.maxStage = math.max(state.progress.maxStage or 1, stage)
    return Persist.saveProgress(state)
end

-- 刷新「最高到达阶段 / 历史最高筹码」并写盘（破产、淘汰等一次游玩结束时调用）
function Persist.recordRunStats(state)
    if not state then return false end
    state.progress = state.progress or Persist.defaultProgress()
    state.progress.maxStage = math.max(state.progress.maxStage or 1, state.stage or 1)
    local chips = (state.player and state.player.chips) or 0
    state.progress.maxChips = math.max(state.progress.maxChips or 0, chips)
    return Persist.saveProgress(state)
end

-- 刷榜：记录最快通关小局数（分模式取最小）。同时把本局战绩写进 state._victoryInfo 供胜利画面展示
local function recordBestRounds(state, mode)
    local rounds = math.max(1, math.floor(state.roundsPlayed or 1))
    local key = (mode == "hard") and "bestRoundsHard" or "bestRoundsBasic"
    local best = state.progress[key] or 0
    local isNew = (best == 0) or (rounds < best)
    if isNew then state.progress[key] = rounds end
    state._victoryInfo = {
        rounds = rounds,
        best = isNew and rounds or best,
        mode = mode,
        isNewRecord = isNew,
    }
end

-- 通关记录：只认「进入 victory 时 gameMode == hard」
function Persist.recordVictory(state)
    if not state then return false end
    state.progress = state.progress or Persist.defaultProgress()
    state.progress.hardCleared    = true
    state.progress.hardClearCount = (state.progress.hardClearCount or 0) + 1
    recordBestRounds(state, "hard")   -- 刷榜：困难模式最快小局
    Persist.recordRunStats(state)   -- 顺带刷新最高阶段/筹码并写盘
    return true
end

-- 基础模式通关：只记最快小局（不解锁困难通关标记）
function Persist.recordVictoryRounds(state)
    if not state then return false end
    state.progress = state.progress or Persist.defaultProgress()
    recordBestRounds(state, "basic")
    return true
end

-- ============================================================
-- 删除 / 重置存档（删掉整个 saves21 目录）
-- ============================================================
function Persist.reset(state)
    -- 先删目录内所有文件，再删目录本身（LÖVE 不能删非空目录）
    local ok, items = pcall(love.filesystem.getDirectoryItems, Persist.DIR)
    if ok and type(items) == "table" then
        for _, name in ipairs(items) do
            pcall(love.filesystem.remove, Persist.DIR .. "/" .. name)
        end
    end
    pcall(love.filesystem.remove, Persist.PROGRESS_PATH)
    pcall(love.filesystem.remove, Persist.COLLECTION_PATH)
    pcall(love.filesystem.remove, Persist.DIR)

    -- state 立刻回到未解锁默认值（不能只在启动时读一次）
    if state then
        state.progress      = Persist.defaultProgress()
        state.championCards = {}
        if state.settings then
            local ds = defaultSettings()
            state.settings.volume          = ds.volume
            state.settings.resolutionIndex = ds.resolutionIndex
            state.settings.fullscreen      = ds.fullscreen
            state.settings.autoEndOnBroke  = ds.autoEndOnBroke
        end
    end
    return true
end

return Persist