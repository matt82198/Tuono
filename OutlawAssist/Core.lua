local ADDON_NAME, OA = ...

OA.frame = CreateFrame("Frame")
OA.eventHandlers = {}
OA.updateHandlers = {}
OA.errorsSeen = {}
OA.errorCount = 0

local function deepMerge(target, source)
  if type(source) ~= "table" then
    return source
  end
  if type(target) ~= "table" then
    target = {}
  end
  for k, v in pairs(source) do
    if type(v) == "table" and type(target[k]) == "table" then
      target[k] = deepMerge(target[k], v)
    else
      target[k] = v
    end
  end
  return target
end

function OA.RegisterEvent(event, fn)
  if not OA.eventHandlers[event] then
    OA.eventHandlers[event] = {}
    OA.frame:RegisterEvent(event)
  end
  table.insert(OA.eventHandlers[event], fn)
end

function OA.RegisterUpdate(fn, interval)
  table.insert(OA.updateHandlers, { fn = fn, interval = interval, elapsed = 0 })
end

function OA.print(msg)
  print("|cff00ccffOutlawAssist|r: " .. tostring(msg))
end

function OA.safe(fn, ...)
  local ok, result = pcall(fn, ...)
  if not ok then
    local errMsg = tostring(result)
    if not OA.errorsSeen[errMsg] then
      OA.errorsSeen[errMsg] = true
      OA.print("Error: " .. errMsg)
    end
    OA.errorCount = OA.errorCount + 1
    return nil
  end
  return result
end

function OA.RegisterSlash(subcmd, fn, helptext)
  if not OA.slashCommands then
    OA.slashCommands = {}
  end
  OA.slashCommands[subcmd] = { fn = fn, help = helptext }
end

local function handleSlash(msg)
  local cmd = string.match(msg, "^(%S*)")
  if cmd == "" then
    OA.print("Slash commands:")
    for k, v in pairs(OA.slashCommands or {}) do
      OA.print("  /oa " .. k .. ": " .. (v.help or ""))
    end
    return
  end
  local handler = OA.slashCommands and OA.slashCommands[cmd]
  if handler then
    local args = string.sub(msg, #cmd + 2)
    OA.safe(handler.fn, args)
  else
    OA.print("Unknown command: /oa " .. cmd)
  end
end

SLASH_OUTLAWASSIST1 = "/oa"
SLASH_OUTLAWASSIST2 = "/outlawassist"
SlashCmdList["OUTLAWASSIST"] = handleSlash

OA.frame:SetScript("OnEvent", function(self, event, ...)
  if OA.eventHandlers[event] then
    for _, fn in ipairs(OA.eventHandlers[event]) do
      OA.safe(fn, event, ...)
    end
  end
end)

OA.frame:SetScript("OnUpdate", function(self, elapsed)
  for _, handler in ipairs(OA.updateHandlers) do
    handler.elapsed = handler.elapsed + elapsed
    if handler.elapsed >= handler.interval then
      OA.safe(handler.fn)
      handler.elapsed = 0
    end
  end
end)

OA.RegisterEvent("ADDON_LOADED", function(event, addonName)
  if addonName ~= ADDON_NAME then return end
  if not OA.defaults then
    OA.defaults = {}
  end
  OutlawAssistDB = deepMerge(OutlawAssistDB or {}, OA.defaults)
  OA.db = OutlawAssistDB
end)

OA.RegisterEvent("PLAYER_LOGIN", function()
  if not OA.defaults then
    OA.defaults = {}
  end
  OutlawAssistDB = deepMerge(OutlawAssistDB or {}, OA.defaults)
  OA.db = OutlawAssistDB
end)

OA.RegisterUpdate(function()
  OA.safe(function()
    if OA.State and OA.State.RefreshFast then
      OA.State.RefreshFast()
    end
    if OA.Assist and OA.Assist.Update then
      OA.Assist.Update()
    end
    local r
    if OA.Engine and OA.Engine.Evaluate then
      r = OA.Engine.Evaluate()
    end
    if OA.Display and OA.Display.Render then
      OA.Display.Render(r)
    end
  end)
end, OA.db and OA.db.updateInterval or 0.1)
