--[[ Messenger - the window for the Slate Messenger background service.

  Networking, storage, unread counts, and notifications belong to
  system/messenger.lua. This app is only the user interface, so closing the
  window never stops Messenger and opening it shows messages received while
  it was closed.
]]

local use = ...
local ui = use("system/ui")
local theme = use("system/theme")
local messenger = use("system/messenger")

local app = {}

local BROADCAST = "all"

local function panel(title, lines)
  local function draw()
    local width, height = term.getSize()
    term.setBackgroundColour(theme.colour.window)
    term.clear()
    ui.row(term, 1, 1, width, " " .. title, colours.white, theme.colour.danger)
    for index, line in ipairs(lines) do
      if index + 2 >= height then break end
      ui.text(term, 2, index + 2, ui.clip(line, width - 2),
        theme.colour.windowText, theme.colour.window)
    end
    ui.row(term, 1, height, width, " Any key to close",
      theme.colour.mutedText, theme.colour.muted)
  end
  draw()
  while true do
    local event = os.pullEvent()
    if event == "term_resize" then draw()
    elseif event == "key" then return end
  end
end

function app.run(ctx)
  local state = "peers"
  local target = nil
  local index = 1
  local scroll = 0
  local chatScroll = 0
  local history = {}

  local function peers()
    return messenger.peers()
  end

  local function retitle()
    local unread = messenger.totalUnread()
    ctx.setTitle(unread > 0 and ("Messenger (" .. unread .. ")") or "Messenger")
  end

  local function drawPeers()
    local width, height = term.getSize()
    local list = peers()
    local rows = height - 2

    index = math.max(1, math.min(#list, index))
    if index < scroll + 1 then scroll = index - 1 end
    if index > scroll + rows then scroll = index - rows end
    scroll = math.max(0, scroll)

    term.setBackgroundColour(theme.colour.window)
    term.clear()
    ui.row(term, 1, 1, width,
      " " .. ui.clip(messenger.info().name .. "  #" .. messenger.info().id, width - 2),
      theme.colour.accentText, theme.colour.accent)

    if #list == 1 then
      ui.text(term, 2, 3, "No other computers yet.",
        theme.colour.mutedText, theme.colour.window)
      ui.text(term, 2, 5, "Other computers need Slate Messenger",
        theme.colour.mutedText, theme.colour.window)
      ui.text(term, 2, 6, "running in the background too.",
        theme.colour.mutedText, theme.colour.window)
      ui.text(term, 2, 8, "You can still message Everyone.",
        theme.colour.mutedText, theme.colour.window)
    end

    for row = 1, rows do
      local entry = list[scroll + row]
      if entry then
        local on = (scroll + row == index)
        local bg = on and theme.colour.accent or theme.colour.window
        local fg = on and theme.colour.accentText or theme.colour.windowText
        local tag = entry.id == BROADCAST and "*" or ("#" .. tostring(entry.id))
        local unread = entry.unread > 0 and ("(" .. entry.unread .. ")") or ""
        local room = math.max(1, width - #tag - #unread - 4)
        ui.row(term, 1, row + 1, width,
          " " .. tag .. " " .. ui.pad(ui.clip(entry.name, room), room) .. " " .. unread,
          fg, bg)
      end
    end

    ui.scrollbar(term, width, 2, rows, #list, scroll,
      theme.colour.muted, theme.colour.accent)

    ui.row(term, 1, height, width,
      " [Enter] open  [R] find  [D] diagnostics",
      theme.colour.mutedText, theme.colour.muted)
  end

  local function chatLines(width)
    local out = {}
    for _, entry in ipairs(messenger.messages(target)) do
      local prefix = entry.mine and "you" or entry.who
      for _, line in ipairs(ui.wrap(prefix .. ": " .. entry.text, width)) do
        out[#out + 1] = { text = line, mine = entry.mine == true }
      end
    end
    return out
  end

  local function chatName()
    if target == BROADCAST then return "Everyone" end
    for _, peer in ipairs(peers()) do
      if tostring(peer.id) == tostring(target) then return peer.name end
    end
    return "computer " .. tostring(target)
  end

  local function printChat()
    local printer = peripheral.find and peripheral.find("printer")
    if not printer then return false, "No printer attached" end

    local messages = messenger.messages(target)
    local body = {}
    for index, entry in ipairs(messages) do
      if index > 1 then body[#body + 1] = "" end
      local who = entry.mine and "You" or tostring(entry.who or "Unknown")
      body[#body + 1] = ("[%s] %s"):format(tostring(entry.time or "--:--"), who)
      local content = tostring(entry.text or ""):gsub("\r\n", "\n"):gsub("\r", "\n")
        :gsub("[^\n\t -~]", "?")
      for paragraph in (content .. "\n"):gmatch("([^\n]*)\n") do
        body[#body + 1] = "  " .. paragraph
      end
    end
    if #body == 0 then body[1] = "(No messages yet.)" end

    local ok, success, result = pcall(function()
      if not printer.newPage() then return false, "Printer needs paper and ink" end
      local width, height = printer.getPageSize()
      local wrapped = {}
      for _, line in ipairs(body) do
        if line == "" then
          wrapped[#wrapped + 1] = ""
        else
          for _, piece in ipairs(ui.wrap(line, width)) do
            wrapped[#wrapped + 1] = piece
          end
        end
      end

      local name = chatName()
      local rows = math.max(1, height - 1)
      local pages = math.max(1, math.ceil(#wrapped / rows))
      for page = 1, pages do
        if page > 1 and not printer.newPage() then
          return false, "Printer needs paper and ink"
        end
        printer.setPageTitle(("Messenger - %s"):format(name):sub(1, 16))
        printer.setCursorPos(1, 1)
        printer.write(("Messenger: %s (%d/%d)"):format(name, page, pages):sub(1, width))
        local first = (page - 1) * rows + 1
        local last = math.min(#wrapped, first + rows - 1)
        for index = first, last do
          printer.setCursorPos(1, index - first + 2)
          printer.write(wrapped[index])
        end
        if not printer.endPage() then return false, "Printer output tray is full" end
      end
      return true, ("Printed %d page%s"):format(pages, pages == 1 and "" or "s")
    end)

    if not ok then return false, tostring(success) end
    return success, result
  end

  local function drawChat(keepCursor)
    local width, height = term.getSize()
    local cx, cy = term.getCursorPos()
    local fg, bg = term.getTextColour(), term.getBackgroundColour()

    local name = chatName()

    local rows = math.max(1, height - 3)
    local lines = chatLines(width - 2)
    local maxScroll = math.max(0, #lines - rows)
    chatScroll = math.max(0, math.min(maxScroll, chatScroll))

    term.setBackgroundColour(theme.colour.window)
    term.clear()
    ui.row(term, 1, 1, width, " < " .. ui.clip(name, width - 4),
      theme.colour.accentText, theme.colour.accent)

    local total = #lines
    local first = math.max(1, total - rows + 1 - chatScroll)
    local count = math.min(rows, total - first + 1)

    for i = 1, count do
      local line = lines[first + i - 1]
      ui.text(term, 2, 1 + (rows - count) + i, line.text,
        line.mine and theme.colour.accent or theme.colour.windowText,
        theme.colour.window)
    end

    ui.row(term, 1, height - 1, width, " > ",
      theme.colour.windowText, theme.colour.muted)
    ui.row(term, 1, height, width, " [Enter] write  [P]rint  [Backspace] back",
      theme.colour.mutedText, theme.colour.muted)

    if keepCursor then
      term.setTextColour(fg)
      term.setBackgroundColour(bg)
      term.setCursorPos(cx, cy)
    end
  end

  local function drawDiagnostics()
    local width, height = term.getSize()
    local info = messenger.info()

    term.setBackgroundColour(theme.colour.window)
    term.clear()
    ui.row(term, 1, 1, width, " Diagnostics",
      theme.colour.accentText, theme.colour.accent)

    local lines = {
      { "modem", tostring(info.modem or "none") },
      { "wireless", tostring(info.wireless) },
      { "rednet open", tostring(info.open) },
      { "my id", "#" .. tostring(info.id) },
      { "my name", tostring(info.name) },
      { "protocol", tostring(info.protocol) },
      { "modem msgs", tostring(info.modemMessages) },
      { "rednet msgs", tostring(info.rednetMessages) },
      { "messages", tostring(info.messages) },
      { "sent", tostring(info.sent) },
      { "last from", tostring(info.lastFrom) },
      { "peers", tostring(info.peers) },
      { "unread", tostring(messenger.totalUnread()) },
    }

    local y = 2
    for _, row in ipairs(lines) do
      if y > height - 1 then break end
      ui.text(term, 2, y, ui.pad(row[1], 14),
        theme.colour.mutedText, theme.colour.window)
      ui.text(term, 16, y, ui.clip(row[2], width - 17),
        theme.colour.windowText, theme.colour.window)
      y = y + 1
    end

    ui.row(term, 1, height, width, " [P]ing   [Backspace] back",
      theme.colour.mutedText, theme.colour.muted)
  end

  local function draw()
    retitle()
    if state == "peers" then drawPeers()
    elseif state == "chat" then drawChat(false)
    else drawDiagnostics() end
  end

  local function select(targetId)
    target = targetId
    chatScroll = 0
    messenger.setActive(target)
    state = "chat"
    draw()
  end

  local function compose()
    local _, height = term.getSize()
    local typed

    parallel.waitForAny(
      function()
        term.setCursorPos(4, height - 1)
        term.setBackgroundColour(theme.colour.muted)
        term.setTextColour(colours.black)
        typed = read(nil, history)
      end,
      function()
        while true do
          local event = { os.pullEvent() }
          if event[1] == "messenger_update" then
            drawChat(true)
          elseif event[1] == "term_resize" then
            drawChat(true)
          end
        end
      end
    )

    return typed
  end

  ctx.onClose(function()
    messenger.setActive(nil)
  end)

  retitle()
  draw()

  while true do
    local event = { os.pullEvent() }
    local name = event[1]

    if name == "messenger_update" then
      if state == "chat" then
        drawChat(false)
      else
        drawPeers()
      end

    elseif name == "key" then
      local key = event[2]

      if state == "diagnostics" then
        if key == keys.backspace then state = "peers"
        elseif key == keys.p then
          messenger.announce()
        end
        draw()

      elseif state == "peers" then
        local list = peers()
        if key == keys.down then
          index = math.min(#list, index + 1)
          draw()
        elseif key == keys.up then
          index = math.max(1, index - 1)
          draw()
        elseif key == keys.r then
          messenger.announce()
          draw()
        elseif key == keys.d then
          state = "diagnostics"
          draw()
        elseif key == keys.enter then
          local entry = list[index]
          if entry then select(entry.id) end
        end

      else
        if key == keys.backspace then
          messenger.setActive(nil)
          state = "peers"
          draw()
        elseif key == keys.up then
          chatScroll = chatScroll + 1
          drawChat(false)
        elseif key == keys.down then
          chatScroll = math.max(0, chatScroll - 1)
          drawChat(false)
        elseif key == keys.p then
          local ok, result = printChat()
          panel(ok and "Print complete" or "Print failed", { result })
          draw()
        elseif key == keys.enter then
          local text = compose()
          if text and text ~= "" then
            local ok, err = messenger.send(target, text)
            if not ok then
              ctx.setTitle("Messenger")
            end
          end
          chatScroll = 0
          draw()
        end
      end

    elseif name == "mouse_click" then
      local my = event[4]
      if state == "peers" then
        local list = peers()
        local clicked = scroll + my - 1
        if list[clicked] then select(list[clicked].id) end
      elseif state == "diagnostics" then
        if my == 1 then state = "peers"; draw() end
      else
        local _, height = term.getSize()
        if my == 1 then
          messenger.setActive(nil)
          state = "peers"
          draw()
        elseif my == height - 1 then
          local text = compose()
          if text and text ~= "" then messenger.send(target, text) end
          chatScroll = 0
          draw()
        end
      end

    elseif name == "mouse_scroll" then
      if state == "peers" then
        local list = peers()
        index = math.max(1, math.min(#list, index + event[2]))
        draw()
      else
        chatScroll = math.max(0, chatScroll - event[2])
        drawChat(false)
      end

    elseif name == "term_resize" then
      draw()
    end
  end
end

return app
