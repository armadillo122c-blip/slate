--[[ Updater - checks for a new Slate and installs it.

  Opened from Settings, or automatically at boot when auto-update is on. The
  automatic path still shows this window; an OS that rewrites itself silently
  is not one you can trust.
]]

local use = ...
local ui = use("system/ui")
local theme = use("system/theme")
local update = use("system/update")

local app = {}

function app.run(ctx, mode)
  local root = ctx.root()
  local state = "checking"        -- checking | none | ready | working | done | failed
  local info, problem = nil, nil
  local line, step, steps = "", 0, 0
  local auto = (mode == "auto")

  local function draw()
    local width, height = term.getSize()
    term.setBackgroundColour(theme.colour.window)
    term.clear()
    ui.row(term, 1, 1, width, " Slate Update", theme.colour.accentText, theme.colour.accent)

    ui.text(term, 2, 3, "Installed", theme.colour.mutedText, theme.colour.window)
    ui.text(term, 13, 3, update.version(), theme.colour.windowText, theme.colour.window)

    if state == "checking" then
      ui.text(term, 2, 5, "Checking for updates...", theme.colour.windowText, theme.colour.window)

    elseif state == "none" then
      ui.text(term, 2, 5, "Slate is up to date.", theme.colour.ok, theme.colour.window)
      if info then
        ui.text(term, 2, 6, "Latest is " .. info.version, theme.colour.mutedText, theme.colour.window)
      end

    elseif state == "failed" then
      ui.text(term, 2, 5, "Could not update", theme.colour.danger, theme.colour.window)
      local y = 6
      for _, text in ipairs(ui.wrap(problem or "unknown", width - 2)) do
        if y > height - 2 then break end
        ui.text(term, 2, y, text, theme.colour.mutedText, theme.colour.window)
        y = y + 1
      end

    elseif state == "ready" and info then
      ui.text(term, 2, 5, "Version " .. info.version .. " is available",
        theme.colour.accent, theme.colour.window)
      ui.text(term, 2, 6, #info.files .. " file(s)", theme.colour.mutedText, theme.colour.window)
      local y = 8
      for _, text in ipairs(ui.wrap(info.notes or "", width - 2)) do
        if y > height - 2 then break end
        ui.text(term, 2, y, text, theme.colour.windowText, theme.colour.window)
        y = y + 1
      end

    elseif state == "working" then
      ui.text(term, 2, 5, ui.clip(line, width - 2), theme.colour.windowText, theme.colour.window)
      local barWidth = width - 4
      local filled = steps > 0 and math.floor(barWidth * step / steps + 0.5) or 0
      ui.fill(term, 3, 7, barWidth, 1, colours.grey)
      if filled > 0 then ui.fill(term, 3, 7, filled, 1, theme.colour.accent) end

    elseif state == "done" and info then
      ui.text(term, 2, 5, "Updated to " .. info.version, theme.colour.ok, theme.colour.window)
      ui.text(term, 2, 7, "Restart to finish.", theme.colour.windowText, theme.colour.window)
    end

    local hint = " "
    if state == "ready" then hint = " [Enter] install   [Backspace] later"
    elseif state == "done" then hint = " [Enter] restart now   [Backspace] later"
    elseif state == "none" or state == "failed" then hint = " [R] check again"
    end
    ui.row(term, 1, height, width, hint, theme.colour.mutedText, theme.colour.muted)
  end

  local function check()
    state = "checking"
    draw()
    local found, err = update.check()
    if not found then
      state, problem = "failed", err
    elseif not found.newer then
      state, info = "none", found
    else
      state, info = "ready", found
      ctx.notify("Slate " .. found.version .. " is available")
    end
    draw()
  end

  local function install()
    if not info then return end
    state = "working"
    step, steps = 0, #info.files
    draw()
    local ok, result = update.install(info, root, function(stage, done, total)
      line, step, steps = stage, done, total
      draw()
    end)
    if ok then
      state = "done"
      ctx.notify("Updated to " .. info.version)
    else
      state, problem = "failed", tostring(result)
    end
    draw()
  end

  check()
  -- Auto mode installs without being asked; that is what auto means, and the
  -- window is still here showing exactly what it did.
  if auto and state == "ready" then install() end

  while true do
    local event, key = os.pullEvent()
    if event == "key" then
      if state == "ready" and key == keys.enter then install()
      elseif state == "ready" and key == keys.backspace then return
      elseif state == "done" and key == keys.enter then ctx.power("reboot")
      elseif state == "done" and key == keys.backspace then return
      elseif (state == "none" or state == "failed") and key == keys.r then check()
      end
    elseif event == "term_resize" then
      draw()
    end
  end
end

return app
