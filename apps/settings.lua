--[[ Settings - categories on the left, the things they hold on the right.

  The old version was one long scrolling list where the interesting controls
  were buried under headings. This splits it into sections you can jump
  between, so nothing is more than two keys away.

  Every change still takes effect immediately - there is no apply button -
  and anything worth keeping is written to CC's settings straight away.
]]

local use = ...
local ui = use("system/ui")
local theme = use("system/theme")
local screens = use("system/screens")
local update = use("system/update")
local dev = use("system/dev")
local wallpaper = use("system/wallpaper")
local catalog = use("system/catalog")

local app = {}

local BOOT_MARKER = "-- slate boot"
local SIDEBAR = 11

local function freeSpace()
  local ok, bytes = pcall(fs.getFreeSpace, "/")
  if not ok or type(bytes) ~= "number" then return "unknown" end
  if bytes >= 1048576 then return string.format("%.1f MB", bytes / 1048576) end
  return string.format("%.0f KB", bytes / 1024)
end

local function uptime()
  local seconds = math.floor(os.clock())
  if seconds < 60 then return seconds .. "s" end
  return string.format("%dm %02ds", math.floor(seconds / 60), seconds % 60)
end

local function bootState(root)
  if not fs.exists("/startup.lua") then return "off" end
  local handle = fs.open("/startup.lua", "r")
  if not handle then return "unknown" end
  local body = handle.readAll() or ""
  handle.close()
  if body:find(BOOT_MARKER, 1, true) then return "on" end
  if fs.combine(root, "startup.lua") == "startup.lua" then return "on" end
  return "foreign"
end

local function setBoot(root, on)
  if on then
    local target = fs.combine(root, "startup.lua")
    if target == "startup.lua" then return false, "Slate already is /startup.lua" end
    local handle, err = fs.open("/startup.lua", "w")
    if not handle then return false, tostring(err) end
    handle.write(BOOT_MARKER .. "\nshell.run(" .. string.format("%q", target) .. ")\n")
    handle.close()
    return true
  end
  local ok, err = pcall(fs.delete, "/startup.lua")
  if not ok then return false, tostring(err) end
  return true
end

--------------------------------------------------------------------------

function app.run(ctx)
  local root = ctx.root()
  local section = 1
  local index = 1
  local scroll = 0
  local pane = "items"
  local notice, noticeUntil = nil, 0

  local function say(text)
    notice, noticeUntil = text, os.clock() + 4
  end

  local function ask(label, value)
    local width = term.getSize()
    ui.panel(term, 2, 3, width - 2, 6, theme.colour.muted, theme.colour.accent)
    ui.text(term, 4, 4, label, colours.black, theme.colour.muted)
    ui.fill(term, 4, 6, width - 6, 1, colours.white)
    term.setCursorPos(4, 6)
    term.setBackgroundColour(colours.white)
    term.setTextColour(colours.black)
    return read(nil, nil, nil, value)
  end

  ------------------------------------------------------------------
  -- sections
  ------------------------------------------------------------------

  local function appearance()
    return {
      {
        label = "Accent", value = theme.accents[theme.accent].name,
        swatch = theme.colour.accent,
        act = function()
          theme.setAccent(theme.accent + 1)
          theme.persist()
          ctx.redraw()
        end,
      },
      {
        label = "Background", value = theme.wallpapers[theme.wallpaper].name,
        swatch = theme.colour.desktop,
        act = function()
          theme.setWallpaper(theme.wallpaper + 1)
          theme.persist()
          ctx.redraw()
        end,
      },
      {
        label = "Animation", value = wallpaper.current().name,
        act = function()
          wallpaper.setStyle(wallpaper.style + 1)
          wallpaper.persist()
          ctx.redraw()
          say(wallpaper.animated() and "Animated background on" or "Static background")
        end,
      },
    }
  end

  local function display()
    local items = {}
    local monitors = screens.available()
    if #monitors == 0 then
      items[#items + 1] = { label = "Monitors", value = "none", fact = true }
    else
      for _, monitor in ipairs(monitors) do
        local w, h = screens.sizeOf(monitor)
        items[#items + 1] = {
          label = ui.clip(monitor, 10) .. " " .. ((w and (w .. "x" .. h)) or "?"),
          value = ({ off = "Off", mirror = "Mirror", display = "Display" })
            [screens.modeOf(monitor)],
          act = function()
            local mode = screens.cycle(monitor)
            local kernel = use("system/kernel")
            if kernel.relayout then kernel.relayout() end
            ctx.redraw()
            say(({ off = "Monitor off", mirror = "Mirroring",
                   display = "Desktop moved to " .. monitor })[mode])
          end,
        }
      end
    end
    local termW, termH = term.getSize()
    items[#items + 1] = { label = "This screen", value = termW .. "x" .. termH, fact = true }
    items[#items + 1] = { label = "Colour",
      value = term.isColour() and "yes" or "mono", fact = true }
    return items
  end

  local function system()
    local boot = bootState(root)
    return {
      {
        label = "Name", value = os.getComputerLabel() or "(none)",
        act = function()
          local typed = ask("Name this computer:", os.getComputerLabel() or "")
          if typed == nil then return end
          os.setComputerLabel(typed ~= "" and typed or nil)
          say(typed ~= "" and "Renamed" or "Label cleared")
        end,
      },
      {
        label = "Start at boot",
        value = boot == "on" and "On" or (boot == "foreign" and "Other" or "Off"),
        act = function()
          if boot == "foreign" then
            say("/startup.lua is not Slate's")
            return
          end
          local ok, err = setBoot(root, boot ~= "on")
          say(ok and (boot == "on" and "Boot script removed" or "Slate will boot")
            or ("Failed: " .. tostring(err)))
        end,
      },
      {
        label = "Start at login",
        value = (function()
          local list = catalog.autostart()
          return #list == 0 and "none" or table.concat(list, " ")
        end)(),
        act = function()
          local current = table.concat(catalog.autostart(), " ")
          local typed = ask("App ids to start, space separated:", current)
          if typed == nil then return end
          local wanted = {}
          for id in typed:gmatch("%S+") do wanted[id:lower()] = true end
          for _, entry in ipairs(catalog.all()) do
            catalog.setAutostart(entry.id, wanted[entry.id] == true)
          end
          say("Saved")
        end,
      },
      { label = "Computer", value = "#" .. os.getComputerID(), fact = true },
      { label = "Free space", value = freeSpace(), fact = true },
      { label = "Uptime", value = uptime(), fact = true },
    }
  end

  local function updates()
    local mode = update.mode()
    return {
      {
        label = "Updates",
        value = ({ off = "Off", notify = "Notify me", silent = "Automatic" })[mode],
        act = function()
          local next_ = ({ off = "notify", notify = "silent", silent = "off" })[mode]
          update.setMode(next_)
          say(({
            off = "Updates off",
            notify = "You will be told, not updated",
            silent = "Updates install by themselves",
          })[next_])
        end,
      },
      {
        label = "Restart",
        value = ({ idle = "When idle", ask = "Ask me", never = "Never" })
          [update.restartMode()],
        act = function()
          local current = update.restartMode()
          local next_ = ({ idle = "ask", ask = "never", never = "idle" })[current]
          update.setRestartMode(next_)
          say(({
            idle = "Restarts itself once left alone",
            ask = "Updates install, you restart",
            never = "Never restarts on its own",
          })[next_])
        end,
      },
      { label = "Check now", value = "", act = function() ctx.launch("updater") end },
      {
        label = "Source", value = update.isDefaultUrl() and "default" or "custom",
        act = function()
          local typed = ask("Update base URL (blank = default):", update.url())
          if typed == nil then return end
          update.setUrl(typed)
          say("Saved")
        end,
      },
      { label = "Version", value = update.version(), fact = true },
    }
  end

  local function developer()
    return {
      {
        label = "Developer mode", value = dev.enabled() and "On" or "Off",
        act = function()
          local now = dev.toggle()
          ctx.redraw()
          say(now and "Console and stats enabled" or "Developer mode off")
        end,
      },
      { label = "Apps", value = tostring(#catalog.all()), fact = true },
      {
        label = "Free up space", value = "cloud apps",
        act = function()
          -- Only removes app code that can be fetched again. Nothing you made
          -- and nothing the OS needs offline is touched.
          local cloud = use("system/cloud")
          local modules = {}
          for _, entry in ipairs(catalog.builtins()) do
            if entry.cloud then modules[#modules + 1] = entry.module end
          end
          local freed = cloud.evict(modules, root)
          say(freed > 0 and ("Freed " .. math.floor(freed / 1024) .. "K")
            or "Nothing cached to remove")
        end,
      },
      { label = "Heap", value = (dev.heapKB() and (dev.heapKB() .. "K")) or "n/a",
        fact = true },
    }
  end

  local function power()
    return {
      { label = "Reboot", value = "", act = function() ctx.power("reboot") end },
      { label = "Shut down", value = "", act = function() ctx.power("shutdown") end },
    }
  end

  local SECTIONS = {
    { name = "Look",    build = appearance },
    { name = "Screens", build = display },
    { name = "System",  build = system },
    { name = "Updates", build = updates },
    { name = "Dev",     build = developer },
    { name = "Power",   build = power },
  }

  ------------------------------------------------------------------

  local function items()
    return SECTIONS[section].build()
  end

  local function firstSelectable(list)
    for position, item in ipairs(list) do
      if not item.fact then return position end
    end
    return 1
  end

  local function step(list, delta)
    local at = index
    for _ = 1, #list do
      at = at + delta
      if at < 1 then at = #list end
      if at > #list then at = 1 end
      if not list[at].fact then return at end
    end
    return index
  end

  local function body()
    local _, height = term.getSize()
    return math.max(1, height - 2)
  end

  local function draw()
    local width, height = term.getSize()
    local list = items()
    local rows = body()
    local right = SIDEBAR + 1
    local rightW = width - right

    index = math.min(index, math.max(1, #list))
    if index < scroll + 1 then scroll = index - 1 end
    if index > scroll + rows then scroll = index - rows end
    scroll = ui.clampScroll(scroll, #list, rows)

    term.setBackgroundColour(theme.colour.window)
    term.clear()
    ui.row(term, 1, 1, width, " " .. ui.spaced("Settings"),
      theme.colour.accentText, theme.colour.accent)

    ui.fill(term, 1, 2, SIDEBAR, height - 2, theme.colour.muted)
    for position, entry in ipairs(SECTIONS) do
      local y = position + 1
      if y > height - 1 then break end
      local on = (position == section)
      ui.row(term, 1, y, SIDEBAR,
        (on and (ui.glyph.right .. " ") or "  ") .. entry.name,
        on and theme.colour.accentText or colours.black,
        on and theme.colour.accent or theme.colour.muted)
    end

    for offset = 0, rows - 1 do
      local item = list[scroll + offset + 1]
      if not item then break end
      local y = 2 + offset
      local on = (scroll + offset + 1 == index) and pane == "items" and not item.fact
      local bg = on and theme.colour.accent or theme.colour.window
      local fg = on and theme.colour.accentText
        or (item.fact and theme.colour.mutedText or theme.colour.windowText)

      local value = item.value or ""
      local room = math.max(1, rightW - #value - 2)
      ui.row(term, right, y, rightW,
        " " .. ui.pad(ui.clip(item.label, room), room) .. " " .. value, fg, bg)
      if item.swatch then ui.fill(term, width, y, 1, 1, item.swatch) end
    end

    ui.scrollbar(term, width, 2, rows, #list, scroll, theme.colour.muted, theme.colour.accent)

    if notice and os.clock() < noticeUntil then
      ui.row(term, 1, height, width, " " .. ui.clip(notice, width - 2),
        colours.white, theme.colour.ok)
    else
      ui.row(term, 1, height, width,
        " " .. (pane == "sections" and "Enter opens a section"
          or "Left for sections, Enter to change"),
        theme.colour.mutedText, theme.colour.muted)
    end
  end

  index = firstSelectable(items())
  draw()
  local ticker = os.startTimer(1)

  while true do
    local event, key, mx, my = os.pullEvent()

    if event == "timer" and key == ticker then
      ticker = os.startTimer(1)
      draw()

    elseif event == "key" then
      local list = items()
      if pane == "sections" then
        if key == keys.up then section = math.max(1, section - 1)
        elseif key == keys.down then section = math.min(#SECTIONS, section + 1)
        elseif key == keys.right or key == keys.enter then
          pane = "items"
          index = firstSelectable(items())
          scroll = 0
        end
      else
        if key == keys.up then index = step(list, -1)
        elseif key == keys.down then index = step(list, 1)
        elseif key == keys.left then pane = "sections"
        elseif key == keys.enter or key == keys.space then
          local item = list[index]
          if item and item.act then item.act() end
        end
      end
      draw()

    elseif event == "mouse_click" then
      if mx and mx <= SIDEBAR then
        local picked = my - 1
        if SECTIONS[picked] then
          section = picked
          pane = "items"
          index = firstSelectable(items())
          scroll = 0
        end
      elseif my then
        local list = items()
        local picked = scroll + my - 1
        local item = list[picked]
        if item and not item.fact then
          pane = "items"
          if picked == index and item.act then item.act() else index = picked end
        end
      end
      draw()

    elseif event == "mouse_scroll" then
      scroll = ui.clampScroll(scroll + key, #items(), body())
      draw()

    elseif event == "term_resize" then
      draw()
    end
  end
end

return app
