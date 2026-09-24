--[[ Editor - CraftOS's own `edit` running in a Slate window.

  Writing a second text editor would be a worse editor. `edit` already does
  syntax highlighting, run-from-editor and save-as, and it adapts to whatever
  terminal size it is given - which here is the window.
]]

local app = {}
local use = ...
local ui = use("system/ui")

local function askForPath()
  local function draw()
    term.setBackgroundColour(colours.white)
    term.setTextColour(colours.black)
    term.clear()
    term.setCursorPos(2, 2)
    term.setTextColour(colours.blue)
    term.write("Open or create")
    term.setTextColour(colours.black)
    term.setCursorPos(2, 4)
    term.write("Path:")
  end
  draw()
  local path = ui.inputLine(term, 2, 5, "", {
    bg = colours.lightGrey,
    fg = colours.black,
    onResize = draw,
  })
  term.setBackgroundColour(colours.white)
  return path
end

function app.run(ctx, path)
  if not path or path == "" then
    path = askForPath()
    if not path or path == "" then return end
  end

  ctx.setTitle("Edit " .. fs.getName(path))

  if fs.isDir(path) then
    local function drawError()
      term.setBackgroundColour(colours.white)
      term.setTextColour(colours.red)
      term.clear()
      term.setCursorPos(2, 2)
      term.write("That is a folder.")
      term.setCursorPos(2, 4)
      term.setTextColour(colours.black)
      term.write("Press any key to close.")
    end
    drawError()
    while true do
      local event = os.pullEvent()
      if event == "term_resize" then drawError()
      elseif event == "key" then break end
    end
    return
  end

  -- CraftOS's editor handles term_resize itself. Slate forwards resize events
  -- even while its event filter is waiting for another event.
  shell.run("/rom/programs/edit.lua", path)
end

return app
