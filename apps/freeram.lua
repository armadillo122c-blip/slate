--[[ FreeRAM.exe - the joke virus.

  Pretends to free memory, then "infects" the desktop: wallpaper noise,
  popups, a compromised banner. It is all cosmetic - see system/infection.lua.
  No file is deleted and nothing outside the in-game computer is touched.

  Closing this window does not cure it. Deleting this file does not cure it.
  Rebooting does not cure it. Zare's Antivirus does.
]]

local use = ...
local ui = use("system/ui")
local theme = use("system/theme")
local sound = use("system/sound")
local infection = use("system/infection")

local app = {}

local STEPS = {
  "Scanning memory banks...",
  "Defragmenting RAM...",
  "Compressing unused bytes...",
  "Freeing 4096 MB...",
  "Optimising registry...",
}

function app.run(ctx)
  local width, height = term.getSize()
  local phase = "Free up memory on this computer"
  local stepNumber = 0

  local function centre(y, text, fg, bg)
    ui.centre(term, y, text, fg, bg, 1, width)
  end

  local function drawPhase()
    width, height = term.getSize()
    term.setBackgroundColour(colours.white)
    term.setTextColour(colours.black)
    term.clear()
    ui.row(term, 1, 1, width, " FreeRAM.exe", colours.white, colours.blue)
    if phase == "intro" then
      centre(3, "Free up memory on this computer", colours.grey, colours.white)
      centre(5, " Optimise now ", colours.white, colours.green)
      centre(7, "[Enter] to start", colours.grey, colours.white)
      return
    elseif phase == "corrupt" then
      term.setBackgroundColour(colours.black)
      term.clear()
      for _ = 1, 30 do
        term.setCursorPos(math.random(1, width), math.random(1, height))
        term.setBackgroundColour(({ colours.red, colours.green, colours.black })[math.random(1, 3)])
        term.setTextColour(colours.white)
        term.write(({ "#", "%", "?", "0", "1", "!" })[math.random(1, 6)])
      end
      centre(math.floor(height / 2), " YOUR PC IS NOW CORRUPTED ", colours.white, colours.red)
      return
    elseif phase == "final" then
      term.setBackgroundColour(colours.black)
      term.clear()
      centre(math.floor(height / 2) - 1, "haha", colours.red, colours.black)
      centre(math.floor(height / 2) + 1, "get Zare's Antivirus", colours.lightGrey, colours.black)
      ui.row(term, 1, height, width, " closing this will not help",
        colours.red, colours.black)
      return
    end
    centre(math.max(2, math.floor(height / 2)), phase, colours.black, colours.white)
    if stepNumber > 0 then
      local bar = math.max(1, width - 6)
      local filled = math.floor(bar * stepNumber / #STEPS + 0.5)
      ui.fill(term, 4, 6, bar, 1, colours.lightGrey)
      if filled > 0 then ui.fill(term, 4, 6, filled, 1, colours.green) end
      centre(8, math.floor(100 * stepNumber / #STEPS) .. "%", colours.grey, colours.white)
    end
  end

  local function wait(seconds)
    local timer = os.startTimer(seconds)
    while true do
      local event, id = os.pullEvent()
      if event == "term_resize" then
        drawPhase()
      elseif event == "timer" and id == timer then
        return
      end
    end
  end

  -- Act one: the helpful utility.
  phase = "intro"
  drawPhase()

  while true do
    local event, key = os.pullEvent()
    if event == "term_resize" then
      drawPhase()
    elseif event == "key" and key == keys.enter then
      break
    elseif event == "key" and key == keys.backspace then
      return
    end
  end

  for index, step in ipairs(STEPS) do
    phase = step
    stepNumber = index
    term.setBackgroundColour(colours.white)
    term.clear()
    ui.row(term, 1, 1, width, " FreeRAM.exe", colours.white, colours.blue)
    centre(4, step, colours.black, colours.white)

    local bar = width - 6
    local filled = math.floor(bar * index / #STEPS + 0.5)
    ui.fill(term, 4, 6, bar, 1, colours.lightGrey)
    if filled > 0 then ui.fill(term, 4, 6, filled, 1, colours.green) end
    centre(8, math.floor(100 * index / #STEPS) .. "%", colours.grey, colours.white)

    sound.note("bit", 1, 10 + index)
    wait(0.6)
  end

  -- Act two.
  phase, stepNumber = "0 MB freed.", 0
  term.setBackgroundColour(colours.white)
  term.clear()
  ui.row(term, 1, 1, width, " FreeRAM.exe", colours.white, colours.blue)
  centre(4, "0 MB freed.", colours.black, colours.white)
  wait(1)

  centre(6, "just kidding", colours.grey, colours.white)
  phase = "just kidding"
  wait(1.2)

  infection.infect()
  ctx.notify("FreeRAM.exe: thanks for installing :)")

  for round = 1, 12 do
    phase = "corrupt"
    term.setBackgroundColour(colours.black)
    term.clear()
    for _ = 1, 30 do
      term.setCursorPos(math.random(1, width), math.random(1, height))
      term.setBackgroundColour(({ colours.red, colours.green, colours.black })[math.random(1, 3)])
      term.setTextColour(colours.white)
      term.write(({ "#", "%", "?", "0", "1", "!" })[math.random(1, 6)])
    end
    centre(math.floor(height / 2), " YOUR PC IS NOW CORRUPTED ", colours.white, colours.red)
    sound.note("bit", 1, math.random(0, 8))
    wait(0.12)
  end

  phase = "final"
  term.setBackgroundColour(colours.black)
  term.clear()
  centre(math.floor(height / 2) - 1, "haha", colours.red, colours.black)
  centre(math.floor(height / 2) + 1, "get Zare's Antivirus", colours.lightGrey, colours.black)
  ui.row(term, 1, height, width, " closing this will not help",
    colours.red, colours.black)

  while true do
    local event = os.pullEvent()
    if event == "term_resize" then
      drawPhase()
    elseif event == "key" then
      break
    end
  end
end

return app
