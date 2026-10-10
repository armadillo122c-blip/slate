--[[ Auto-update mechanism.

  Points at a base URL holding a manifest:

      { "version": "1.3", "files": ["startup.lua", "system/ui.lua", ...] }

  The install order is the important part: EVERY file is downloaded into
  memory and checked first, and only then is anything written to disk. A
  download that fails half way leaves the installed copy untouched, because
  a half-updated OS is worse than an out-of-date one.

  The URL and the auto setting live in CC's settings, so they survive updates
  of Slate itself. So does the version an install last wrote: that, not the
  number below, is what the next check compares against, so a release only
  has to bump manifest.json.
]]

local update = {}

-- The release this file shipped in. It is only a floor for a copy that has
-- never been through install(), such as a folder copied on by hand. 1.30 to
-- 1.32 bumped the manifest but not this, so every computer kept reading 1.29,
-- reinstalling, restarting, and reading 1.29 again.
local BUILT_IN = "1.33"

local MANIFEST = "manifest.json"
local INSTALLED = "slate.update.installed"

-- Where Slate updates from unless Settings says otherwise. Raw GitHub serves
-- the repository's files directly over plain HTTPS, which is all CC's http
-- API can do - no auth headers, no API tokens.
local DEFAULT_URL = "https://raw.githubusercontent.com/armadillo122c-blip/slate/main"

function update.url()
  local ok, value = pcall(settings.get, "slate.update.url")
  if ok and type(value) == "string" and value ~= "" then
    return (value:gsub("/+$", ""))
  end
  return DEFAULT_URL
end

function update.isDefaultUrl()
  local ok, value = pcall(settings.get, "slate.update.url")
  return not (ok and type(value) == "string" and value ~= "")
end

function update.setUrl(value)
  pcall(function()
    if value == nil or value == "" then
      settings.unset("slate.update.url")
    else
      settings.set("slate.update.url", value)
    end
    settings.save()
  end)
end

-- "off" | "notify" | "silent". Silent installs without asking, which is what
-- most people mean by auto-update; notify only tells you one is waiting.
function update.mode()
  local ok, value = pcall(settings.get, "slate.update.mode")
  if ok and (value == "off" or value == "notify" or value == "silent") then
    return value
  end
  -- Older installs stored a boolean; treat a true as the new silent default.
  local legacy, was = pcall(settings.get, "slate.update.auto")
  if legacy and was == true then return "silent" end
  return "silent"
end

function update.setMode(mode)
  pcall(function()
    settings.set("slate.update.mode", mode)
    settings.save()
  end)
end

function update.auto()
  return update.mode() ~= "off"
end

-- "idle" | "ask" | "never". Windows-style is "idle": it restarts by itself,
-- but only once the computer has been left alone.
function update.restartMode()
  local ok, value = pcall(settings.get, "slate.update.restart")
  if ok and (value == "idle" or value == "ask" or value == "never") then
    return value
  end
  return "idle"
end

function update.setRestartMode(mode)
  pcall(function()
    settings.set("slate.update.restart", mode)
    settings.save()
  end)
end

function update.setAuto(on)
  update.setMode(on and "silent" or "off")
end

-- Compares dotted versions numerically: "1.10" is newer than "1.9".
function update.isNewer(candidate, current)
  local function parts(text)
    local out = {}
    for piece in tostring(text):gmatch("%d+") do out[#out + 1] = tonumber(piece) end
    return out
  end
  local a, b = parts(candidate), parts(current)
  for index = 1, math.max(#a, #b) do
    local left, right = a[index] or 0, b[index] or 0
    if left ~= right then return left > right end
  end
  return false
end

-- The version on disk right now. Re-read every time, so once an install has
-- written a release, checking again before the restart does not fetch it again.
function update.installed()
  local ok, value = pcall(settings.get, INSTALLED)
  if ok and type(value) == "string" and update.isNewer(value, BUILT_IN) then
    return value
  end
  return BUILT_IN
end

-- The version that is running: read once, when Slate booted.
update.VERSION = update.installed()

local function fetch(url)
  local response, err = http.get(url)
  if not response then return nil, tostring(err) end
  local body = response.readAll()
  response.close()
  return body
end

-- Returns { version, files, newer } or nil plus a reason.
function update.check()
  if not http then return nil, "HTTP is disabled" end
  local base = update.url()
  if not base then return nil, "No update URL set" end

  local body, err = fetch(base .. "/" .. MANIFEST)
  if not body then return nil, err end

  local manifest = textutils.unserialiseJSON(body)
  if type(manifest) ~= "table" or type(manifest.version) ~= "string"
      or type(manifest.files) ~= "table" then
    return nil, "Manifest is not valid"
  end

  return {
    base = base,
    version = manifest.version,
    files = manifest.files,
    notes = type(manifest.notes) == "string" and manifest.notes or nil,
    newer = update.isNewer(manifest.version, update.installed()),
  }
end

-- progress(stage, done, total) is called as it goes so the UI can show it.
function update.install(info, root, progress)
  if type(info) ~= "table" or type(info.files) ~= "table" then
    return false, "Nothing to install"
  end

  local total = #info.files
  local staged = {}

  for index, name in ipairs(info.files) do
    if type(name) ~= "string" or name:find("%.%.") then
      return false, "Manifest names a bad path: " .. tostring(name)
    end
    if progress then progress("Downloading " .. name, index, total) end
    local body, err = fetch(info.base .. "/" .. name)
    if not body then return false, "Failed on " .. name .. ": " .. tostring(err) end
    staged[#staged + 1] = { name = name, body = body }
  end

  -- Everything is in hand; only now touch the disk.
  for index, file in ipairs(staged) do
    if progress then progress("Writing " .. file.name, index, total) end
    local path = fs.combine(root, file.name)
    local folder = fs.getDir(path)
    if folder ~= "" and not fs.exists(folder) then
      local made = pcall(fs.makeDir, folder)
      if not made then return false, "Could not create " .. folder end
    end
    local handle, err = fs.open(path, "w")
    if not handle then return false, "Could not write " .. path .. ": " .. tostring(err) end
    handle.write(file.body)
    handle.close()
  end

  -- Recorded last, so a write that fails part way leaves the old version
  -- standing and the next check tries again.
  if type(info.version) == "string" then
    pcall(function()
      settings.set(INSTALLED, info.version)
      settings.save()
    end)
  end

  return true, total
end

-- The whole unattended path in one call: check, and install if there is
-- something newer. Returns the version installed, or nil plus a reason.
--
-- It still stages every file before writing any of them, so an unattended
-- update cannot leave a half-installed OS behind. What it skips is asking.
function update.applySilently(root)
  local info, err = update.check()
  if not info then return nil, err end
  if not info.newer then return nil, nil end

  local ok, result = update.install(info, root)
  if not ok then return nil, tostring(result) end
  return info.version
end

return update
