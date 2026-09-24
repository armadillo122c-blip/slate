--[[ BitAI - chat with Gemini from inside Minecraft.

  Adapted from Armadillo122's ComputerCraft AI chat script. The request shape,
  system prompt and history handling are kept; what changed is everything that
  assumed it owned a full terminal:

    * the transcript is a scrollable buffer, not print() into a 15-row window
    * the API key lives in CC's settings rather than a file at /ai_config,
      so it survives a Slate reinstall and is not sitting in a plain path
    * state is local to run(), so a second window would not share a history
    * failures are shown in the transcript instead of scrolling away

  You supply your own API key - Slate ships none. It is stored in plain text
  in CC's settings, same as every other CC setting, and is only ever sent to
  Google's endpoint.
]]

local use = ...
local ui = use("system/ui")
local theme = use("system/theme")

local app = {}

local KEY_SETTING = "slate.bitai.key"
local MODEL_SETTING = "slate.bitai.model"
local DEFAULT_MODEL = "gemini-3.8-flash"
local MAX_HISTORY = 20

local SYSTEM_PROMPT = [[
You are an AI assistant running inside a ComputerCraft computer in Minecraft.
Answer clearly and helpfully.
Keep responses reasonably concise unless the user asks for detail.
Use plain text because the response will be displayed in a terminal.
]]

local function setting(name, fallback)
  local ok, value = pcall(settings.get, name)
  if ok and type(value) == "string" and value ~= "" then return value end
  return fallback
end

local function saveSetting(name, value)
  pcall(function()
    if value == nil or value == "" then
      settings.unset(name)
    else
      settings.set(name, value)
    end
    settings.save()
  end)
end

local function endpoint(model)
  return "https://generativelanguage.googleapis.com/v1beta/models/"
    .. model .. ":generateContent"
end

--------------------------------------------------------------------------

function app.run(ctx)
  local apiKey = setting(KEY_SETTING, nil)
  local model = setting(MODEL_SETTING, DEFAULT_MODEL)
  local history = {}
  local transcript = {}          -- { role, text }
  local scroll = 0
  local busy = false
  local typed = {}

  local function say(role, text)
    transcript[#transcript + 1] = { role = role, text = tostring(text) }
    scroll = 0                   -- 0 means pinned to the newest line
  end

  local function remember(role, text)
    history[#history + 1] = { role = role, parts = { { text = text } } }
    while #history > MAX_HISTORY do table.remove(history, 1) end
  end

  ------------------------------------------------------------------
  -- rendering
  ------------------------------------------------------------------

  -- Flattens the transcript into display lines once, so scrolling is just an
  -- offset rather than a re-wrap on every keypress.
  local function lines(width)
    local out = {}
    for _, entry in ipairs(transcript) do
      local prefix = entry.role == "you" and "you  " or
        (entry.role == "ai" and "ai   " or "")
      local colour = entry.role == "you" and theme.colour.accent
        or (entry.role == "error" and theme.colour.danger or theme.colour.windowText)
      local body = ui.wrap(prefix .. entry.text, width)
      for _, line in ipairs(body) do
        out[#out + 1] = { text = line, colour = colour }
      end
      out[#out + 1] = { text = "", colour = colour }
    end
    return out
  end

  local function draw()
    local width, height = term.getSize()
    term.setBackgroundColour(theme.colour.window)
    term.clear()
    ui.row(term, 1, 1, width, " BitAI  " .. ui.clip(model, width - 9),
      theme.colour.accentText, theme.colour.accent)

    local body = height - 3
    local all = lines(width - 2)
    local maxScroll = math.max(0, #all - body)
    scroll = math.min(scroll, maxScroll)
    local first = math.max(1, #all - body + 1 - scroll)

    for row = 0, body - 1 do
      local line = all[first + row]
      if line then
        ui.text(term, 2, 2 + row, line.text, line.colour, theme.colour.window)
      end
    end
    ui.scrollbar(term, width, 2, body, #all, math.max(0, #all - body - scroll),
      theme.colour.muted, theme.colour.accent)

    if busy then
      ui.row(term, 1, height - 1, width, " thinking...",
        theme.colour.accentText, theme.colour.accent)
    else
      ui.fill(term, 1, height - 1, width, 1, colours.white)
      ui.text(term, 1, height - 1, " > ", colours.black, colours.white)
    end

    ui.row(term, 1, height, width,
      apiKey and " /clear  /key  /model  PgUp scrolls" or " /key to add your API key",
      theme.colour.mutedText, theme.colour.muted)
  end

  ------------------------------------------------------------------
  -- the API
  ------------------------------------------------------------------

  local function ask(message)
    if not http then return nil, "HTTP is disabled in computercraft-server.toml" end
    if not apiKey then return nil, "No API key. Type /key to add one." end

    remember("user", message)

    local body = textutils.serialiseJSON({
      systemInstruction = { parts = { { text = SYSTEM_PROMPT } } },
      contents = history,
      generationConfig = { thinkingConfig = { thinkingLevel = "low" } },
    })

    local ok, response = pcall(http.post, endpoint(model), body, {
      ["Content-Type"] = "application/json",
      ["x-goog-api-key"] = apiKey,
    })

    -- Every failure below drops the question from history, so a retry does
    -- not resend a conversation the model never saw.
    if not ok or not response then
      table.remove(history)
      return nil, "Could not reach the Gemini API."
    end

    local status = response.getResponseCode()
    local raw = response.readAll()
    response.close()

    if status < 200 or status >= 300 then
      table.remove(history)
      local detail = "HTTP " .. tostring(status)
      local parsedOk, parsed = pcall(textutils.unserialiseJSON, raw)
      if parsedOk and parsed and parsed.error and parsed.error.message then
        detail = detail .. ": " .. parsed.error.message
      end
      return nil, detail
    end

    local parsedOk, data = pcall(textutils.unserialiseJSON, raw)
    if not parsedOk or type(data) ~= "table" then
      table.remove(history)
      return nil, "Gemini returned invalid JSON."
    end

    local candidate = data.candidates and data.candidates[1]
    local text = candidate and candidate.content and candidate.content.parts
      and candidate.content.parts[1] and candidate.content.parts[1].text

    if not text then
      table.remove(history)
      return nil, "Gemini returned no text."
    end

    remember("model", text)
    return text
  end

  ------------------------------------------------------------------
  -- prompts
  ------------------------------------------------------------------

  local function askKey()
    local function drawDialog()
      local width = term.getSize()
      ui.panel(term, 2, 3, width - 2, 7, theme.colour.muted, theme.colour.accent)
      ui.text(term, 4, 4, "Gemini API key", colours.black, theme.colour.muted)
      ui.text(term, 4, 5, "from Google AI Studio", theme.colour.mutedText, theme.colour.muted)
      ui.fill(term, 4, 7, width - 6, 1, colours.white)
    end
    drawDialog()
    -- Masked: the key should never appear on a screen someone might be
    -- watching, or in a remote session.
    local entered = ui.inputLine(term, 4, 7, "", { mask = "*", onResize = drawDialog })
    if entered and entered ~= "" then
      apiKey = entered
      saveSetting(KEY_SETTING, entered)
      say("ai", "Key saved. Ask me something.")
    end
  end

  local function askModel()
    local function drawDialog()
      local width = term.getSize()
      ui.panel(term, 2, 3, width - 2, 6, theme.colour.muted, theme.colour.accent)
      ui.text(term, 4, 4, "Model name:", colours.black, theme.colour.muted)
      ui.fill(term, 4, 6, width - 6, 1, colours.white)
    end
    drawDialog()
    local entered = ui.inputLine(term, 4, 6, model, { onResize = drawDialog })
    if entered and entered ~= "" then
      model = entered
      saveSetting(MODEL_SETTING, entered)
      say("ai", "Model set to " .. entered)
    end
  end

  ------------------------------------------------------------------

  say("ai", "BitAI ready. " .. (apiKey and "Ask me something."
    or "Type /key to add your Gemini API key."))
  draw()

  while true do
    local input = ui.inputLine(term, 4, function()
      local _, height = term.getSize()
      return height - 1
    end, "", { history = typed, onResize = draw })
    if input == nil then return end

    if input == "" then
      draw()

    elseif input == "/exit" then
      return

    elseif input == "/clear" then
      history, transcript, scroll = {}, {}, 0
      say("ai", "Conversation cleared.")
      draw()

    elseif input == "/key" then
      askKey()
      draw()

    elseif input == "/model" then
      askModel()
      draw()

    else
      typed[#typed + 1] = input
      say("you", input)
      busy = true
      draw()

      -- http.post yields, so the rest of the desktop keeps running while
      -- this waits for a reply.
      local answer, err = ask(input)
      busy = false

      if answer then
        say("ai", answer)
      else
        say("error", err or "Something went wrong.")
      end
      draw()
    end
  end
end

return app
