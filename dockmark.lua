--[[
================================================================================
 DockMark (strips) — red bar under real Dock icons for apps with a window
================================================================================
 Now matches Dock icons to apps by FILE PATH (robust) with name as a fallback,
 so apps whose Dock label differs from their app name (e.g. Dock "Visual Studio
 Code" vs app name "Code") light up correctly.

 If you want an app that keeps a phantom background window (e.g. Microsoft Teams)
 to NOT show a bar, add its name to config.ignoreApps below.

 DIAGNOSTIC: reproduce a problem, then in the Hammerspoon Console run
   DockMark.dump()
 and paste the output. It now prints each app's PATH too, so we can verify the
 matching.

 INSTALL/UPDATE: mv ~/Downloads/dockmark.lua ~/.hammerspoon/init.lua ; Reload.
================================================================================
]]

local M = {}

--------------------------------------------------------------------------------
-- CONFIG
--------------------------------------------------------------------------------
local config = {
  stripColor       = { red = 0.85, green = 0.16, blue = 0.16, alpha = 0.95 },
  stripHeightPx    = 4,
  stripWidthFrac   = 0.42,
  cornerRadius     = 2,
  verticalNudge    = 0,
  includeMinimized = true,
  refreshInterval  = 1.0,
  ignoreApps       = {        -- lowercase app names that should NEVER get a bar
    -- "microsoft teams",     -- uncomment if Teams' background window annoys you
  },
  debug            = false,
}

--------------------------------------------------------------------------------
-- STATE
--------------------------------------------------------------------------------
local canvas, appWatcher, poll, debounce, lastSig
local ignore = {}
for _, n in ipairs(config.ignoreApps) do ignore[n:lower()] = true end

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------
local function normPath(s)
  if type(s) ~= "string" then return nil end
  s = s:gsub("/+$", "")
  return s:lower()
end

-- AXURL (string or table) -> filesystem path
local function urlToPath(url)
  local s
  if type(url) == "string" then s = url
  elseif type(url) == "table" then s = url.url or url.path or url[1] end
  if type(s) ~= "string" then return nil end
  s = s:gsub("^file://", "")
  s = s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)
  return s
end

-- Window subroles that count as "a real window". Some apps (Safari, OneNote,
-- Teams, Zotero, Outlook...) report their window as AXDialog once minimized
-- instead of AXStandardWindow, so we accept both. The desktop (Finder's window,
-- empty subrole) is not in this set, so it stays excluded.
local windowSubroles = {
  AXStandardWindow = true,
  AXDialog         = true,
}

local function appIsWindowed(app)
  local ok, wins = pcall(function() return app:allWindows() end)
  if not ok or not wins then return false end
  for _, w in ipairs(wins) do
    if windowSubroles[w:subrole()] then
      if config.includeMinimized or not w:isMinimized() then
        return true
      end
    end
  end
  return false
end

--------------------------------------------------------------------------------
-- Dock geometry + path, via accessibility
--------------------------------------------------------------------------------
local function pointXY(v) if not v then return nil end return v.x or v[1], v.y or v[2] end
local function sizeWH(v)  if not v then return nil end return v.w or v[1], v.h or v[2] end

local function dockAppIcons()
  local dock = hs.application.get("com.apple.dock")
  if not dock then return {} end
  local ax = hs.axuielement.applicationElement(dock)
  if not ax then return {} end
  local list
  for _, child in ipairs(ax:attributeValue("AXChildren") or {}) do
    if child:attributeValue("AXRole") == "AXList" then list = child break end
  end
  if not list then return {} end
  local icons = {}
  for _, item in ipairs(list:attributeValue("AXChildren") or {}) do
    if item:attributeValue("AXSubrole") == "AXApplicationDockItem" then
      local title = item:attributeValue("AXTitle")
      local x, y  = pointXY(item:attributeValue("AXPosition"))
      local w, h  = sizeWH(item:attributeValue("AXSize"))
      local okURL, url = pcall(function() return item:attributeValue("AXURL") end)
      local path = okURL and normPath(urlToPath(url)) or nil
      if title and x and y and w and h then
        icons[#icons + 1] = { title = title, path = path, x = x, y = y, w = w, h = h }
      end
    end
  end
  return icons
end

--------------------------------------------------------------------------------
-- Which Dock icons should get a bar?  (path match first, name match fallback)
--------------------------------------------------------------------------------
local function matchedIcons(icons)
  local dockPaths, dockNames = {}, {}
  for _, ic in ipairs(icons) do
    if ic.path then dockPaths[ic.path] = true end
    dockNames[ic.title:lower()] = true
  end

  local winPaths, winNames = {}, {}
  for _, app in ipairs(hs.application.runningApplications()) do
    pcall(function()                          -- one bad process can't break the loop
      local n = app:name()
      local p = normPath(app:path())
      local nkey = n and n:lower() or nil
      local inDock = (p and dockPaths[p]) or (nkey and dockNames[nkey])
      if inDock and not (nkey and ignore[nkey]) and appIsWindowed(app) then
        if p then winPaths[p] = true end
        if nkey then winNames[nkey] = true end
      end
    end)
  end

  local out = {}
  for _, ic in ipairs(icons) do
    local hit = (ic.path and winPaths[ic.path]) or winNames[ic.title:lower()]
    if hit and not ignore[ic.title:lower()] then out[#out + 1] = ic end
  end
  return out
end

--------------------------------------------------------------------------------
-- Recompute + repaint (only when changed)
--------------------------------------------------------------------------------
local function refresh()
  local ok, icons = pcall(dockAppIcons)
  if not ok then return end
  local hits = matchedIcons(icons)

  local strips, names = {}, {}
  local minX, minY, maxX, maxY
  for _, ic in ipairs(hits) do
    local sw = ic.w * config.stripWidthFrac
    local sx = ic.x + ic.w / 2 - sw / 2
    local sy = ic.y + ic.h - config.stripHeightPx + config.verticalNudge
    strips[#strips + 1] = { x = sx, y = sy, w = sw, h = config.stripHeightPx }
    names[#names + 1] = ic.title
    minX = math.min(minX or sx, sx);  maxX = math.max(maxX or (sx + sw), sx + sw)
    minY = math.min(minY or sy, sy);  maxY = math.max(maxY or (sy + config.stripHeightPx), sy + config.stripHeightPx)
  end

  local sigParts = {}
  for _, s in ipairs(strips) do sigParts[#sigParts + 1] = math.floor(s.x) .. "," .. math.floor(s.y) end
  table.sort(sigParts)
  local sig = table.concat(sigParts, "|")
  if sig == lastSig then return end
  lastSig = sig

  if config.debug then
    table.sort(names)
    print("DockMark bars: " .. (next(names) and table.concat(names, ", ") or "(none)"))
  end

  if #strips == 0 then
    if canvas then canvas:hide() end
    return
  end

  local fx, fy, fw, fh = minX, minY, maxX - minX, maxY - minY
  if not canvas then
    canvas = hs.canvas.new({ x = fx, y = fy, w = fw, h = fh })
    canvas:level(hs.canvas.windowLevels.dock + 1)
    canvas:behavior(hs.canvas.windowBehaviors.canJoinAllSpaces)
  else
    canvas:frame({ x = fx, y = fy, w = fw, h = fh })
  end

  local els = {}
  for _, s in ipairs(strips) do
    els[#els + 1] = {
      type = "rectangle", action = "fill",
      fillColor = config.stripColor,
      roundedRectRadii = { xRadius = config.cornerRadius, yRadius = config.cornerRadius },
      frame = { x = s.x - fx, y = s.y - fy, w = s.w, h = s.h },
    }
  end
  canvas:replaceElements(els)
  canvas:show()
end

local function scheduleRefresh()
  if debounce then debounce:stop() end
  debounce = hs.timer.doAfter(0.1, refresh)
end

--------------------------------------------------------------------------------
-- DIAGNOSTIC — run  DockMark.dump()  in the Console
--------------------------------------------------------------------------------
function M.dump()
  print("\n==================== DockMark diagnostic ====================")
  local icons = dockAppIcons()
  print(string.format("Dock application items: %d", #icons))
  for _, ic in ipairs(icons) do
    print(string.format('  DOCK  %-26s path=%s', '"' .. ic.title .. '"', tostring(ic.path)))
  end
  print("\nRunning apps with a Dock icon (matched by path or name):")
  local dockPaths, dockNames = {}, {}
  for _, ic in ipairs(icons) do if ic.path then dockPaths[ic.path] = true end dockNames[ic.title:lower()] = true end
  for _, app in ipairs(hs.application.runningApplications()) do
    pcall(function()
      local n = app:name()
      local p = normPath(app:path())
      if (p and dockPaths[p]) or (n and dockNames[n:lower()]) then
        local ok, wins = pcall(function() return app:allWindows() end)
        wins = ok and wins or {}
        print(string.format('  APP   "%s"  windows=%d  path=%s%s',
          tostring(n), #wins, tostring(p), ignore[(n or ""):lower()] and "  [IGNORED]" or ""))
        for _, w in ipairs(wins) do
          print(string.format("          subrole=%-18s standard=%-5s min=%-5s vis=%-5s",
            tostring(w:subrole()), tostring(w:isStandard()), tostring(w:isMinimized()), tostring(w:isVisible())))
        end
      end
    end)
  end
  print("\nDock icons that WOULD get a bar:")
  local hits = matchedIcons(icons)
  if #hits == 0 then print("  (none)") end
  for _, ic in ipairs(hits) do print("  -> " .. ic.title) end
  print("===============================================================\n")
end

--------------------------------------------------------------------------------
-- Start / stop
--------------------------------------------------------------------------------
function M.start()
  appWatcher = hs.application.watcher.new(function(_, ev)
    if ev == hs.application.watcher.launched
    or ev == hs.application.watcher.terminated
    or ev == hs.application.watcher.hidden
    or ev == hs.application.watcher.unhidden then
      scheduleRefresh()
    end
  end)
  appWatcher:start()
  poll = hs.timer.doEvery(config.refreshInterval, refresh)
  refresh()
end

function M.stop()
  if appWatcher then appWatcher:stop(); appWatcher = nil end
  if poll then poll:stop(); poll = nil end
  if debounce then debounce:stop(); debounce = nil end
  if canvas then canvas:delete(); canvas = nil end
  lastSig = nil
end

M.start()
DockMark = M
return M
