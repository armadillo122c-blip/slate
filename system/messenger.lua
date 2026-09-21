--[[ Messenger background service.
  Networking is owned by Slate itself, not the Messenger window. The service
  stays alive for as long as the OS does, stores received messages on disk,
  and exposes the data to the Messenger app when it opens.

  rednet is still unauthenticated: a nearby computer can send messages and
  claim any display name.
]]

local use = ...
local notify = use("system/notify")
local peripherals = use("system/peripherals")

local messenger = {}

local PROTOCOL = "slate.msg"
local BROADCAST = "all"
local MAX_MESSAGES = 200
local DATA_FILE = "data/messenger.json"

local root = ""
local modem = nil
local openedByUs = false
local wireless = false
local announceTimer = nil
local me = os.getComputerID()
local myName = os.getComputerLabel() or ("computer " .. me)

local peers = {}
local logs = { [BROADCAST] = {} }
local unread = {}
local active = nil
local stats = { modem = 0, rednet = 0, mine = 0, sent = 0, lastFrom = "-" }

local function dataPath()
  return fs.combine(root, DATA_FILE)
end

local function save()
  if root == "" then return end
  local folder = fs.combine(root, "data")
  if not fs.exists(folder) then pcall(fs.makeDir, folder) end

  local handle = fs.open(dataPath(), "w")
  if not handle then return end

  local payload = {
    peers = peers,
    logs = logs,
    unread = unread,
  }
  handle.write(textutils.serializeJSON(payload))
  handle.close()
end

local function load()
  peers, logs, unread = {}, { [BROADCAST] = {} }, {}
  if root == "" or not fs.exists(dataPath()) then return end

  local handle = fs.open(dataPath(), "r")
  if not handle then return end
  local body = handle.readAll() or ""
  handle.close()

  local ok, saved = pcall(textutils.unserialiseJSON, body)
  if not ok or type(saved) ~= "table" then return end

  if type(saved.peers) == "table" then peers = saved.peers end
  if type(saved.logs) == "table" then logs = saved.logs end
  if type(saved.unread) == "table" then unread = saved.unread end
  logs[BROADCAST] = logs[BROADCAST] or {}
end

local function trim(log)
  while #log > MAX_MESSAGES do table.remove(log, 1) end
end

local function append(id, who, senderId, text, mine)
  id = tostring(id)
  logs[id] = logs[id] or {}
  logs[id][#logs[id] + 1] = {
    who = who,
    senderId = senderId,
    text = text:sub(1, 400),
    time = textutils.formatTime(os.time(), true),
    mine = mine == true,
  }
  trim(logs[id])
end

local function seePeer(id, name)
  id = tonumber(id) or id
  if id == me then return end
  local peer = peers[tostring(id)]
  if not peer then
    peer = { id = id, name = name or ("computer " .. id) }
    peers[tostring(id)] = peer
  elseif name and name ~= "" then
    peer.name = name
  end
end

local function findModem()
  local wired
  for _, name in ipairs(peripherals.names()) do
    if peripherals.isType(name, "modem") then
      local device = peripheral.wrap(name)
      local isWireless = false
      if device and device.isWireless then
        local ok, value = pcall(device.isWireless)
        isWireless = ok and value == true
      end
      if isWireless then return name, true end
      wired = wired or name
    end
  end
  return wired, false
end

local function openModem()
  if modem then
    local ok, open = pcall(rednet.isOpen, modem)
    if ok and open then return true end
  end

  local name, isWireless = findModem()
  if not name then
    modem = nil
    wireless = false
    openedByUs = false
    return false
  end

  modem = name
  wireless = isWireless
  local ok, open = pcall(rednet.isOpen, modem)
  if ok and open then
    openedByUs = false
  else
    ok = pcall(rednet.open, modem)
    if not ok then
      modem = nil
      wireless = false
      openedByUs = false
      return false
    end
    openedByUs = true
  end

  pcall(rednet.host, PROTOCOL, myName)
  return true
end

local function announce()
  if openModem() then
    local ok = pcall(rednet.broadcast, {
      kind = "hello",
      name = myName,
    }, PROTOCOL)
    if ok then stats.sent = stats.sent + 1 end
  end
  announceTimer = os.startTimer(10)
end

function messenger.init(path)
  root = path or ""
  me = os.getComputerID()
  myName = os.getComputerLabel() or ("computer " .. me)
  active = nil
  load()
  openModem()
  announceTimer = os.startTimer(1)
end

function messenger.announce()
  announce()
end

function messenger.shutdown()
  if announceTimer then
    pcall(os.cancelTimer, announceTimer)
    announceTimer = nil
  end
  if modem then
    pcall(rednet.unhost, PROTOCOL)
    if openedByUs then pcall(rednet.close, modem) end
  end
  modem = nil
  openedByUs = false
  save()
end

function messenger.handleEvent(event)
  local name = event[1]

  if name == "timer" and event[2] == announceTimer then
    announce()
    return false
  end

  if name == "peripheral" then
    local attached = event[2]
    if peripherals.isType(attached, "modem") then
      openModem()
      announce()
      return true
    end
    return false
  end

  if name == "peripheral_detach" then
    if modem == event[2] then
      pcall(rednet.unhost, PROTOCOL)
      modem = nil
      wireless = false
      openedByUs = false
      openModem()
      announce()
      return true
    end
    return false
  end

  if name == "modem_message" then
    stats.modem = stats.modem + 1
    return false
  end

  if name ~= "rednet_message" or event[4] ~= PROTOCOL then return false end

  stats.rednet = stats.rednet + 1

  local sender = tonumber(event[2]) or event[2]
  local message = event[3]
  if type(message) ~= "table" or type(message.kind) ~= "string" then return false end

  if message.kind == "hello" then
    seePeer(sender, type(message.name) == "string" and message.name or nil)
    if openModem() then
      pcall(rednet.send, sender, { kind = "here", name = myName }, PROTOCOL)
    end
    save()
    return true
  end

  if message.kind == "here" then
    seePeer(sender, type(message.name) == "string" and message.name or nil)
    save()
    return true
  end

  if message.kind == "msg" and type(message.text) == "string" then
    stats.mine = stats.mine + 1
    stats.lastFrom = "#" .. tostring(sender)
    seePeer(sender, type(message.name) == "string" and message.name or nil)

    local key = message.to == BROADCAST and BROADCAST or tostring(sender)
    local who = peers[tostring(sender)] and peers[tostring(sender)].name
      or ("computer " .. tostring(sender))

    append(key, who, sender, message.text, false)

    if active ~= key then
      unread[key] = (tonumber(unread[key]) or 0) + 1
      notify.push("messenger", who .. ": " .. message.text:sub(1, 40))
    end

    save()
    return true
  end

  return false
end

function messenger.send(target, text)
  if type(text) ~= "string" or text == "" then return false, "empty message" end
  if not openModem() then return false, "no modem" end

  target = target or BROADCAST
  local payload = {
    kind = "msg",
    name = myName,
    text = text:sub(1, 400),
    to = target,
  }

  local ok
  if target == BROADCAST then
    ok = pcall(rednet.broadcast, payload, PROTOCOL)
  else
    ok = pcall(rednet.send, tonumber(target) or target, payload, PROTOCOL)
  end

  if not ok then return false, "could not send" end

  stats.sent = stats.sent + 1
  local key = target == BROADCAST and BROADCAST or tostring(target)
  local who = target == BROADCAST and "Everyone"
    or (peers[tostring(target)] and peers[tostring(target)].name
      or ("computer " .. tostring(target)))
  append(key, "me", me, text, true)
  save()
  return true
end

function messenger.setActive(target)
  active = target == nil and nil or tostring(target)
  if active then unread[active] = 0 end
  notify.clear("messenger")
  save()
end

function messenger.markRead(target)
  local key = target == nil and nil or tostring(target)
  if key then unread[key] = 0 end
  notify.clear("messenger")
  save()
end

function messenger.peers()
  local list = {}
  for id, peer in pairs(peers) do
    list[#list + 1] = {
      id = tonumber(peer.id) or id,
      name = peer.name or ("computer " .. tostring(peer.id or id)),
      unread = tonumber(unread[id]) or 0,
    }
  end
  table.sort(list, function(a, b) return tostring(a.id) < tostring(b.id) end)

  table.insert(list, 1, {
    id = BROADCAST,
    name = "Everyone",
    unread = tonumber(unread[BROADCAST]) or 0,
  })
  return list
end

function messenger.messages(target)
  local key = target == nil and BROADCAST or tostring(target)
  return logs[key] or {}
end

function messenger.unread(target)
  return tonumber(unread[tostring(target)]) or 0
end

function messenger.totalUnread()
  local total = 0
  for _, count in pairs(unread) do total = total + (tonumber(count) or 0) end
  return total
end

function messenger.info()
  return {
    modem = modem,
    wireless = wireless,
    open = modem ~= nil and pcall(function() return rednet.isOpen(modem) end) or false,
    id = me,
    name = myName,
    protocol = PROTOCOL,
    modemMessages = stats.modem,
    rednetMessages = stats.rednet,
    messages = stats.mine,
    sent = stats.sent,
    lastFrom = stats.lastFrom,
    peers = #messenger.peers() - 1,
  }
end

return messenger
