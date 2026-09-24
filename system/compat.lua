--[[ Compatibility - old apps on new Slate, and new apps on old Slate.

  Two things break when an OS grows an app API:

    1. An app written for an older Slate calls something that has since been
       renamed or removed, and dies on "attempt to call a nil value".
    2. An app written for a newer Slate calls something this version does not
       have yet, and dies the same way.

  Both are handled here rather than in every app:

    * adapt()   accepts every module shape Slate has ever used, so an app
                that returns a bare function still runs.
    * context() gives ctx a metatable, so an unknown field returns a harmless
                no-op instead of nil. An old app calling a removed function
                keeps working, minus that feature.
    * API       is a number apps and store entries can test against, so an
                app that genuinely needs something newer is refused with a
                message instead of crashing half way through.

  API history:
    1  run(ctx): close, setTitle, launch, size, redraw
    2  + onClose, fullscreen, root
    3  + power, notify
    4  + onResize
]]

local compat = {}

compat.API = 4

-- Every module shape Slate has accepted. Returning a bare function was the
-- obvious thing to write before there was a documented shape, so it still
-- works.
function compat.adapt(module)
  if type(module) == "function" then
    return { run = module }
  end
  if type(module) == "table" then
    if type(module.run) == "function" then return module end
    -- `main` is what someone porting a normal CC program tends to call it.
    if type(module.main) == "function" then return { run = module.main } end
  end
  return nil, "an app must return a table with run(ctx), or a function"
end

-- Does this Slate provide what the app asked for?
function compat.satisfies(required)
  local wanted = tonumber(required)
  if not wanted then return true end
  return wanted <= compat.API
end

function compat.tooNew(required)
  return ("needs Slate API %s, this is %d"):format(tostring(required), compat.API)
end

-- Wraps a context so unknown fields are survivable. The stub returns nil and
-- does nothing, which is what an app that lost a feature should see - not a
-- crash that takes the window with it.
function compat.context(ctx)
  ctx.api = compat.API

  local warned = {}
  return setmetatable(ctx, {
    __index = function(table_, key)
      if type(key) ~= "string" then return nil end
      if not warned[key] then
        warned[key] = true
        -- rawget, NOT table_.log: a plain lookup of a field that does not
        -- exist would re-enter this same __index and recurse forever.
        local logger = rawget(table_, "log")
        if logger then logger("ctx." .. key .. " is not available in this version") end
      end
      return function() return nil end
    end,
  })
end

return compat
