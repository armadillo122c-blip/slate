--[[ Terminal - a full CraftOS shell inside a Slate window.

  There is no emulation here. The kernel redirects term to this window before
  resuming the process, so /rom/programs/shell.lua runs exactly as it would
  fullscreen. Anything you can run on a computer, you can run in this window.
]]

local app = {}

function app.run(ctx, dir)
  if not shell then
    term.setBackgroundColour(colours.black)
    term.setTextColour(colours.red)
    term.clear()
    term.setCursorPos(1, 1)
    print("No shell API available.")
    os.pullEvent("key")
    return
  end

  term.setBackgroundColour(colours.black)
  term.setTextColour(colours.white)
  term.clear()
  term.setCursorPos(1, 1)

  if dir and fs.isDir(dir) then
    shell.setDir(dir)
  end

  -- Returning from here closes the window, so `exit` in the shell closes the
  -- terminal, which is what anyone would expect.
  -- The CraftOS shell redraws its prompt on term_resize; Slate forwards that
  -- event even when the shell is waiting for input.
  shell.run("/rom/programs/shell.lua")
end

return app
