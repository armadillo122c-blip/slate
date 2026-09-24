--[[ Paint - draw pictures, saved as .nfp.

  .nfp is CraftOS's own image format (one hex colour character per pixel), so
  anything drawn here can be shown by paintutils.drawImage in your own
  programs, and existing .nfp files open fine.
]]

local use = ...
local ui = use("system/ui")
local theme = use("system/theme")

local app = {}

local PALETTE = {
  colours.white, colours.orange, colours.magenta, colours.lightBlue,
  colours.yellow, colours.lime, colours.pink, colours.grey,
  colours.lightGrey, colours.cyan, colours.purple, colours.blue,
  colours.brown, colours.green, colours.red, colours.black,
}

local function validColour(c)
  if type(c) ~= "number" or c == 0 then
    return false
  end

  return pcall(colours.toBlit, c)
end

local function normaliseColour(c)
  if type(c) ~= "number" or c == 0 then
    return nil
  end

  if validColour(c) then
    return c
  end

  if c >= 0 and c <= 15 and c == math.floor(c) then
    local converted = 2 ^ c
    if validColour(converted) then
      return converted
    end
  end

  return nil
end

function app.run(ctx, openPath)
  local width, height = term.getSize()
  local canvasH = math.max(1, height - 2)
  local canvasW = math.max(1, width - 3)
  local pixels = {}
  local colour = colours.red
  local path = openPath
  local notice, noticeUntil = nil, 0

  local function safeThemeColour(value, fallback)
    local c = normaliseColour(value)
    return c or fallback
  end

  local windowColour = safeThemeColour(theme.colour.window, colours.black)
  local accentText = safeThemeColour(theme.colour.accentText, colours.white)
  local accent = safeThemeColour(theme.colour.accent, colours.blue)
  local okColour = safeThemeColour(theme.colour.ok, colours.green)
  local mutedText = safeThemeColour(theme.colour.mutedText, colours.lightGrey)
  local muted = safeThemeColour(theme.colour.muted, colours.grey)

  for y = 1, canvasH do
    pixels[y] = {}
  end

  local function say(text)
    notice = tostring(text)
    noticeUntil = os.clock() + 3
  end

  local function load(target)
    if not target:lower():match("%.nfp$") then
      target = target .. ".nfp"
    end
    local ok, image = pcall(paintutils.loadImage, target)
    if not ok or type(image) ~= "table" then
      return false
    end

    for y = 1, canvasH do
      pixels[y] = {}

      local row = image[y]
      if row then
        for x = 1, canvasW do
          pixels[y][x] = normaliseColour(row[x])
        end
      end
    end

    return true
  end

  local function save(target)
    -- Always save as .nfp unless the user already supplied that extension.
    if not target:lower():match("%.nfp$") then
      target = target .. ".nfp"
    end

    local handle, err = fs.open(target, "w")
    if not handle then
      return false, tostring(err)
    end

    local lastRow = 0

    for y = 1, canvasH do
      for x = 1, canvasW do
        if normaliseColour(pixels[y][x]) then
          lastRow = y
          break
        end
      end
    end

    for y = 1, lastRow do
      local line = {}
      local lastCol = 0

      for x = 1, canvasW do
        if normaliseColour(pixels[y][x]) then
          lastCol = x
        end
      end

      for x = 1, lastCol do
        local c = normaliseColour(pixels[y][x])
        line[#line + 1] = c and colours.toBlit(c) or " "
      end

      handle.writeLine(table.concat(line))
    end

    handle.close()
    return true, target
  end

  local function draw()
    term.setBackgroundColour(windowColour)
    term.clear()

    ui.row(
      term,
      1,
      1,
      width,
      " Paint  " .. (path and fs.getName(path) or "untitled"),
      accentText,
      accent
    )

    for y = 1, canvasH do
      for x = 1, canvasW do
        local cell = normaliseColour(pixels[y][x])

        if cell then
          ui.fill(term, x, y + 1, 1, 1, cell)
        end
      end
    end

    for index, entry in ipairs(PALETTE) do
      local y = index + 1

      if y <= height - 1 then
        ui.fill(term, width - 2, y, 3, 1, entry)

        if entry == colour then
          ui.text(
            term,
            width - 1,
            y,
            "o",
            entry == colours.white and colours.black or colours.white,
            entry
          )
        end
      end
    end

    if notice and os.clock() < noticeUntil then
      ui.row(
        term,
        1,
        height,
        width,
        " " .. notice,
        colours.white,
        okColour
      )
    else
      ui.row(
        term,
        1,
        height,
        width,
        " click to paint  [S]ave  [O]pen  [C]lear",
        mutedText,
        muted
      )
    end
  end

  local function prompt(label)
    ui.fill(term, 1, height - 1, width, 1, colours.white)
    ui.text(term, 1, height - 1, label, colours.black, colours.white)

    term.setCursorPos(#label + 1, height - 1)
    term.setBackgroundColour(colours.white)
    term.setTextColour(colours.black)

    return read()
  end

  if path then
    load(path)
  end

  draw()

  while true do
    local event, a, x, y = os.pullEvent()

    if event == "mouse_click" or event == "mouse_drag" then
      if x >= width - 2 then
        local pick = PALETTE[y - 1]

        if pick then
          colour = pick
        end
      elseif y >= 2 and y <= canvasH + 1 and x <= canvasW then
        pixels[y - 1][x] = (a == 2) and nil or colour
      end

      draw()

    elseif event == "key" then
      if a == keys.s then
        local target = path or prompt(" save as: ")

        if target and target ~= "" then
          local ok, result = save(target)

          if ok then
            path = result
            say("Saved as " .. fs.getName(result))
          else
            say("Failed: " .. tostring(result))
          end
        end

      elseif a == keys.o then
        local target = prompt(" open: ")

        if target and target ~= "" then
          if load(target) then
            path = target
            say("Opened")
          else
            say("Could not open")
          end
        end

      elseif a == keys.c then
        for row = 1, canvasH do
          pixels[row] = {}
        end

        say("Cleared")
      end

      draw()

    elseif event == "term_resize" then
      width, height = term.getSize()
      canvasH = math.max(1, height - 2)
      canvasW = math.max(1, width - 3)

      local newPixels = {}

      for y2 = 1, canvasH do
        newPixels[y2] = {}

        if pixels[y2] then
          for x2 = 1, canvasW do
            newPixels[y2][x2] = normaliseColour(pixels[y2][x2])
          end
        end
      end

      pixels = newPixels
      draw()
    end
  end
end

return app
