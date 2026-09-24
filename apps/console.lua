--[[ Console - a Lua prompt with Slate's own modules in scope.

  Developer mode only. Unlike the Terminal app (which runs the CraftOS shell),
  this evaluates Lua in an environment where `kernel`, `catalog`, `theme`,
  `ui`, `notify` and `use` are already available, so the running desktop can
  be poked at directly:

      kernel.list()[1].title
      theme.setAccent(3)
      catalog.all()[1].id

  An expression prints its value; a statement just runs.
]]

local use = ...
local ui = use("system/ui")
local theme = use("system/theme")
local verity = use("system/verity")

local app = {}

local function show(value, seen)
  local kind = type(value)
  if kind == "string" then return string.format("%q", value) end
  if kind == "table" then
    seen = seen or {}
    if seen[value] then return "<cycle>" end
    seen[value] = true
    local parts, count = {}, 0
    for k, v in pairs(value) do
      count = count + 1
      if count > 8 then parts[#parts + 1] = "..." break end
      parts[#parts + 1] = tostring(k) .. "=" ..
        (type(v) == "table" and "<table>" or tostring(v))
    end
    return "{" .. table.concat(parts, ", ") .. "}"
  end
  return tostring(value)
end

function app.run(ctx)
  local history = {}
  local typed = {}

  -- Slate's own modules, plus the normal globals.
  local env = setmetatable({
    use = use,
    ui = ui,
    theme = theme,
    kernel = use("system/kernel"),
    catalog = use("system/catalog"),
    notify = use("system/notify"),
    dev = use("system/dev"),
    compat = use("system/compat"),
    ctx = ctx,
  }, { __index = _ENV or _G })

  local function record(text, ok)
    history[#history + 1] = { text = text, ok = ok }
    if #history > 80 then table.remove(history, 1) end
  end

  local function draw()
    local width, height = term.getSize()
    term.setBackgroundColour(colours.black)
    term.clear()
    ui.row(term, 1, 1, width, " Console   dev", colours.white, theme.colour.accent)

    local body = height - 3
    local first = math.max(1, #history - body + 1)
    local y = 2
    for index = first, #history do
      local entry = history[index]
      for _, line in ipairs(ui.wrap(entry.text, width - 2)) do
        if y > height - 2 then break end
        ui.text(term, 2, y, line,
          entry.ok and colours.white or colours.red, colours.black)
        y = y + 1
      end
    end

    ui.text(term, 1, height - 1, " > ", colours.lime, colours.black)
    ui.row(term, 1, height, width, " Lua with kernel, catalog, theme, ui in scope",
      theme.colour.mutedText, theme.colour.muted)
  end

  ctx.onResize(draw)

  local function run(source)
    -- Reading stored tokens or deleting the OS from a prompt is not a
    -- mistake anybody makes by accident.
    local why = verity.inspect(source)
    if why then
      record("refused: " .. why, false)
      local woke = verity.report(why)
      if woke then os.queueEvent("slate_verity", why) end
      return
    end
    -- Try it as an expression first so `1+1` prints 2 rather than erroring.
    local chunk, err = load("return " .. source, "=console", "t", env)
    if not chunk then
      chunk, err = load(source, "=console", "t", env)
    end
    if not chunk then
      record(tostring(err), false)
      return
    end

    local results = table.pack(pcall(chunk))
    if not results[1] then
      record(tostring(results[2]), false)
      return
    end
    if results.n <= 1 then
      record("ok", true)
      return
    end
    local parts = {}
    for index = 2, results.n do parts[#parts + 1] = show(results[index]) end
    record(table.concat(parts, ", "), true)
  end

  draw()

  while true do
    local width, height = term.getSize()
    term.setCursorPos(4, height - 1)
    term.setBackgroundColour(colours.black)
    term.setTextColour(colours.white)

    local source = read(nil, typed)
    if source == nil then return end
    if source ~= "" then
      typed[#typed + 1] = source
      record("> " .. source, true)
      run(source)
    end
    draw()
  end
end

return app
