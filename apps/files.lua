--[[ Files - browse, open, create and delete.

  Written against the Slate ui helpers rather than wrapping a CraftOS program,
  because this is the app that has to feel like part of the OS: it is how you
  get to everything else.
]]

local use = ...
local ui = use("system/ui")
local theme = use("system/theme")
local verity = use("system/verity")

local app = {}

local function humanSize(bytes)
  if bytes < 1024 then return bytes .. "B" end
  return string.format("%.1fK", bytes / 1024)
end

local function readDir(dir)
  local entries = {}
  if dir ~= "/" and dir ~= "" then
    entries[#entries + 1] = { name = "..", path = fs.getDir(dir), isDir = true, up = true }
  end

  local ok, names = pcall(fs.list, dir)
  if not ok then return entries, tostring(names) end

  local folders, files = {}, {}
  for _, name in ipairs(names) do
    local path = fs.combine(dir, name)
    local entry = { name = name, path = path, isDir = fs.isDir(path) }
    if entry.isDir then
      folders[#folders + 1] = entry
    else
      local sized, size = pcall(fs.getSize, path)
      entry.size = sized and size or 0
      files[#files + 1] = entry
    end
  end

  local byName = function(a, b) return a.name:lower() < b.name:lower() end
  table.sort(folders, byName)
  table.sort(files, byName)

  for _, entry in ipairs(folders) do entries[#entries + 1] = entry end
  for _, entry in ipairs(files) do entries[#entries + 1] = entry end
  return entries
end

local function printFile(entry)
  local printer = peripheral.find and peripheral.find("printer")
  if not printer then return false, "No printer attached" end

  local handle, err = fs.open(entry.path, "r")
  if not handle then return false, tostring(err or "Could not open file") end
  local ok, contents = pcall(handle.readAll)
  handle.close()
  if not ok then return false, tostring(contents) end

  contents = tostring(contents):gsub("\r\n", "\n"):gsub("\r", "\n")
    :gsub("[^\n\t -~]", "?")
  if not printer.newPage() then return false, "Printer needs paper and ink" end
  local width, height = printer.getPageSize()
  local lines = ui.wrap(contents, width)
  if #lines == 0 then lines = { "" } end
  local pageCount = math.ceil(#lines / height)

  for page = 1, pageCount do
    if page > 1 and not printer.newPage() then
      return false, "Printer needs paper and ink"
    end
    printer.setPageTitle(entry.name:sub(1, 16))
    local first = (page - 1) * height + 1
    local last = math.min(#lines, first + height - 1)
    for index = first, last do
      printer.setCursorPos(1, index - first + 1)
      printer.write(lines[index])
    end
    if not printer.endPage() then return false, "Printer output tray is full" end
  end

  return true, ("Printed %d page%s"):format(pageCount, pageCount == 1 and "" or "s")
end

--------------------------------------------------------------------------
-- modal helpers
--------------------------------------------------------------------------

local function box(title, height)
  local w, h = term.getSize()
  local width = w - 4
  local x, y = 3, math.max(1, math.floor((h - height) / 2))
  ui.fill(term, x, y, width, height, theme.colour.muted)
  ui.row(term, x, y, width, " " .. title, theme.colour.accentText, theme.colour.accent)
  return x, y, width
end

local function notice(title, message)
  local x, y, width = box(title, 5)
  ui.text(term, x + 1, y + 2, ui.clip(message, width - 2), colours.black, theme.colour.muted)
  ui.text(term, x + 1, y + 4, "Any key to continue", theme.colour.mutedText, theme.colour.muted)
  os.pullEvent("key")
end

local function confirm(title, message)
  local x, y, width = box(title, 5)
  ui.text(term, x + 1, y + 2, ui.clip(message, width - 2), colours.black, theme.colour.muted)
  ui.text(term, x + 1, y + 4, "Y = yes, any other key = no", theme.colour.mutedText, theme.colour.muted)
  local _, key = os.pullEvent("key")
  return key == keys.y
end

local function prompt(title, label)
  local x, y, width = box(title, 5)
  ui.text(term, x + 1, y + 2, label, colours.black, theme.colour.muted)
  ui.fill(term, x + 1, y + 3, width - 2, 1, colours.white)
  term.setCursorPos(x + 1, y + 3)
  term.setBackgroundColour(colours.white)
  term.setTextColour(colours.black)
  local value = read()
  return value
end

--------------------------------------------------------------------------

function app.run(ctx, startDir)
  local dir = startDir or "/"
  local entries, listError = readDir(dir)
  local index, scroll = 1, 0

  local function refresh()
    entries, listError = readDir(dir)
    if index > #entries then index = math.max(1, #entries) end
    scroll = 0
  end

  local function enter(entry)
    if not entry then return end
    if entry.isDir then
      dir = entry.path
      index, scroll = 1, 0
      entries, listError = readDir(dir)
      ctx.setTitle("Files " .. ui.clip(dir, 18))
    else
      ctx.launch("editor", { entry.path })
    end
  end

  local function draw()
    local w, h = term.getSize()
    local rows = h - 2
    local listTop = 2

    if index < scroll + 1 then scroll = index - 1 end
    if index > scroll + rows then scroll = index - rows end
    if scroll < 0 then scroll = 0 end

    term.setBackgroundColour(theme.colour.window)
    term.clear()

    -- Free space sits in the path bar, right aligned: it is the number you
    -- want when you are deciding whether to delete something.
    local free = ""
    local okFree, bytes = pcall(fs.getFreeSpace, "/")
    if okFree and type(bytes) == "number" then
      free = bytes >= 1048576 and string.format("%.1fM free", bytes / 1048576)
        or string.format("%dK free", math.floor(bytes / 1024))
    end
    local room = math.max(1, w - #free - 3)
    ui.row(term, 1, 1, w, " " .. ui.pad(ui.clip(dir, room), room) .. " " .. free,
      theme.colour.accentText, theme.colour.accent)

    if listError then
      ui.text(term, 2, 3, ui.clip("Cannot read: " .. listError, w - 2),
        theme.colour.danger, theme.colour.window)
    end

    for row = 1, rows do
      local entryIndex = scroll + row
      local entry = entries[entryIndex]
      local y = listTop + row - 1
      if entry then
        local on = (entryIndex == index)
        local bg = on and theme.colour.accent or theme.colour.window
        local fg = on and theme.colour.accentText
          or (entry.isDir and theme.colour.accent or theme.colour.windowText)

        local tag = entry.isDir and "/" or " "
        local right = entry.isDir and "" or humanSize(entry.size or 0)
        local nameWidth = w - 3 - #right
        local line = tag .. ui.pad(ui.clip(entry.name, nameWidth), nameWidth) .. " " .. right
        ui.row(term, 1, y, w - 1, line, fg, bg)
      end
    end

    ui.scrollbar(term, w, listTop, rows, #entries, scroll,
      theme.colour.muted, theme.colour.accent)

    ui.row(term, 1, h, w, " [Enter]open [P]rint [N]ew [F]older [Del]ete",
      theme.colour.mutedText, theme.colour.muted)
  end

  ctx.setTitle("Files " .. ui.clip(dir, 18))
  draw()

  -- The disk changes underneath this window - a download finishing, another
  -- app writing a file - so the listing refreshes itself rather than showing
  -- a stale directory until someone presses R.
  local ticker = os.startTimer(5)

  while true do
    local event = { os.pullEvent() }
    local name = event[1]
    local w, h = term.getSize()
    local rows = h - 2

    if name == "timer" and event[2] == ticker then
      ticker = os.startTimer(5)
      local before = #entries
      local keep = entries[index] and entries[index].name
      entries, listError = readDir(dir)
      -- Keep the selection on the same file when the list shifts under it.
      if keep and #entries ~= before then
        for position, entry in ipairs(entries) do
          if entry.name == keep then index = position break end
        end
      end
      if index > #entries then index = math.max(1, #entries) end
      draw()

    elseif name == "key" then
      local key = event[2]
      if key == keys.down then index = math.min(#entries, index + 1)
      elseif key == keys.up then index = math.max(1, index - 1)
      elseif key == keys.pageDown then index = math.min(#entries, index + rows)
      elseif key == keys.pageUp then index = math.max(1, index - rows)
      elseif key == keys.home then index = 1
      elseif key == keys["end"] then index = #entries
      elseif key == keys.enter then enter(entries[index])
      elseif key == keys.backspace then
        if dir ~= "/" then enter({ path = fs.getDir(dir), isDir = true }) end
      elseif key == keys.r then refresh()

      elseif key == keys.p then
        local entry = entries[index]
        if entry and not entry.isDir and not entry.up then
          local ok, result = printFile(entry)
          notice(ok and "Print complete" or "Print failed", result)
        end

      elseif key == keys.delete then
        local entry = entries[index]
        if entry and not entry.up then
          if verity.isProtected(entry.path) then
            -- Refused first, noticed second. The refusal is the real part.
            local woke, _, why = verity.report("deleting " .. entry.name)
            notice("Not allowed", entry.name .. " is part of the OS")
            if woke then os.queueEvent("slate_verity", why) end
          elseif fs.isReadOnly(entry.path) then
            notice("Cannot delete", entry.name .. " is read-only")
          elseif confirm("Delete", "Delete " .. ui.clip(entry.name, 20) .. "?") then
            local ok, err = pcall(fs.delete, entry.path)
            if not ok then notice("Delete failed", tostring(err)) end
            refresh()
          end
        end

      elseif key == keys.n then
        local value = prompt("New file", "Name:")
        if value and value ~= "" then
          local path = fs.combine(dir, value)
          if fs.exists(path) then
            notice("Exists", value .. " is already there")
          else
            local handle, err = fs.open(path, "w")
            if handle then handle.close() else notice("Failed", tostring(err)) end
            refresh()
          end
        end

      elseif key == keys.f then
        local value = prompt("New folder", "Name:")
        if value and value ~= "" then
          local ok, err = pcall(fs.makeDir, fs.combine(dir, value))
          if not ok then notice("Failed", tostring(err)) end
          refresh()
        end
      end
      draw()

    elseif name == "mouse_click" then
      local my = event[4]
      local clicked = scroll + (my - 1)
      if my >= 2 and entries[clicked] then
        -- Click to select, click the selected row again to open it. Reliable
        -- without trying to time a double click.
        if clicked == index then enter(entries[clicked]) else index = clicked end
      end
      draw()

    elseif name == "mouse_scroll" then
      index = math.max(1, math.min(#entries, index + event[2]))
      draw()

    elseif name == "term_resize" then
      draw()
    end
  end
end

return app
