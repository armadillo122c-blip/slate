--[[ Slate kernel: processes, windows, compositing, event routing.

  Each process is a coroutine plus two windows. The outer `frame` holds the
  title bar and is kept INVISIBLE; the inner `content` is visible relative to
  the frame, so an app's writes land in the frame's buffer but never reach the
  real terminal on their own.

  That indirection is the whole trick. CC's window API draws straight through
  to its parent, so visible overlapping windows would paint over each other in
  whatever order they happened to write. Instead the kernel reads each frame's
  buffer with getLine() and blits the finished picture one row at a time -
  19 blits per frame, correct z-order, no flicker.
]]

local use = ...
local theme = use("system/theme")
local ui = use("system/ui")
local screens = use("system/screens")
local bootseq = use("system/bootseq")
local notify = use("system/notify")
local compat = use("system/compat")
local peripherals = use("system/peripherals")
local sound = use("system/sound")
local messenger = use("system/messenger")

local kernel = {}

local native = term.native()

-- The desktop is built at the size of whatever it is being shown on: the
-- computer's own terminal normally, or a monitor running in display mode.
local function nativeSize() return native.getSize() end
local function displaySize() return screens.displaySize(nativeSize) end

local W, H = displaySize()
local DESK_H = H - 1          -- the bottom row belongs to the taskbar

local processes = {}          -- back to front; the last entry has focus
local nextId = 1
local focus = nil

---@type table Registered by startup.lua via kernel.setDesktop before run().
local desktop

---@type table The wallpaper layer; created in kernel.run() before any draw.
local background

---@type table The finished frame. Composed here, then presented to the real
--- terminal and to any mirrored monitors, so every output shows the same
--- picture from one piece of work.
local screen

local dirty = true
local alive = true
local drag = nil              -- { proc, offset } while a title bar is held
local ctrlDown = false
local root = ""               -- where Slate is installed; set by startup.lua
local pendingPower = nil      -- "reboot" or "shutdown", run after the loop ends
local modems = {}             -- modems seen attached, so detach can be told apart
local painted = {}            -- last row presented, so only changes are redrawn
local watchers = {}           -- frame listeners (the remote viewer)
local monitorNotice = false   -- whether the "desktop moved" notice is showing
local lastInput = 0           -- os.clock() of the last key or click

kernel.launcher = nil         -- set by the desktop so apps can open apps

--------------------------------------------------------------------------
-- geometry
--------------------------------------------------------------------------

local function clamp(proc)
  proc.x = math.max(1, math.min(proc.x, W - proc.w + 1))
  proc.y = math.max(1, math.min(proc.y, DESK_H - proc.h + 1))
end

local function topAt(mx, my)
  for index = #processes, 1, -1 do
    local proc = processes[index]
    if not proc.minimised and ui.hit(mx, my, proc.x, proc.y, proc.w, proc.h) then
      return proc
    end
  end
  return nil
end

local function indexOf(proc)
  for index, candidate in ipairs(processes) do
    if candidate == proc then return index end
  end
  return nil
end

--------------------------------------------------------------------------
-- processes
--------------------------------------------------------------------------

function kernel.list() return processes end
function kernel.focused() return focus end
function kernel.invalidate() dirty = true end
function kernel.size() return W, H, DESK_H end

function kernel.focusOn(proc)
  if not proc or proc.dead then return end
  local index = indexOf(proc)
  if index then table.remove(processes, index) end
  processes[#processes + 1] = proc
  proc.minimised = false
  focus = proc
  -- Opening the thing is what marks it read.
  if proc.appId then notify.clear(proc.appId) end
  dirty = true
end

function kernel.close(proc)
  local index = indexOf(proc)
  if not index then return end
  table.remove(processes, index)
  proc.dead = true
  -- Cleanup registered with ctx.onClose. It runs here, outside the app's
  -- coroutine, so it must not draw or yield - it is for releasing things the
  -- world can see, like a speaker that would otherwise keep playing.
  if proc.onClose then
    local hook = proc.onClose
    proc.onClose = nil
    pcall(hook)
  end
  if focus == proc then
    focus = processes[#processes]
  end
  dirty = true
end

function kernel.minimise(proc)
  proc.minimised = true
  if focus == proc then
    focus = nil
    for index = #processes, 1, -1 do
      if not processes[index].minimised then focus = processes[index]; break end
    end
  end
  dirty = true
end

-- Fullscreen genuinely resizes the window, rather than just drawing it bigger,
-- so the app is told its terminal changed and can lay itself out again.
function kernel.toggleFullscreen(proc)
  if not proc or proc.dead then return end
  if proc.full then
    proc.x, proc.y = proc.full.x, proc.full.y
    proc.w, proc.h = proc.full.w, proc.full.h
    proc.full = nil
  else
    proc.full = { x = proc.x, y = proc.y, w = proc.w, h = proc.h }
    proc.x, proc.y, proc.w, proc.h = 1, 1, W, DESK_H
  end
  proc.frame.reposition(1, 1, proc.w, proc.h)
  proc.content.reposition(1, 2, proc.w, proc.h - 1)
  clamp(proc)
  dirty = true
  kernel.resume(proc, { "term_resize", n = 1 })
end

local function contextFor(proc)
  -- compat.context adds ctx.api and makes unknown fields no-ops, so an app
  -- built for a different Slate version degrades instead of crashing.
  return compat.context({
    close = function() kernel.close(proc) end,
    setTitle = function(text) proc.title = tostring(text); dirty = true end,
    launch = function(id, args) if kernel.launcher then return kernel.launcher(id, args) end end,
    size = function() return proc.content.getSize() end,
    redraw = function() dirty = true end,
    onClose = function(fn) proc.onClose = fn end,
    power = function(mode) kernel.power(mode) end,
    notify = function(text) notify.push(proc.appId, text) end,
    fullscreen = function() kernel.toggleFullscreen(proc) end,
    root = function() return root end,
  })
end

-- Windows open centred. The small stagger stops a second window of the same
-- size from sitting exactly on top of the first, without throwing it into a
-- corner.
local function placement(w, h)
  local step = (#processes % 4) - 1        -- -1, 0, 1, 2
  local x = math.floor((W - w) / 2) + 1 + step * 2
  local y = math.floor((DESK_H - h) / 2) + 1 + step
  return x, y
end

function kernel.spawn(spec)
  local w = math.max(16, math.min(spec.w or 38, W))
  local h = math.max(5, math.min(spec.h or 13, DESK_H))
  local x, y = placement(w, h)
  if spec.x then x = spec.x end
  if spec.y then y = spec.y end

  local frame = window.create(native, 1, 1, w, h, false)
  local content = window.create(frame, 1, 2, w, h - 1, true)

  local proc = {
    id = nextId,
    title = spec.title or "Window",
    x = x, y = y, w = w, h = h,
    frame = frame, content = content,
    filter = nil, dead = false, minimised = false, crashed = false,
  }
  nextId = nextId + 1
  clamp(proc)

  content.setBackgroundColour(theme.colour.window)
  content.setTextColour(theme.colour.windowText)
  content.clear()
  content.setCursorPos(1, 1)

  local ctx = contextFor(proc)
  proc.co = coroutine.create(function()
    return spec.run(ctx, table.unpack(spec.args or {}, 1, (spec.args and #spec.args) or 0))
  end)

  processes[#processes + 1] = proc
  kernel.focusOn(proc)
  kernel.resume(proc, { n = 0 })
  return proc
end

--------------------------------------------------------------------------
-- crash screen
--------------------------------------------------------------------------

-- A crashed app keeps its window and shows why, instead of vanishing and
-- leaving you to guess.
local function crashScreen(message)
  local w, h = term.getSize()
  term.setBackgroundColour(theme.colour.danger)
  term.setTextColour(colours.white)
  term.clear()
  ui.text(term, 2, 1, "This app stopped", colours.white, theme.colour.danger)
  local lines = ui.wrap(message, w - 2)
  for index = 1, math.min(#lines, h - 3) do
    ui.text(term, 2, 2 + index, lines[index], colours.white, theme.colour.danger)
  end
  ui.text(term, 2, h, "Press any key to close", colours.white, theme.colour.danger)
  os.pullEvent("key")
end

--------------------------------------------------------------------------
-- resuming
--------------------------------------------------------------------------

function kernel.resume(proc, event)
  if proc.dead or coroutine.status(proc.co) == "dead" then return end
  local name = event[1]
  if proc.filter and name ~= nil and name ~= proc.filter and name ~= "terminate"
      and name ~= "term_resize" then return end

  local previous = term.redirect(proc.content)
  local ok, result = coroutine.resume(proc.co, table.unpack(event, 1, event.n or #event))
  term.redirect(previous)
  dirty = true

  if not ok then
    -- Ctrl+T is a deliberate stop, not a fault. os.pullEvent raises
    -- "Terminated" for it, so close quietly instead of accusing the app.
    if tostring(result):find("Terminated") then
      kernel.close(proc)
      return
    end
    if proc.crashed then
      kernel.close(proc)              -- the crash screen itself failed; give up
      return
    end
    proc.crashed = true
    proc.title = "Error"
    proc.filter = nil
    local message = tostring(result)
    proc.co = coroutine.create(function() crashScreen(message) end)
    return kernel.resume(proc, { n = 0 })
  end

  if coroutine.status(proc.co) == "dead" then
    kernel.close(proc)
  else
    proc.filter = result
  end
end

local function broadcast(event)
  local snapshot = {}
  for index, proc in ipairs(processes) do snapshot[index] = proc end
  for _, proc in ipairs(snapshot) do
    if not proc.dead then kernel.resume(proc, event) end
  end
end

--------------------------------------------------------------------------
-- drawing
--------------------------------------------------------------------------

local function drawTitleBar(proc)
  local active = (proc == focus)
  local bg = active and theme.colour.titleOn or theme.colour.titleOff
  ui.row(proc.frame, 1, 1, proc.w, " " .. ui.clip(proc.title, proc.w - 8),
    theme.colour.titleText, bg)
  -- Minimise, fullscreen and close sit at fixed offsets from the right edge.
  ui.text(proc.frame, proc.w - 4, 1, "_", theme.colour.titleText, bg)
  ui.text(proc.frame, proc.w - 2, 1, proc.full and "v" or "^", theme.colour.titleText, bg)
  ui.text(proc.frame, proc.w, 1, "X", active and colours.white or theme.colour.titleText,
    active and theme.colour.danger or bg)
  -- Rounded title bar ends, so a window is not a hard rectangle. Only the
  -- title row is touched: the rows below belong to the content window, and
  -- drawing a side border there would clip two columns off every app.
  ui.text(proc.frame, 1, 1, "(", bg, colours.black)
end

local function splice(base, patch, at)
  return base:sub(1, at - 1) .. patch .. base:sub(at + #patch)
end

-- The desktop draws inside the kernel's own coroutine, not an app's, so an
-- error here used to take the whole OS down - which is exactly what a broken
-- developer-mode taskbar did. Shell drawing is now contained: a failing
-- layer is skipped and reported once, and the rest of the desktop lives.
local shellFault = nil

local function safely(what, fn, ...)
  local ok, err = pcall(fn, ...)
  if ok then return true end
  if not shellFault then
    shellFault = what .. ": " .. tostring(err)
  end
  return false
end

function kernel.draw()
  dirty = false
  if not safely("background", desktop.drawBackground, background) then
    ui.fill(background, 1, 1, W, DESK_H, theme.colour.desktop)
  end

  for _, proc in ipairs(processes) do
    if not proc.minimised then drawTitleBar(proc) end
  end

  -- Compose: wallpaper, then every window back to front, into the frame buffer.
  for y = 1, DESK_H do
    local text, fg, bg = background.getLine(y)
    for _, proc in ipairs(processes) do
      if not proc.minimised and y >= proc.y and y <= proc.y + proc.h - 1 then
        local t, f, b = proc.frame.getLine(y - proc.y + 1)
        text = splice(text, t, proc.x)
        fg = splice(fg, f, proc.x)
        bg = splice(bg, b, proc.x)

        -- One column of shadow to the right lifts the window off the
        -- wallpaper; a solid border would only look blockier.
        local edge = proc.x + proc.w
        if edge <= W and y > proc.y then
          text = splice(text, " ", edge)
          bg = splice(bg, colours.toBlit(colours.black), edge)
        end
      elseif not proc.minimised and y == proc.y + proc.h and proc.y + proc.h <= DESK_H then
        local from = proc.x + 1
        local span = math.min(proc.w, W - from + 1)
        if span > 0 then
          text = splice(text, (" "):rep(span), from)
          bg = splice(bg, colours.toBlit(colours.black):rep(span), from)
        end
      end
    end
    screen.setCursorPos(1, y)
    screen.blit(text, fg, bg)
  end

  if not safely("taskbar", desktop.drawTaskbar, screen) then
    ui.fill(screen, 1, H, W, 1, theme.colour.bar)
  end
  safely("overlay", desktop.drawOverlay, screen)

  -- Say what broke, once, where it cannot be missed.
  if shellFault then
    ui.row(screen, 1, H, W, " shell: " .. ui.clip(shellFault, W - 9),
      colours.white, theme.colour.danger)
  end

  -- Present: the real terminal always, then any mirrors. Presenting to
  -- term.native() is unconditional, which is what keeps Slate a no-screen-
  -- required OS however many monitors are attached.
  -- Only rows that actually changed are sent to the terminal. Most frames
  -- touch a few lines - a clock tick, one window - so this is the difference
  -- between redrawing 19 rows and redrawing one, and it is what makes the
  -- desktop feel smooth rather than flickery.
  local changed = {}
  for y = 1, H do
    local text, fg, bg = screen.getLine(y)
    local signature = text .. fg .. bg
    if painted[y] ~= signature then
      painted[y] = signature
      changed[#changed + 1] = y
    end
  end

  local onMonitor = screens.primary() ~= nil
  if not onMonitor then
    for _, y in ipairs(changed) do
      local text, fg, bg = screen.getLine(y)
      native.setCursorPos(1, y)
      native.blit(text, fg, bg)
    end
  end
  if onMonitor or screens.count() > 0 then
    screens.presentFrame(H, function(y) return screen.getLine(y) end, changed)
  end

  -- Anything watching the frame (the remote viewer) gets the same rows.
  if #changed > 0 and next(watchers) then
    for _, watcher in pairs(watchers) do
      local ok = pcall(watcher, changed, function(y)
        return screen.getLine(y)
      end, W, H)
      if not ok then watchers[watcher] = nil end
    end
  end
  -- The computer itself cannot show a frame built for a bigger screen, so it
  -- says where the desktop went. Drawn once on the change, not every frame -
  -- clearing the terminal 3 times a second is exactly the flicker the
  -- change-only presenter exists to remove.
  if onMonitor ~= monitorNotice then
    monitorNotice = onMonitor
    local nw, nh = nativeSize()
    native.setBackgroundColour(colours.black)
    native.clear()
    if onMonitor then
      ui.centre(native, math.floor(nh / 2), "Desktop on " .. tostring(screens.primaryName()),
        theme.colour.accent, colours.black, 1, nw)
      ui.centre(native, math.floor(nh / 2) + 1, "keyboard still works here",
        colours.grey, colours.black, 1, nw)
    else
      kernel.repaint()
    end
  end

  -- The real cursor follows the focused app's window, so typing in a nested
  -- shell looks like typing in a terminal.
  local proc = focus
  if proc and not proc.minimised and not proc.crashed and proc.content.getCursorBlink() then
    local cx, cy = proc.content.getCursorPos()
    local x, y = proc.x + cx - 1, proc.y + cy
    if x >= 1 and x <= W and y >= 1 and y <= DESK_H then
      native.setTextColour(proc.content.getTextColour())
      native.setCursorPos(x, y)
      native.setCursorBlink(true)
      return
    end
  end
  native.setCursorBlink(false)
end

--------------------------------------------------------------------------
-- input
--------------------------------------------------------------------------

-- fromTouch: a monitor touch is a click with no matching mouse_up, so it must
-- never start a window drag - the window would stick to every later touch.
local function handleMouse(event, fromTouch)
  local name, button, mx, my = event[1], event[2], event[3], event[4]
  lastInput = os.clock()

  if drag then
    if name == "mouse_drag" then
      drag.proc.x = mx - drag.dx
      drag.proc.y = my - drag.dy
      clamp(drag.proc)
      dirty = true
    elseif name == "mouse_up" then
      drag = nil
    end
    return
  end

  if desktop.overlayClick(name, button, mx, my) then return end

  if my >= H then
    desktop.taskbarClick(name, button, mx, my)
    return
  end

  local proc = topAt(mx, my)
  if not proc then
    desktop.desktopClick(name, button, mx, my)
    return
  end

  if name == "mouse_click" then kernel.focusOn(proc) end

  if my == proc.y then
    if name ~= "mouse_click" then return end
    local column = mx - proc.x + 1
    if column == proc.w then
      kernel.close(proc)
    elseif column == proc.w - 2 then
      kernel.toggleFullscreen(proc)
    elseif column == proc.w - 4 then
      kernel.minimise(proc)
    elseif not proc.full and not fromTouch then
      -- A fullscreen window has nowhere to be dragged to.
      drag = { proc = proc, dx = mx - proc.x, dy = my - proc.y }
    end
    return
  end

  kernel.resume(proc, { name, button, mx - proc.x + 1, my - proc.y, n = 4 })
end

local function cycleFocus()
  local visible = {}
  for _, proc in ipairs(processes) do
    if not proc.minimised then visible[#visible + 1] = proc end
  end
  if #visible < 2 then
    if #visible == 1 then kernel.focusOn(visible[1]) end
    return
  end
  -- The focused window is last, so the one before it is "next" in the cycle.
  kernel.focusOn(visible[#visible - 1])
end

local function handleKey(event)
  local name, key = event[1], event[2]
  lastInput = os.clock()

  if name == "key" then
    if key == keys.leftCtrl or key == keys.rightCtrl then ctrlDown = true end
  elseif name == "key_up" then
    if key == keys.leftCtrl or key == keys.rightCtrl then ctrlDown = false end
  end

  -- Window management shortcuts are taken before the app sees them; a basic
  -- computer has no mouse, so these are the only way to drive the OS there.
  if name == "key" and ctrlDown then
    if key == keys.tab then cycleFocus(); return end
    if key == keys.w then if focus then kernel.close(focus) end; return end
    if key == keys.e then desktop.toggleMenu(); return end
    if key == keys.f then if focus then kernel.toggleFullscreen(focus) end; return end
    for slot = 1, 9 do
      if key == keys[tostring(slot)] then
        desktop.launchPinned(slot)
        return
      end
    end
  end

  if desktop.overlayKey(event) then return end
  if focus then
    kernel.resume(focus, event)
  else
    desktop.desktopKey(event)   -- arrow-key navigation of the icon grid
  end
end

--------------------------------------------------------------------------
-- boot
--------------------------------------------------------------------------

function kernel.setDesktop(d)
  desktop = d
end

-- Where Slate was launched from. Settings needs it to write a boot script that
-- points back here, and guessing it from shell state would be fragile.
function kernel.setRoot(path)
  root = path or ""
end

-- Where Slate lives. The unattended updater needs this to write files back
-- into the install, not into the root of the computer.
function kernel.root()
  return root
end

-- Seconds since the last key or click. An unattended restart waits for this,
-- because rebooting a computer somebody is using is not an update, it is a
-- crash with extra steps.
function kernel.idleFor()
  return os.clock() - lastInput
end

-- Frame watchers receive (changedRows, getLine, W, H) after every paint.
function kernel.watch(fn)
  watchers[fn] = fn
  painted = {}          -- the next frame is full, so a watcher starts complete
  dirty = true
  return fn
end

function kernel.unwatch(fn)
  watchers[fn] = nil
end

-- The whole screen as blit rows. Used to send a joining viewer a full frame.
function kernel.snapshot()
  local rows = {}
  if not screen then return rows, W, H end
  for y = 1, H do
    local text, fg, bg = screen.getLine(y)
    rows[y] = { text, fg, bg }
  end
  return rows, W, H
end

-- Called when a monitor becomes (or stops being) the display, and when one
-- is resized. Everything that depends on the size is rebuilt, and every app
-- is told its terminal changed so it can lay itself out again.
-- Forces the next frame to be painted in full. Anything that invalidates
-- what is already on screen - a resize, a monitor coming or going - has to
-- call this, or the change-only presenter will happily skip rows that are
-- stale rather than unchanged.
function kernel.repaint()
  painted = {}
  dirty = true
end

function kernel.relayout()
  painted = {}
  W, H = displaySize()
  DESK_H = H - 1
  background = window.create(native, 1, 1, W, DESK_H, false)
  screen = window.create(native, 1, 1, W, H, false)
  for _, proc in ipairs(processes) do
    if proc.full then
      proc.x, proc.y, proc.w, proc.h = 1, 1, W, DESK_H
    end
    proc.w = math.min(proc.w, W)
    proc.h = math.min(proc.h, DESK_H)
    proc.frame.reposition(1, 1, proc.w, proc.h)
    proc.content.reposition(1, 2, proc.w, proc.h - 1)
    clamp(proc)
    kernel.resume(proc, { "term_resize", n = 1 })
  end
  dirty = true
end

function kernel.stop()
  alive = false
end

-- Power actions end the event loop first, so the sequence owns a clean screen
-- with no windows left to redraw over it.
function kernel.power(mode)
  pendingPower = (mode == "reboot") and "reboot" or "shutdown"
  alive = false
end

function kernel.run()
  if not desktop then
    error("kernel.run: no desktop registered (call kernel.setDesktop first)", 0)
  end
  -- The compositor reads window buffers directly. Without getLine there is no
  -- way to stack windows correctly, so say so now rather than drawing garbage.
  if not window.create(native, 1, 1, 1, 1, false).getLine then
    error("Slate needs CC:Tweaked (window.getLine is missing)", 0)
  end
  kernel.relayout()
  messenger.init(root)

  while alive do
    if dirty then kernel.draw() end
    local event = table.pack(os.pullEventRaw())
    local name = event[1]
    local messengerUpdate = messenger.handleEvent(event)

    if name == "term_resize" then
      W, H = native.getSize()
      DESK_H = H - 1
      background = window.create(native, 1, 1, W, DESK_H, false)
      screen = window.create(native, 1, 1, W, H, false)
      for _, proc in ipairs(processes) do
        if proc.full then
          -- A maximised window means "fill the screen", so it follows the
          -- screen rather than keeping the size it happened to have.
          proc.x, proc.y, proc.w, proc.h = 1, 1, W, DESK_H
          proc.frame.reposition(1, 1, proc.w, proc.h)
          proc.content.reposition(1, 2, proc.w, proc.h - 1)
          kernel.resume(proc, { "term_resize", n = 1 })
        end
        clamp(proc)
      end
      dirty = true
    elseif name == "mouse_click" or name == "mouse_up"
        or name == "mouse_drag" or name == "mouse_scroll" then
      handleMouse(event)

    elseif name == "monitor_touch" then
      -- An advanced monitor showing the mirror can drive Slate directly. One
      -- lent to an app is that app's to handle, so the event is passed on
      -- instead of being swallowed.
      if screens.owns(event[2]) then
        handleMouse({ "mouse_click", 1, event[3], event[4], n = 4 }, true)
      else
        broadcast(event)
      end

    elseif name == "monitor_resize" then
      if screens.primaryName() == event[2] then
        kernel.relayout()
      elseif screens.owns(event[2]) then
        screens.clearAll()
        dirty = true
      end

    elseif name == "peripheral" then
      -- Something was attached. A modem gets a chime, because plugging in
      -- wireless is the moment worth hearing.
      local attached = event[2]
      if peripherals.isType(attached, "modem") then
        modems[attached] = true
        sound.chime("connect")
        desktop.notify("Wireless connected")
        notify.push(nil, "Modem attached: " .. tostring(attached))
      end
      dirty = true
      broadcast(event)

    elseif name == "peripheral_detach" then
      local gone = event[2]
      -- The peripheral is already gone, so its type cannot be asked for -
      -- that is why the modems seen at attach time are remembered.
      if modems[gone] then
        modems[gone] = nil
        sound.chime("disconnect")
        desktop.notify("Wireless disconnected")
      end
      if screens.primaryName() == gone then
        screens.forget(gone)
        kernel.relayout()          -- the desktop comes home to the computer
      else
        screens.forget(gone)
      end
      dirty = true
      broadcast(event)
    elseif name == "key" or name == "key_up" or name == "char" or name == "paste" then
      handleKey(event)
    elseif name == "terminate" then
      -- Ctrl+T closes the focused window rather than killing the whole OS;
      -- shutting down is a deliberate choice in the menu.
      if focus then kernel.resume(focus, event) end
    else
      desktop.systemEvent(event)
      broadcast(event)
    end

    if messengerUpdate then
      broadcast({ "messenger_update", n = 1 })
    end
  end

  messenger.shutdown()

  -- Leaving Slate should not leave a desktop frozen on someone's wall.
  screens.clearAll()

  if pendingPower then bootseq.run(pendingPower) end
end

return kernel
