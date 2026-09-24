--[[ Slate drawing helpers.

  Everything here takes an explicit target terminal (a window, or the native
  term) rather than drawing to whatever happens to be redirected. The kernel
  composites windows by hand, so "where am I drawing" must never be implicit.
]]

local ui = {}

-- blit wants one colour character per cell, so cache the repeats we use most.
local function blitRun(colour, width)
  return colours.toBlit(colour):rep(width)
end

function ui.fill(target, x, y, w, h, bg)
  if w < 1 or h < 1 then return end
  local blank = (" "):rep(w)
  local run = blitRun(bg, w)
  for row = y, y + h - 1 do
    target.setCursorPos(x, row)
    target.blit(blank, run, run)
  end
end

function ui.text(target, x, y, text, fg, bg)
  target.setCursorPos(x, y)
  if bg then target.setBackgroundColour(bg) end
  if fg then target.setTextColour(fg) end
  target.write(text)
end

-- Pad or truncate to exactly `width`, so a row never leaves stale characters.
function ui.pad(text, width)
  text = tostring(text)
  if #text > width then return ui.clip(text, width) end
  return text .. (" "):rep(width - #text)
end

function ui.clip(text, width)
  text = tostring(text)
  if width <= 0 then return "" end
  if #text <= width then return text end
  if width <= 2 then return text:sub(1, width) end
  return text:sub(1, width - 2) .. ".."
end

-- A compact single-line editor for app prompts. Unlike the built-in read(),
-- this returns terminal resizes to the app so its surrounding screen can be
-- laid out again while preserving the text being entered.
function ui.inputLine(target, x, y, value, opts)
  opts = opts or {}
  value = tostring(value or "")
  local cursor = #value
  local historyIndex, savedInput = nil, nil

  local function position()
    local px = type(x) == "function" and x() or x
    local py = type(y) == "function" and y() or y
    return px, py
  end

  local function drawInput()
    local width = target.getSize()
    local px, py = position()
    local available = math.max(0, width - px + 1)
    local first = math.max(1, cursor - available + 1)
    local shown = value:sub(first, first + available - 1)
    local shownCursor = math.min(available, cursor - first + 1)
    target.setCursorPos(px, py)
    target.setBackgroundColour(opts.bg or colours.white)
    target.setTextColour(opts.fg or colours.black)
    target.write((" "):rep(available))
    target.setCursorPos(px, py)
    target.write(opts.mask and opts.mask:rep(#shown) or shown)
    target.setCursorPos(px + shownCursor, py)
    target.setCursorBlink(true)
  end

  drawInput()
  while true do
    local event, a = os.pullEvent()
    if event == "term_resize" then
      if opts.onResize then opts.onResize() end
      drawInput()
    elseif event == "char" then
      value = value:sub(1, cursor) .. a .. value:sub(cursor + 1)
      cursor = cursor + #a
      drawInput()
    elseif event == "paste" then
      value = value:sub(1, cursor) .. a .. value:sub(cursor + 1)
      cursor = cursor + #a
      drawInput()
    elseif event == "key" then
      if a == keys.enter or a == keys.numPadEnter then
        target.setCursorBlink(false)
        return value
      elseif a == keys.backspace and cursor > 0 then
        value = value:sub(1, cursor - 1) .. value:sub(cursor + 1)
        cursor = cursor - 1
      elseif a == keys.delete and cursor < #value then
        value = value:sub(1, cursor) .. value:sub(cursor + 2)
      elseif a == keys.left then
        cursor = math.max(0, cursor - 1)
      elseif a == keys.right then
        cursor = math.min(#value, cursor + 1)
      elseif a == keys.home then
        cursor = 0
      elseif a == keys["end"] then
        cursor = #value
      elseif a == keys.up and opts.history and #opts.history > 0 then
        if historyIndex == nil then savedInput = value; historyIndex = #opts.history
        else historyIndex = math.max(1, historyIndex - 1) end
        value = tostring(opts.history[historyIndex] or "")
        cursor = #value
      elseif a == keys.down and historyIndex ~= nil then
        if historyIndex < #opts.history then
          historyIndex = historyIndex + 1
          value = tostring(opts.history[historyIndex] or "")
        else
          historyIndex, value = nil, savedInput or ""
        end
        cursor = #value
      else
        drawInput()
      end
      drawInput()
    end
  end
end

function ui.row(target, x, y, w, text, fg, bg)
  ui.text(target, x, y, ui.pad(text, w), fg, bg)
end

function ui.centre(target, y, text, fg, bg, x, w)
  text = ui.clip(text, w)
  ui.text(target, x + math.floor((w - #text) / 2), y, text, fg, bg)
end

function ui.hit(mx, my, x, y, w, h)
  return mx >= x and mx <= x + w - 1 and my >= y and my <= y + h - 1
end

-- A one-column scrollbar. Drawn only when there is something to scroll, so a
-- short list does not grow a decorative stripe.
function ui.scrollbar(target, x, y, h, total, offset, track, thumb)
  if total <= h then return end
  ui.fill(target, x, y, 1, h, track)
  local size = math.max(1, math.floor(h * h / total))
  local span = h - size
  local maxOffset = total - h
  local pos = maxOffset > 0 and math.floor(span * offset / maxOffset + 0.5) or 0
  ui.fill(target, x, y + pos, 1, size, thumb)
end

-- CC has exactly one font at one weight: there is no bold, and no `&l`. What
-- reads as bold on a terminal is inverse video, so that is what "strong" means
-- here. Everything below is a way of getting emphasis without a second font.

-- Inverse-video run. The nearest thing to bold CC can actually draw.
function ui.strong(target, x, y, text, fg, bg)
  ui.text(target, x, y, " " .. text .. " ", bg, fg)
end

-- Letter-spaced heading: "S L A T E". Wide text reads as heavier without
-- needing a heavier face.
function ui.spaced(text)
  return (tostring(text):upper():gsub("(.)", "%1 "):gsub(" $", ""))
end

-- A title row with an accent underline - the blockiness goes away when a
-- heading is a line of colour rather than a filled bar of it.
function ui.heading(target, x, y, w, text, fg, bg, accent)
  ui.row(target, x, y, w, " " .. text, fg, bg)
  ui.fill(target, x + 1, y + 1, math.min(w - 2, #text + 1), 1, accent)
end

-- A real button: padded label, its own colours, and it hands back the rect so
-- the caller hit-tests the same geometry it drew instead of guessing.
-- opts = { fg, bg, disabled, active, key }
function ui.button(target, x, y, label, opts)
  opts = opts or {}
  local text = " " .. label .. " "
  local bg = opts.bg or colours.lightGrey
  local fg = opts.fg or colours.black
  if opts.disabled then bg, fg = colours.grey, colours.lightGrey end
  if opts.active then bg, fg = opts.activeBg or colours.white, colours.black end

  ui.text(target, x, y, text, fg, bg)
  -- Rounded ends: the first and last cell get the surrounding colour back,
  -- so a button reads as a pill rather than a rectangle.
  if opts.round ~= false and #text > 2 then
    ui.text(target, x, y, "(", bg, opts.surround or colours.black)
    ui.text(target, x + #text - 1, y, ")", bg, opts.surround or colours.black)
  end
  return { x = x, y = y, w = #text, h = 1, disabled = opts.disabled }
end

-- Lays out buttons left to right from x, returning their rects by name.
function ui.buttonRow(target, x, y, list)
  local rects = {}
  local at = x
  for _, entry in ipairs(list) do
    rects[entry.name] = ui.button(target, at, y, entry.label, entry)
    at = at + #entry.label + 3
  end
  return rects
end

function ui.inButton(rect, mx, my)
  return rect and not rect.disabled and ui.hit(mx, my, rect.x, rect.y, rect.w, rect.h)
end

-- Clamps a scroll offset so a list can never show past its own end. Returns
-- the corrected offset; every scrolling view in Slate goes through this.
function ui.clampScroll(offset, total, visible)
  local maxOffset = math.max(0, total - visible)
  return math.max(0, math.min(maxOffset, offset)), maxOffset
end

--------------------------------------------------------------------------
-- circles and outlines
--
-- Terminal cells are about twice as tall as they are wide, so a circle drawn
-- with equal radii comes out as a tall oval. Every round shape here scales x
-- by ASPECT to compensate - that one constant is the difference between a
-- circle and an egg.
--------------------------------------------------------------------------

local ASPECT = 1.8

-- Hollow rectangle: a real outline rather than a filled block.
function ui.outline(target, x, y, w, h, colour)
  if w < 1 or h < 1 then return end
  ui.fill(target, x, y, w, 1, colour)
  ui.fill(target, x, y + h - 1, w, 1, colour)
  ui.fill(target, x, y, 1, h, colour)
  ui.fill(target, x + w - 1, y, 1, h, colour)
end

-- Filled rectangle with the four corner cells left alone, which reads as
-- rounded at this resolution.
function ui.roundRect(target, x, y, w, h, colour)
  if w < 3 or h < 3 then return ui.fill(target, x, y, w, h, colour) end
  ui.fill(target, x + 1, y, w - 2, 1, colour)
  ui.fill(target, x, y + 1, w, h - 2, colour)
  ui.fill(target, x + 1, y + h - 1, w - 2, 1, colour)
end

-- A panel: rounded fill plus an outline around it. The standard container
-- for anything that floats above other content.
function ui.panel(target, x, y, w, h, bg, border)
  if border then ui.outline(target, x, y, w, h, border) end
  ui.roundRect(target, x + (border and 1 or 0), y + (border and 1 or 0),
    w - (border and 2 or 0), h - (border and 2 or 0), bg)
end

function ui.circle(target, cx, cy, r, colour)
  if r < 1 then return ui.fill(target, cx, cy, 1, 1, colour) end
  for dy = -r, r do
    local span = math.floor(math.sqrt(math.max(0, r * r - dy * dy)) * ASPECT + 0.5)
    if span > 0 or dy == 0 then
      ui.fill(target, cx - span, cy + dy, span * 2 + 1, 1, colour)
    end
  end
end

-- Just the edge. Drawn per row so the aspect correction keeps it round.
function ui.ring(target, cx, cy, r, colour)
  if r < 1 then return end
  for dy = -r, r do
    local outer = math.floor(math.sqrt(math.max(0, r * r - dy * dy)) * ASPECT + 0.5)
    local inner = math.floor(math.sqrt(math.max(0, (r - 1) * (r - 1) - dy * dy)) * ASPECT + 0.5)
    if math.abs(dy) >= r - 1 then
      ui.fill(target, cx - outer, cy + dy, outer * 2 + 1, 1, colour)
    elseif outer > inner then
      ui.fill(target, cx - outer, cy + dy, outer - inner, 1, colour)
      ui.fill(target, cx + inner + 1, cy + dy, outer - inner, 1, colour)
    end
  end
end

-- A small round badge with a character in it - what an app chip looks like.
function ui.badge(target, cx, cy, colour, glyph, fg)
  ui.fill(target, cx - 1, cy, 3, 1, colour)
  if glyph then
    ui.text(target, cx, cy, glyph, fg or colours.white, colour)
  end
end

-- A thin rule instead of a solid divider.
function ui.rule(target, x, y, w, colour, bg)
  ui.text(target, x, y, ("-"):rep(w), colour, bg)
end

-- Arrow glyphs that CC's font genuinely has (CP437 range), used widely by
-- CraftOS programs. Safer than guessing at box-drawing characters.
ui.glyph = {
  up = "\30", down = "\31", right = "\16", left = "\17",
  bullet = "\7", dot = "\7",
}

-- Word-wrap to a column width, keeping existing line breaks. Used by the crash
-- screen and by Messenger, so it lives here rather than in both.
function ui.wrap(text, width)
  local out = {}
  if width < 1 then return out end
  for line in (tostring(text) .. "\n"):gmatch("([^\n]*)\n") do
    if line == "" then
      out[#out + 1] = ""
    end
    while #line > width do
      -- Break on the last space that fits; fall back to a hard cut for a word
      -- longer than the whole column.
      local cut = line:sub(1, width + 1):match(".*%s()")
      if not cut or cut < 2 then cut = width + 1 end
      local piece = line:sub(1, cut - 1):gsub("%s+$", "")
      out[#out + 1] = piece
      line = line:sub(cut):gsub("^%s+", "")
    end
    if #line > 0 then out[#out + 1] = line end
  end
  return out
end

-- Draws a label with a bracketed hotkey, e.g. "[D]elete". Basic computers have
-- no mouse, so every action needs a visible key.
function ui.key(target, x, y, key, label, fg, bg, keyFg)
  ui.text(target, x, y, "[", fg, bg)
  target.setTextColour(keyFg or fg)
  target.write(key)
  target.setTextColour(fg)
  target.write("]" .. label)
  return x + 3 + #label
end

return ui
