--[[ The built-in app registry.

  `cloud = true` means the code is not shipped with the install: the icon is
  there, and the file is fetched the first time you open it. Apps a computer
  with no network still needs - Files, Terminal, Editor, Settings, Store,
  Tasks, Updater, Messenger - are deliberately NOT cloud apps.


  Everything optional lives in the Store instead (Music, Messenger, Furnace,
  and the joke pair), which keeps a fresh desktop readable and means those
  apps can be updated without shipping a whole new OS. Their code is
  identical; only where it is delivered from changed.


  `icon` is 3 rows of 7 blit colour characters - real pixel art at character
  resolution, which is why the desktop no longer shows coloured squares with a
  letter in them. A space means "leave the wallpaper showing", so icons are not
  forced to be rectangles.

  blit colours: 0 white 1 orange 2 magenta 3 lightBlue 4 yellow 5 lime
                6 pink 7 grey 8 lightGrey 9 cyan a purple b blue
                c brown d green e red f black
]]

return {
  {
    id = "files", title = "Files", module = "apps/files", w = 40, h = 14,
    icon = { "111    ", "1111111", "1111111" },
  },
  {
    id = "terminal", title = "Terminal", module = "apps/terminal", w = 42, h = 14,
    icon = { "fffffff", "f5fffff", "fffffff" },
  },
  {
    id = "editor", title = "Editor", module = "apps/editor", w = 44, h = 15,
    icon = { "0000000", "0888880", "0088800" },
  },
  {
    -- Core app. Networking is handled by system/messenger.lua, so the UI
    -- can be closed without stopping message reception.
    id = "messenger", title = "Messenger", module = "apps/messenger", w = 42, h = 15,
    single = true,
    icon = { "2222222", "2222222", " 2     " },
  },
  {
    -- Needs your own Gemini API key; it prompts on first use and ships none.
    id = "bitai", title = "BitAI", module = "apps/bitai", w = 46, h = 16, cloud = true,
    single = true,
    icon = { " 99999 ", "9 0 0 9", " 99999 " },
  },
  {
    -- Talks to your stasis server. Asks for the address and token on first
    -- run; nothing is baked into the source, which is published publicly.
    id = "stasis", title = "Stasis", module = "apps/stasis", w = 46, h = 16,
    single = true, cloud = true,
    icon = { "  999  ", " 90009 ", "  999  " },
  },
  {
    id = "remote", title = "Remote", module = "apps/remote", w = 44, h = 15, cloud = true,
    single = true,
    icon = { "9999999", "9  0  9", "  999  " },
  },
  {
    id = "minebit", title = "Minebit", module = "apps/minebit", w = 44, h = 16, cloud = true,
    icon = { "5     5", "5555555", " 5   5 " },
  },
  {
    id = "store", title = "Store", module = "apps/store", w = 44, h = 15,
    single = true,
    icon = { " d   d ", "ddddddd", "ddddddd" },
  },
  {
    id = "cloud", title = "Cloud", module = "apps/cloud", w = 46, h = 16,
    single = true,
    icon = { "  888  ", " 88888 ", "8888888" },
  },
  {
    id = "tasks", title = "Tasks", module = "apps/tasks", w = 40, h = 14,
    single = true,
    icon = { "7 7    ", "7 7 7 7", "7 7 7 7" },
  },
  {
    id = "updater", title = "Update", module = "apps/updater", w = 40, h = 12,
    single = true,
    icon = { "   9   ", "  999  ", " 99999 " },
  },
  {
    id = "devices", title = "Devices", module = "apps/devices", w = 40, h = 13, cloud = true,
    icon = { "a   a  ", "aaaaaaa", "  aaa  " },
  },
  {
    id = "console", title = "Console", module = "apps/console", w = 44, h = 15, cloud = true,
    single = true, dev = true,
    icon = { "fffffff", "f5 ffff", "fffffff" },
  },
  {
    id = "settings", title = "Settings", module = "apps/settings", w = 36, h = 13,
    icon = { " b b b ", "bbbbbbb", " bbbbb " },
  },
}
