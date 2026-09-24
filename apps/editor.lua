--[[ Editor - CraftOS's own `edit` running in a Slate window.

  Writing a second text editor would be a worse editor. `edit` already does
  syntax highlighting, run-from-editor and save-as, and it adapts to whatever
  terminal size it is given - which here is the window.
]]

local app = {}

local function askForPath()
  term.setBackgroundColour(colours.white)
  term.setTextColour(colours.black)
  term.clear()
  term.setCursorPos(2, 2)
  term.setTextColour(colours.blue)
  term.write("Open or create")
  term.setTextColour(colours.black)
  term.setCursorPos(2, 4)
  term.write("Path:")
  term.setCursorPos(2, 5)
  term.setBackgroundColour(colours.lightGrey)
  local width = term.getSize()
  term.write((" "):rep(width - 2))
  term.setCursorPos(2, 5)
  local path = read()
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
    term.setBackgroundColour(colours.white)
    term.setTextColour(colours.red)
    term.clear()
    term.setCursorPos(2, 2)
    term.write("That is a folder.")
    term.setCursorPos(2, 4)
    term.setTextColour(colours.black)
    term.write("Press any key to close.")
    os.pullEvent("key")
    return
  end

  -- CraftOS's editor handles term_resize itself. Slate forwards resize events
  -- even while its event filter is waiting for another event.
  shell.run("/rom/programs/edit.lua", path)
end

return app
