--[[ The Slate desktop: wallpaper, icons, taskbar and start menu.

  The kernel owns windows; this owns everything outside them. It is registered
  with the kernel as the "shell", which calls back into it to paint the layers
  below and above the window stack, and to handle clicks that miss every
  window.

  Icons are 7x3 pixel art (see system/apps.lua) and can be dragged into any
  order, which is why the list comes from the catalog rather than straight from
  the registry.
]]

local use = ...
local theme = use("system/theme")
local ui = use("system/ui")
local catalog = use("system/catalog")
local notify = use("system/notify")
local infection = use("system/infection")
local verity = use("system/verity")
local compat = use("system/compat")
local dev = use("system/dev")
local wallpaper = use("system/wallpaper")
local cloud = use("system/cloud")

local desktop = {}

local kernel
local loadModule

local ICON_W, ICON_H = 9, 5        -- cell: 7px of art, a label row, a gap
local ART_W, ART_H = 7, 3
local COLUMNS = 5

local menuOpen = false
local menuIndex = 1
local selected = 1
local clockTimer
local animTimer
local updateTimer
local updatePending
local restartAt = nil              -- os.clock() when the countdown fires

local CHECK_EVERY = 1800           -- re-check every half hour
local IDLE_BEFORE_RESTART = 120    -- left alone this long before restarting
local COUNTDOWN = 10               -- visible warning before it happens
local status
local statusUntil = 0
local dragging = nil               -- { id, slot, mx, my, moved } while held
local hauntFrame = 0

-- catalog.all() reads settings and rebuilds a list; the taskbar, the icons
-- and the start menu all wanted it in the same frame. Cached for the frame
-- and dropped when anything could have changed it.
local appCache = nil
local function apps()
  if not appCache then appCache = catalog.all() end
  return appCache
end
function desktop.forgetApps() appCache = nil end
local hotbar = {}                  -- slot rects, rebuilt each taskbar draw

local MENU_POWER = {
  { label = "Shut down", action = "shutdown" },
  { label = "Reboot",    action = "reboot" },
  { label = "Exit Slate", action = "exit" },
}

--------------------------------------------------------------------------
-- launching
--------------------------------------------------------------------------

function desktop.launch(id, args)
  local app = catalog.byId(id)
  if not app then return nil end

  if app.single then
    for _, proc in ipairs(kernel.list()) do
      if proc.appId == id then
        kernel.focusOn(proc)
        return proc
      end
    end
  end

  -- An app built for a newer Slate is refused with a reason, rather than
  -- being started and failing somewhere in the middle.
  if app.api and not compat.satisfies(app.api) then
    desktop.notify(app.title .. ": " .. compat.tooNew(app.api))
    return nil
  end

  -- Cloud apps arrive on first open. The download is visible, because a
  -- window that takes two seconds to appear with no explanation reads as
  -- broken.
  if app.cloud and not cloud.isCached(app.module, kernel.root()) then
    if not cloud.available() then
      desktop.notify(app.title .. " needs a connection to download")
      return nil
    end
    desktop.notify("Downloading " .. app.title .. "...")
    kernel.draw()
    local fetched, why = cloud.fetch(app.module, kernel.root())
    if not fetched then
      desktop.notify(app.title .. ": " .. tostring(why))
      return nil
    end
  end

  -- A store app is a file that might have been deleted or be broken; that
  -- should be a message, not a dead desktop.
  local ok, module = pcall(loadModule, app.module)
  if not ok then
    desktop.notify("Could not start " .. app.title)
    return nil
  end

  local adapted, why = compat.adapt(module)
  if not adapted then
    desktop.notify(app.title .. ": " .. tostring(why))
    return nil
  end

  local proc = kernel.spawn({
    title = app.title,
    w = app.w, h = app.h,
    run = adapted.run,
    args = args,
  })
  if proc then proc.appId = id end
  return proc
end

--------------------------------------------------------------------------
-- layout
--------------------------------------------------------------------------

local function iconRect(index)
  local column = (index - 1) % COLUMNS
  local row = math.floor((index - 1) / COLUMNS)
  return 2 + column * (ICON_W + 1), 2 + row * ICON_H
end

local function slots()
  local _, _, DESK_H = kernel.size()
  return COLUMNS * math.max(1, math.floor(DESK_H / ICON_H))
end

local function slotAt(mx, my)
  for index = 1, slots() do
    local x, y = iconRect(index)
    if ui.hit(mx, my, x, y, ICON_W, ICON_H - 1) then return index end
  end
  return nil
end

--------------------------------------------------------------------------
-- painting
--------------------------------------------------------------------------

-- Draws one 7x3 art tile. A space in the pattern leaves the wallpaper showing,
-- so an icon is a shape rather than a coloured rectangle.
local function drawArt(target, x, y, art)
  for row = 1, ART_H do
    local line = art[row] or ""
    local runText, runColour, runStart = "", "", nil
    local function flush()
      if runStart then
        target.setCursorPos(x + runStart - 1, y + row - 1)
        target.blit(runText, runColour, runColour)
        runText, runColour, runStart = "", "", nil
      end
    end
    for column = 1, ART_W do
      local cell = line:sub(column, column)
      if cell == " " or cell == "" then
        flush()
      else
        if not runStart then runStart = column end
        runText = runText .. " "
        runColour = runColour .. cell
      end
    end
    flush()
  end
end

local BLANK_ICON = { "8888888", "8000008", "8888888" }

-- The colour a hotbar chip should be: whatever the icon uses most.
local function iconColour(app)
  local tally, best, bestCount = {}, "0", 0
  for _, line in ipairs(app.icon or BLANK_ICON) do
    for index = 1, #line do
      local cell = line:sub(index, index)
      if cell ~= " " then
        tally[cell] = (tally[cell] or 0) + 1
        if tally[cell] > bestCount then best, bestCount = cell, tally[cell] end
      end
    end
  end
  return 2 ^ tonumber(best, 16)
end

function desktop.drawBackground(win)
  appCache = nil                    -- one rebuild per frame, at the start
  local W, _, DESK_H = kernel.size()
  wallpaper.draw(win, W, DESK_H, theme.colour.desktop)

  -- Drawn before the icons so the desktop stays clickable: the infection is
  -- meant to look alarming, not to lock you out of the cure.
  if infection.active() then infection.glitch(win, W, DESK_H) end
  if verity.active() then verity.haunt(win, W, DESK_H, hauntFrame) end

  for index, app in ipairs(apps()) do
    local x, y = iconRect(index)
    if y + ART_H <= DESK_H then
      local active = (selected == index and kernel.focused() == nil)
      local held = dragging and dragging.id == app.id and dragging.moved

      if not held then
        -- Selection is a ring around the icon rather than an inverted label.
        if active then
          ui.ring(win, x + 4, y + 1, 2, theme.colour.desktopText)
        end
        drawArt(win, x + 1, y, app.icon or BLANK_ICON)
      end

      if notify.count(app.id) > 0 then
        ui.text(win, x + ICON_W - 1, y, ui.glyph.bullet, colours.red, theme.colour.desktop)
      end

      local label = ui.clip(app.title, ICON_W)
      local labelX = x + math.floor((ICON_W - #label) / 2)
      ui.text(win, labelX, y + ART_H, label,
        active and theme.colour.desktop or theme.colour.desktopText,
        active and theme.colour.desktopText or theme.colour.desktop)
    end
  end
end

function desktop.drawTaskbar(target)
  local W, H = kernel.size()
  ui.fill(target, 1, H, W, 1, theme.colour.bar)

  if verity.active() then
    local mark = verity.banner()
    ui.text(target, math.max(1, W - #mark - 6), H, mark, colours.white, colours.red)
  end

  if infection.active() then
    local banner = infection.banner()
    ui.text(target, math.max(1, W - #banner), H, banner, colours.white, colours.red)
  end

  -- Pressed state is an inversion, not a different shape.
  ui.text(target, 1, H, " " .. ui.glyph.up .. " ",
    menuOpen and colours.black or theme.colour.barText,
    menuOpen and theme.colour.barHot or theme.colour.bar)

  local clock = textutils.formatTime(os.time(), true)
  if dev.enabled() then
    clock = dev.stats(#kernel.list()) .. " " .. clock
  end
  local clockX = W - #clock + 1
  ui.text(target, clockX, H, clock, theme.colour.barText, theme.colour.bar)

  if status and os.clock() < statusUntil then
    ui.text(target, 5, H, ui.clip(status, clockX - 6), theme.colour.warn, theme.colour.bar)
    return
  end

  -- Hotbar: pinned apps, each a numbered chip. Click it or press Ctrl+n.
  hotbar = {}
  local x = 5
  for slot, id in ipairs(catalog.pinned()) do
    local app = catalog.byId(id)
    if not app then break end
    if x + 2 > clockX - 1 then break end
    local running = false
    for _, proc in ipairs(kernel.list()) do
      if proc.appId == id then running = true break end
    end
    local colour = iconColour(app)
    ui.badge(target, x, H, colour, tostring(slot),
      colour == colours.black and colours.white or colours.black)
    -- A dot marks an app that is already open, so the chip doubles as a
    -- "jump to it" rather than only a launcher.
    ui.text(target, x + 1, H, running and ui.glyph.bullet or " ",
      colour == colours.black and colours.white or colours.black, colour)
    hotbar[#hotbar + 1] = { id = id, x = x, w = 2 }
    x = x + 3
  end

  if #hotbar > 0 then
    ui.text(target, x - 1, H, "|", theme.colour.barHot, theme.colour.bar)
    x = x + 1
  end

  for _, proc in ipairs(kernel.list()) do
    local width = 11
    if x + width > clockX - 1 then break end
    local focused = (kernel.focused() == proc)
    local bg = focused and theme.colour.barHot or theme.colour.bar
    local fg = focused and colours.black or theme.colour.barText
    local mark = proc.minimised and ui.glyph.down or " "
    if proc.appId and notify.count(proc.appId) > 0 then mark = ui.glyph.bullet end
    ui.text(target, x, H, ui.pad(mark .. ui.clip(proc.title, width - 1), width), fg, bg)
    proc.taskX, proc.taskW = x, width
    x = x + width + 1
  end
end

local function menuItems()
  local items = {}
  for _, app in ipairs(apps()) do
    items[#items + 1] = { label = app.title, id = app.id }
  end
  items[#items + 1] = { separator = true }
  for _, entry in ipairs(MENU_POWER) do items[#items + 1] = entry end
  return items
end

local function menuRect()
  local _, H, DESK_H = kernel.size()
  local items = menuItems()
  local width = 16
  local height = math.min(#items + 2, DESK_H)
  return 1, H - height, width, height, items
end

function desktop.drawOverlay(target)
  local W, H = kernel.size()

  local toast = notify.active()
  if toast then
    local text = " " .. ui.clip(toast.text, math.max(4, W - 6)) .. " "
    local x = math.max(1, W - #text)
    ui.row(target, x, H - 1, #text, text, colours.white, theme.colour.accent)
  end

  -- The icon being dragged rides above everything, under the cursor.
  if dragging and dragging.moved then
    local app = catalog.byId(dragging.id)
    if app then
      drawArt(target,
        math.max(1, math.min(W - ART_W, dragging.mx - 3)),
        math.max(1, math.min(H - ART_H, dragging.my - 1)),
        app.icon or BLANK_ICON)
    end
  end

  if not menuOpen then return end
  local x, y, w, h, items = menuRect()

  ui.panel(target, x, y, w, h, theme.colour.window, theme.colour.accent)
  ui.row(target, x + 1, y + 1, w - 2, " " .. ui.spaced("Slate"),
    theme.colour.accentText, theme.colour.accent)

  for index = 1, math.min(#items, h - 2) do
    local item = items[index]
    local row = y + index
    if item.separator then
      ui.rule(target, x, row, w, theme.colour.muted, theme.colour.window)
    else
      local on = (index == menuIndex)
      ui.row(target, x, row, w,
        (on and (ui.glyph.right .. " ") or "  ") .. item.label,
        on and theme.colour.accentText or theme.colour.windowText,
        on and theme.colour.accent or theme.colour.window)
    end
  end
end

--------------------------------------------------------------------------
-- menu behaviour
--------------------------------------------------------------------------

function desktop.toggleMenu()
  menuOpen = not menuOpen
  if menuOpen then menuIndex = 1 end
  kernel.invalidate()
end

local function runMenuItem(item)
  if not item or item.separator then return end
  menuOpen = false
  kernel.invalidate()
  if item.id then
    desktop.launch(item.id)
  elseif item.action == "shutdown" then
    kernel.power("shutdown")
  elseif item.action == "reboot" then
    kernel.power("reboot")
  elseif item.action == "exit" then
    kernel.stop()
  end
end

local function stepMenu(delta)
  local _, _, _, _, items = menuRect()
  for _ = 1, #items do
    menuIndex = menuIndex + delta
    if menuIndex < 1 then menuIndex = #items end
    if menuIndex > #items then menuIndex = 1 end
    if not items[menuIndex].separator then break end
  end
  kernel.invalidate()
end

function desktop.overlayKey(event)
  if not menuOpen then return false end
  if event[1] ~= "key" then return event[1] == "char" end
  local key = event[2]
  if key == keys.up then stepMenu(-1)
  elseif key == keys.down then stepMenu(1)
  elseif key == keys.enter then
    local _, _, _, _, items = menuRect()
    runMenuItem(items[menuIndex])
  else
    menuOpen = false
    kernel.invalidate()
  end
  return true
end

function desktop.overlayClick(name, button, mx, my)
  if not menuOpen then return false end
  if name ~= "mouse_click" then return true end
  local x, y, w, h, items = menuRect()
  if not ui.hit(mx, my, x, y, w, h) then
    menuOpen = false
    kernel.invalidate()
    return true
  end
  local index = my - y
  if items[index] then
    menuIndex = index
    runMenuItem(items[index])
  end
  return true
end

--------------------------------------------------------------------------
-- clicks that miss every window
--------------------------------------------------------------------------

function desktop.taskbarClick(name, button, mx, my)
  -- A desktop icon dropped on the taskbar gets pinned there.
  if dragging then
    if name == "mouse_drag" then
      dragging.mx, dragging.my = mx, my
      dragging.moved = true
      kernel.invalidate()
      return
    elseif name == "mouse_up" then
      local held = dragging
      dragging = nil
      if held.moved then
        if catalog.pin(held.id) then
          desktop.notify("Pinned " .. held.id)
        else
          desktop.notify("Already pinned, or hotbar full")
        end
      end
      kernel.invalidate()
      return
    end
  end

  if name ~= "mouse_click" then return end
  if mx <= 3 then return desktop.toggleMenu() end

  for _, chip in ipairs(hotbar) do
    if mx >= chip.x and mx < chip.x + chip.w then
      if button == 2 then
        catalog.unpin(chip.id)
        desktop.notify("Unpinned " .. chip.id)
      else
        desktop.launch(chip.id)
      end
      kernel.invalidate()
      return
    end
  end
  for _, proc in ipairs(kernel.list()) do
    if proc.taskX and mx >= proc.taskX and mx < proc.taskX + proc.taskW then
      if kernel.focused() == proc and not proc.minimised then
        kernel.minimise(proc)
      else
        kernel.focusOn(proc)
      end
      return
    end
  end
end

-- Handles clicks AND drags on the wallpaper. A press that never moves is a
-- launch; a press that moves is a rearrange, decided on release.
function desktop.desktopClick(name, button, mx, my)
  local apps = apps()

  if name == "mouse_click" then
    local slot = slotAt(mx, my)
    if slot and apps[slot] then
      selected = slot
      dragging = { id = apps[slot].id, slot = slot, mx = mx, my = my, moved = false }
    end
    kernel.invalidate()

  elseif name == "mouse_drag" and dragging then
    dragging.mx, dragging.my = mx, my
    dragging.moved = true
    kernel.invalidate()

  elseif name == "mouse_up" and dragging then
    local target = slotAt(mx, my)
    local held = dragging
    dragging = nil
    if held.moved then
      if target and target ~= held.slot then
        catalog.moveTo(held.id, target)
      end
    else
      desktop.launch(held.id)
    end
    kernel.invalidate()
  end
end

-- Ctrl+1..9 from anywhere, handled by the kernel's shortcut layer.
function desktop.launchPinned(slot)
  local pins = catalog.pinned()
  if pins[slot] then desktop.launch(pins[slot]) end
end

function desktop.desktopKey(event)
  if event[1] ~= "key" then return end
  local apps = apps()
  local key = event[2]
  if key == keys.right then selected = math.min(#apps, selected + 1)
  elseif key == keys.left then selected = math.max(1, selected - 1)
  elseif key == keys.down then selected = math.min(#apps, selected + COLUMNS)
  elseif key == keys.up then selected = math.max(1, selected - COLUMNS)
  elseif key == keys.enter and apps[selected] then desktop.launch(apps[selected].id)
  end
  kernel.invalidate()
end

--------------------------------------------------------------------------
-- system
--------------------------------------------------------------------------

-- Unattended by default: it installs and then tells you, rather than asking
-- first. The restart is still yours to make - nothing reboots on its own.
function desktop.checkForUpdate()
  local update = loadModule("system/update")
  if not http or not update.url() then return end
  local mode = update.mode()
  if mode == "off" then return end

  if mode == "notify" then
    local info = update.check()
    if info and info.newer then
      notify.push("updater", "Slate " .. info.version .. " is available")
      desktop.notify("Update available: " .. info.version)
    end
    return
  end

  local version, problem = update.applySilently(kernel.root and kernel.root() or "")
  if version then
    updatePending = version
    notify.push("updater", "Updated to Slate " .. version)
    desktop.notify("Updated to " .. version)
  elseif problem then
    notify.push("updater", "Update failed: " .. tostring(problem))
  end
end

-- Windows-style: the restart happens on its own, but only when the computer
-- has been left alone AND nothing is open. A reboot that eats what somebody
-- was doing is worse than an out-of-date OS.
local function considerRestart()
  if not updatePending then return end

  local update = loadModule("system/update")
  local mode = update.restartMode()
  if mode == "never" then return end

  if restartAt then
    -- Any input at all cancels it; you should never lose a race with your
    -- own computer.
    if kernel.idleFor() < 1 then
      restartAt = nil
      desktop.notify("Restart cancelled")
      return
    end
    local left = math.ceil(restartAt - os.clock())
    if left <= 0 then
      kernel.power("reboot")
    else
      desktop.notify("Restarting for update in " .. left .. "s - press anything to stop")
    end
    return
  end

  if mode == "ask" then return end
  if #kernel.list() > 0 then return end
  if kernel.idleFor() < IDLE_BEFORE_RESTART then return end
  restartAt = os.clock() + COUNTDOWN
end

function desktop.updatePending()
  return updatePending
end

function desktop.notify(text)
  status = text
  statusUntil = os.clock() + 3
  kernel.invalidate()
end

-- A popup is just a tiny process, so it gets a title bar and an X like
-- anything else. Closing one is easy; they simply come back.
local function spawnPopup(message, onClose)
  local proc = kernel.spawn({
    title = "!",
    w = 26, h = 6,
    run = function(ctx)
      local width, height = term.getSize()
      term.setBackgroundColour(colours.white)
      term.clear()
      ui.row(term, 1, 1, width, " Warning", colours.white, colours.red)
      ui.centre(term, 3, ui.clip(message, width - 2), colours.black, colours.white, 1, width)
      ui.centre(term, height, " OK ", colours.white, colours.grey, 1, width)
      os.pullEvent("key")
    end,
  })
  if proc then
    local previous = proc.onClose
    proc.onClose = function()
      if previous then pcall(previous) end
      onClose()
    end
  end
end

-- True when a window is covering the whole desktop: animating a background
-- nobody can see is the easiest way to waste a Minecraft computer's time.
local function backgroundHidden()
  local W, _, DESK_H = kernel.size()
  for _, proc in ipairs(kernel.list()) do
    if not proc.minimised and proc.x <= 1 and proc.y <= 1
      and proc.w >= W and proc.h >= DESK_H then
      return true
    end
  end
  return false
end

-- Fullscreen, so there is nowhere to look away to. Spawned as an ordinary
-- process, which means it still has an X and cannot wedge the desktop.
local function wakeVerity(why)
  local W, _, DESK_H = kernel.size()
  kernel.spawn({
    title = "?",
    w = W, h = DESK_H, x = 1, y = 1,
    run = function(ctx) verity.scene(ctx, why) end,
  })
end

function desktop.systemEvent(event)
  if event[1] == "timer" and event[2] == clockTimer then
    clockTimer = os.startTimer(1)
    infection.tick(spawnPopup)
    considerRestart()
    kernel.invalidate()

  elseif event[1] == "timer" and event[2] == updateTimer then
    updateTimer = os.startTimer(CHECK_EVERY)
    desktop.checkForUpdate()

  elseif event[1] == "timer" and event[2] == animTimer then
    animTimer = os.startTimer(0.3)
    hauntFrame = hauntFrame + 1
    if (wallpaper.animated() or verity.active()) and not backgroundHidden() then
      wallpaper.tick()
      kernel.invalidate()
    end
  end
end

function desktop.init(k, loader)
  kernel = k
  loadModule = loader
  kernel.launcher = function(id, args) return desktop.launch(id, args) end
  clockTimer = os.startTimer(1)
  wallpaper.load()
  animTimer = os.startTimer(0.3)

  -- Store/update work starts after the desktop is up, so a slow server cannot
  -- delay startup. Messenger itself is initialized by the kernel and needs no
  -- UI window to stay alive.
  updateTimer = os.startTimer(4)
end

return desktop
