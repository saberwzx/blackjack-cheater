-- ============================================================
-- conf.lua — LÖVE 启动配置
--
-- 职责: 只声明 t.identity（决定 love.filesystem 的存档目录），
--       其余字段一律保留 LÖVE 默认值，避免改变既有窗口行为。
-- 依赖: 无
-- 调用方: LÖVE 运行时（love.load 之前自动调用 love.conf）
-- 禁止改动: 不要在这里设置 window 尺寸/可缩放/全屏 —— 分辨率与全屏是
--           由游戏内设置页（UI.RESOLUTIONS + love.window.setMode）负责的。
-- ============================================================

function love.conf(t)
    -- 存档目录名（love.filesystem.getSaveDirectory() 的末级目录）
    -- 存档数据全部写在它下面的 saves21/ 子目录里，发布时可整目录删除
    t.identity = "blackjack-cheater"
end