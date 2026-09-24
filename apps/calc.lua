--[[ Calculator.

  The expression is parsed rather than handed to load(). A tiny recursive
  descent parser is barely more code than building a string and running it,
  and it cannot execute anything: a typo is an error message, not a program.
]]

local use = ...
local ui = use("system/ui")
local theme = use("system/theme")

local app = {}

--------------------------------------------------------------------------
-- parser:  expr = term (('+'|'-') term)*
--          term = power (('*'|'/'|'%') power)*
--          power = unary ('^' power)?
--          unary = '-'? atom
--          atom = number | '(' expr ')' | name '(' expr ')'
--------------------------------------------------------------------------

local FUNCTIONS = {
  sqrt = math.sqrt, abs = math.abs, floor = math.floor, ceil = math.ceil,
  sin = math.sin, cos = math.cos, tan = math.tan, log = math.log,
  min = math.min, max = math.max,
}

local CONSTANTS = { pi = math.pi, e = math.exp(1) }

local function evaluate(source)
  local at = 1

  local function skip()
    while source:sub(at, at):match("%s") do at = at + 1 end
  end

  local function peek()
    skip()
    return source:sub(at, at)
  end

  local expr

  local function atom()
    skip()
    local char = peek()

    if char == "(" then
      at = at + 1
      local value = expr()
      if peek() ~= ")" then error("missing )", 0) end
      at = at + 1
      return value
    end

    local name = source:match("^([%a_]+)", at)
    if name then
      at = at + #name
      if CONSTANTS[name] and peek() ~= "(" then return CONSTANTS[name] end
      local fn = FUNCTIONS[name]
      if not fn then error("unknown name '" .. name .. "'", 0) end
      if peek() ~= "(" then error("expected ( after " .. name, 0) end
      at = at + 1
      local first = expr()
      local second
      if peek() == "," then at = at + 1; second = expr() end
      if peek() ~= ")" then error("missing )", 0) end
      at = at + 1
      return second and fn(first, second) or fn(first)
    end

    local number = source:match("^(%d+%.?%d*)", at) or source:match("^(%.%d+)", at)
    if not number then error("unexpected '" .. (char == "" and "end" or char) .. "'", 0) end
    at = at + #number
    return tonumber(number)
  end

  local function unary()
    if peek() == "-" then at = at + 1; return -unary() end
    if peek() == "+" then at = at + 1; return unary() end
    return atom()
  end

  local function power()
    local left = unary()
    if peek() == "^" then
      at = at + 1
      return left ^ power()
    end
    return left
  end

  local function term()
    local left = power()
    while true do
      local op = peek()
      if op == "*" then at = at + 1; left = left * power()
      elseif op == "/" then
        at = at + 1
        local right = power()
        if right == 0 then error("divide by zero", 0) end
        left = left / right
      elseif op == "%" then
        at = at + 1
        local right = power()
        if right == 0 then error("divide by zero", 0) end
        left = left % right
      else return left end
    end
  end

  expr = function()
    local left = term()
    while true do
      local op = peek()
      if op == "+" then at = at + 1; left = left + term()
      elseif op == "-" then at = at + 1; left = left - term()
      else return left end
    end
  end

  local value = expr()
  skip()
  if at <= #source then error("unexpected '" .. source:sub(at, at) .. "'", 0) end
  return value
end

local function pretty(value)
  if value ~= value then return "not a number" end
  if value == math.huge then return "infinity" end
  if value == math.floor(value) and math.abs(value) < 1e15 then
    return string.format("%d", value)
  end
  return (string.format("%.10g", value))
end

--------------------------------------------------------------------------

function app.run(ctx)
  local history = {}
  local typed = {}

  local function draw()
    local width, height = term.getSize()
    term.setBackgroundColour(theme.colour.window)
    term.clear()
    ui.row(term, 1, 1, width, " Calculator", theme.colour.accentText, theme.colour.accent)

    local first = math.max(1, #history - (height - 4))
    local y = 3
    for index = first, #history do
      local entry = history[index]
      if y > height - 2 then break end
      ui.text(term, 2, y, ui.clip(entry.source, width - 2),
        theme.colour.mutedText, theme.colour.window)
      ui.text(term, 2, y + 1, ui.clip("= " .. entry.result, width - 2),
        entry.ok and theme.colour.windowText or theme.colour.danger, theme.colour.window)
      y = y + 2
    end

    ui.fill(term, 1, height - 1, width, 1, colours.white)
    ui.text(term, 1, height - 1, " > ", colours.black, colours.white)
    ui.row(term, 1, height, width, " sqrt abs floor min max pi e  ^ % ( )",
      theme.colour.mutedText, theme.colour.muted)
  end

  ctx.onResize(draw)

  draw()

  while true do
    local width, height = term.getSize()
    term.setCursorPos(4, height - 1)
    term.setBackgroundColour(colours.white)
    term.setTextColour(colours.black)

    local source = read(nil, typed)
    if source == nil then return end

    if source ~= "" then
      typed[#typed + 1] = source
      local ok, value = pcall(evaluate, source)
      history[#history + 1] = {
        source = source,
        ok = ok,
        result = ok and pretty(value) or tostring(value),
      }
      if #history > 60 then table.remove(history, 1) end
    end
    draw()
  end
end

return app
