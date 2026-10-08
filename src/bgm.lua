-- ============================================================
-- BGM 管理器：3 首阶段曲 + 1 首酒吧曲（标题页复用 phase1）
-- 职责: 按 state 切换循环播放的阶段 BGM，并在一次性音效播放期间为其让位
-- 依赖: love.audio（无第三方依赖）
-- 被谁调用: main.lua（init / update / setVolume / yieldToSfx / resumeFromSfx / isYielding）
-- 公开 API: BGM.init(), BGM.update(state), BGM.setVolume(v), BGM.stop(),
--           BGM.yieldToSfx(keepOnExit), BGM.resumeFromSfx(), BGM.isYielding(), BGM.status()
-- 禁区: 让位期间不得调用 switch（会打断让位）；恢复必须用 pause/play，禁止 stop/play（会从头重播）
-- 已踩过的坑: 让位期间若照常每帧 switch，恢复逻辑会与切歌逻辑打架——故 update 开头必须跳过
-- ============================================================

local BGM = {}

local sources = {}       -- [1]=phase1, [2]=phase2, [3]=phase3, [4]=bar
local currentStage = 0   -- 0 = 无, 1/2/3 = 阶段曲, 4 = 酒吧曲
local currentSource = nil

-- ===== 按曲目的基准增益（响度匹配，不要凭感觉改） =====
-- 测量命令（工程 music/ 目录下）：
--   ffmpeg -hide_banner -i music/phase1.MP3 -af volumedetect -f null -
--   ffmpeg -hide_banner -i music/bar.MP3    -af volumedetect -f null -
-- 原始测量值：phase1  mean_volume = -18.0 dB, max_volume = -2.2 dB
--             bar     mean_volume = -27.3 dB, max_volume = -6.7 dB
-- 取值依据：GAIN[4] = 10 ^ ((mean_phase1 - mean_bar) / 20)
--                  = 10 ^ ((-18.0 - (-27.3)) / 20) = 10 ^ (9.3 / 20) = 2.916 -> 2.92
-- 说明：bar 峰值 -6.7 dB，乘 2.92 后理论峰值约 +2.6 dB，若听感失真可下调本值。
-- GAIN[1..3] 必须保持 1.00：基础模式 / 困难模式的响度不得有任何变化。
BGM.GAIN = {
    [1] = 1.00,
    [2] = 1.00,
    [3] = 1.00,
    [4] = 2.92,
}

-- ===== 为一次性音效让位 =====
local yieldActive = false      -- 让位中：BGM 已暂停，update 必须跳过 switch
local keepStageOnExit = false  -- 让位发生在 forceExit（破产/淘汰）画面：恢复后不要被 switch(0) 关掉

function BGM.init()
    local files = {
        [1] = "music/phase1.MP3",
        [2] = "music/phase2.MP3",
        [3] = "music/phase3.MP3",
        [4] = "music/bar.MP3",
    }
    for i, path in ipairs(files) do
        local ok, src = pcall(love.audio.newSource, path, "stream")
        if ok and src then
            src:setLooping(true)
            sources[i] = src
        else
            print("[BGM] 加载失败: " .. path .. " -> " .. tostring(src))
        end
    end
end

-- 切到指定曲目的 BGM（0 = 停止；1/2/3 = 阶段曲，4 = 酒吧曲）
function BGM.switch(stage)
    if stage == currentStage then return end
    currentStage = stage

    if currentSource then
        currentSource:stop()
        currentSource = nil
    end

    if stage > 0 and sources[stage] then
        currentSource = sources[stage]
        currentSource:play()
    end
end

-- 每帧调用：根据 state.state + state.stage 决定播什么
function BGM.update(state)
    if not state then return end

    -- 让位期间一律跳过切歌（否则恢复逻辑会与切歌逻辑打架）：恢复后再交给本函数收敛
    if yieldActive then return end

    if state.state ~= "forceExit" then
        keepStageOnExit = false
    end

    if state.state == "title" then
        BGM.switch(1)   -- 标题页 = phase1
    elseif state.state == "forceExit" then
        -- 破产/淘汰画面：音效让位后已恢复的阶段曲保持播放，直到回标题再换 phase1
        if not keepStageOnExit then BGM.switch(0) end
    elseif state.gameMode == "bar" then
        -- 酒吧对局全程（说明弹窗 / 要牌 / 庄家 / 结算 / 喝酒赠酒弹窗 / 结局画面）
        -- 一律播酒吧曲。本分支必须放在 title 判断之后：settings.gameMode 在标题页
        -- 就可能是 "bar"，否则标题页会被换成酒吧曲，破坏既有听感。
        BGM.switch(4)
    elseif state.stage and state.stage >= 1 and state.stage <= 3 then
        BGM.switch(state.stage)
    end
end

function BGM.setVolume(v)
    -- 逐首乘该曲目的基准增益：既保留「设置界面统一调节音量」的语义，
    -- 又让酒吧曲与阶段曲响度相当（GAIN[1..3] 恒为 1.00，阶段曲听感不变）
    for i, src in ipairs(sources) do
        if src then src:setVolume(v * (BGM.GAIN[i] or 1)) end
    end
end

function BGM.stop()
    if currentSource then
        currentSource:stop()
        currentSource = nil
    end
    currentStage = 0
end

-- ===== 为一次性音效让位 / 恢复 =====

-- 让位：暂停当前阶段曲（保留播放进度）。main.lua 必须在 BGM.update 之前调用，
-- 否则 forceExit 帧里 update 会先把阶段曲 stop 掉，就没有进度可续了。
-- keepOnExit: 让位发生在 forceExit（破产/淘汰）画面时传 true —— 恢复后阶段曲继续播到回标题。
-- 可重复调用（幂等）：音效播放期间每帧调用只做「升级 keepOnExit」，不会重复暂停。
function BGM.yieldToSfx(keepOnExit)
    if keepOnExit then keepStageOnExit = true end
    if yieldActive then return end
    yieldActive = true
    if currentSource then
        currentSource:pause()
    end
end

-- 恢复：pause 之后再 play 才是从暂停处续播（stop 再 play 会从头重播）
function BGM.resumeFromSfx()
    if not yieldActive then return end
    yieldActive = false
    if currentSource and currentStage > 0 then
        currentSource:play()
    end
end

function BGM.isYielding()
    return yieldActive
end

-- 只读状态查询（不改任何状态）：供 main.lua 与无头验证脚本核对让位 / 续播是否真的生效
function BGM.status()
    local playing = false
    local position = 0
    if currentSource then
        playing = currentSource:isPlaying()
        position = currentSource:tell()
    end
    return {
        stage = currentStage,
        playing = playing,
        position = position,
        yielding = yieldActive,
    }
end

return BGM
