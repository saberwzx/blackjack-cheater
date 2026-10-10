-- conf.lua : LÖVE 11.5 window configuration for Blackjack Cheater
function love.conf(t)
  t.identity = "blackjack-cheater"
  t.version = "11.5"
  t.console = false
  t.window.title = "Blackjack Cheater"
  t.window.width = 1280
  t.window.height = 720
  t.window.resizable = true
  t.window.minwidth = 800
  t.window.minheight = 600
  t.window.vsync = 1
  t.window.msaa = 2
  t.window.highdpi = false
  t.modules.joystick = false
  t.modules.physics = false
  t.modules.video = false
  t.modules.touch = false
  t.modules.thread = true
end
