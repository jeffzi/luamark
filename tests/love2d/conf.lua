--- Love2D configuration for headless testing.
--- Disables all visual/audio modules so the test can run without a display server.
function love.conf(t) -- luacheck: ignore love
   t.title = "luamark-love2d-test"
   t.console = true

   t.modules.window = false
   t.modules.graphics = false
   t.modules.audio = false
   t.modules.sound = false
   t.modules.image = false
   t.modules.video = false
   t.modules.joystick = false
   t.modules.physics = false
   t.modules.touch = false
   t.modules.font = false

   t.modules.timer = true
   t.modules.event = true
   t.modules.system = true
   t.modules.data = true
   t.modules.math = true
end
