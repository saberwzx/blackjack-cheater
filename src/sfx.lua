-- ============================================================
-- Sfx — 音效管理器
-- 恰好 21 点时播放 blackjack.MP3（收银机入账音效）
-- 另有两条「盖过 BGM」的一次性音效：
--   67 音效     music/67.MP3      —— 67 组合技触发时播放一遍
--   滚出去音效  music/getout.MP3  —— 进入 forceExit（破产/淘汰）画面时播放一遍
-- 依赖: love.audio（无第三方依赖）
-- 被谁调用: main.lua（Sfx.init / Sfx.isOverlayPlaying）、src/game_state.lua（Sfx.play67 / Sfx.playGetout）
-- 公开 API: Sfx.init(), Sfx.play21(), Sfx.play67(), Sfx.playGetout(),
--           Sfx.isOverlayPlaying(), Sfx.getGetoutDuration()
-- 禁区: 禁止在 love.draw 或每帧 update 里调用 play*（会重复播放）；玩法侧必须由一次性标记守卫
-- 已踩过的坑: 加载失败只 print、不抛错（沿用既有容错写法）；两个盖过类音效共用同一条通道，
--             起新的之前先停掉旧的，避免两首叠在一起
-- ============================================================

local Sfx = {}

local sfx21 = nil
local sfx67 = nil
local sfxGetout = nil

function Sfx.init()
    local ok, src = pcall(love.audio.newSource, "music/blackjack.MP3", "static")
    if ok and src then
        sfx21 = src
        sfx21:setVolume(1.0)
    else
        print("[Sfx] 加载 blackjack.MP3 失败: " .. tostring(src))
    end

    -- 67 音效（67 组合技触发时播放）
    local ok67, src67 = pcall(love.audio.newSource, "music/67.MP3", "static")
    if ok67 and src67 then
        sfx67 = src67
        sfx67:setVolume(1.0)
    else
        print("[Sfx] 加载 67.MP3 失败（该音效将静音）: " .. tostring(src67))
    end

    -- 滚出去音效（进入 forceExit 画面时播放；用 ASCII 文件名 getout.MP3 规避中文名编码风险）
    local okGo, srcGo = pcall(love.audio.newSource, "music/getout.MP3", "static")
    if okGo and srcGo then
        sfxGetout = srcGo
        sfxGetout:setVolume(1.0)
    else
        print("[Sfx] 加载 getout.MP3 失败（该音效将静音）: " .. tostring(srcGo))
    end
end

function Sfx.play21()
    if sfx21 then
        sfx21:stop()
        sfx21:play()
    end
end

function Sfx.play67()
    if sfxGetout then sfxGetout:stop() end
    if sfx67 then
        sfx67:stop()
        sfx67:play()
    end
end

function Sfx.playGetout()
    if sfx67 then sfx67:stop() end
    if sfxGetout then
        sfxGetout:stop()
        sfxGetout:play()
    end
end

-- 盖过类音效是否还有在播的（main.lua 每帧据此决定 BGM 让位 / 恢复）
function Sfx.isOverlayPlaying()
    if sfx67 and sfx67:isPlaying() then return true end
    if sfxGetout and sfxGetout:isPlaying() then return true end
    return false
end

-- 只读查询：getout 音效的真实时长（秒）。加载失败 / 拿不到时长时返回 0。
-- 供 game_state.barFail 对齐 forceExit 倒计时，保证音效播完再回标题。
function Sfx.getGetoutDuration()
    if sfxGetout and sfxGetout.getDuration then
        return sfxGetout:getDuration()
    end
    return 0
end

return Sfx