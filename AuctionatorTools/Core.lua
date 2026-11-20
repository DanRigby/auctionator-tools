local addonName, AT = ...

AT.name = addonName
AT.CALLER_ID = "Auctionator Tools"
AT.MIN_HISTORY_DAYS = 3

local DEFAULTS = {
  autoOpen = false,
  historyDays = 14,
  activeView = "vendor",
  views = {
    vendor = { minProfit = 1, mode = "buyout", sortKey = "profit", sortAsc = false },
    deals = { minProfit = 1, discount = 30, sortKey = "profit", sortAsc = false },
    crafting = { minProfit = 1, sortKey = "profit", sortAsc = false },
    disenchant = { minProfit = 1, sortKey = "profit", sortAsc = false },
    resale = { minProfit = 1, sortKey = "profit", sortAsc = false },
  },
  vendorPrices = {},
}

local CHAR_DEFAULTS = {
  professions = {},
}

local function ApplyDefaults(target, defaults)
  for key, value in pairs(defaults) do
    if type(value) == "table" then
      if type(target[key]) ~= "table" then
        target[key] = {}
      end
      ApplyDefaults(target[key], value)
    elseif target[key] == nil then
      target[key] = value
    end
  end
end

function AT.Print(message)
  DEFAULT_CHAT_FRAME:AddMessage("|cff33ccffAuctionator Tools|r: " .. tostring(message))
end

function AT.AHCut()
  local constants = Auctionator and Auctionator.Constants
  return (constants and constants.AfterAHCut) or 0.95
end

-- Internal message bus between modules
local listeners = {}

function AT.Listen(message, callback)
  listeners[message] = listeners[message] or {}
  table.insert(listeners[message], callback)
end

function AT.Send(message, ...)
  local callbacks = listeners[message]
  if callbacks then
    for i = 1, #callbacks do
      callbacks[i](...)
    end
  end
end

-- Game events; unknown events are skipped instead of raising errors
local eventFrame = CreateFrame("Frame")
local eventHandlers = {}

function AT.OnEvent(event, callback)
  if C_EventUtils and C_EventUtils.IsEventValid and not C_EventUtils.IsEventValid(event) then
    return false
  end
  if not eventHandlers[event] then
    if not pcall(eventFrame.RegisterEvent, eventFrame, event) then
      return false
    end
    eventHandlers[event] = {}
  end
  table.insert(eventHandlers[event], callback)
  return true
end

eventFrame:SetScript("OnEvent", function(_, event, ...)
  local handlers = eventHandlers[event]
  for i = 1, #handlers do
    handlers[i](...)
  end
end)

local debounceTimers = {}
function AT.Debounce(key, delay, callback)
  if debounceTimers[key] then
    debounceTimers[key]:Cancel()
  end
  debounceTimers[key] = C_Timer.NewTimer(delay, function()
    debounceTimers[key] = nil
    callback()
  end)
end

-- Cooperative background jobs so large scans never cause frame hitches
local FRAME_BUDGET_MS = 6
local jobs = {}
local deadline = 0
local jobFrame = CreateFrame("Frame")

local function RunJobs()
  deadline = debugprofilestop() + FRAME_BUDGET_MS
  local finished
  for name, job in pairs(jobs) do
    local ok, result = coroutine.resume(job.co)
    if not ok then
      jobs[name] = nil
      geterrorhandler()(result)
    elseif coroutine.status(job.co) == "dead" then
      jobs[name] = nil
      finished = finished or {}
      table.insert(finished, { job = job, result = result })
    end
  end
  if next(jobs) == nil then
    jobFrame:SetScript("OnUpdate", nil)
  end
  if finished then
    for _, entry in ipairs(finished) do
      if entry.job.onDone then
        entry.job.onDone(entry.result)
      end
    end
  end
end

function AT.RunJob(name, func, onDone)
  jobs[name] = { co = coroutine.create(func), onDone = onDone }
  jobFrame:SetScript("OnUpdate", RunJobs)
end

function AT.CancelJob(name)
  jobs[name] = nil
end

-- Call inside a job's loop; yields once the frame budget is spent
function AT.MaybeYield(counter)
  if counter % 64 == 0 and debugprofilestop() > deadline then
    coroutine.yield()
  end
end

function AT.FormatMoney(copper)
  if copper == nil then
    return "|cff808080-|r"
  end
  local negative = copper < 0
  copper = math.floor(math.abs(copper) + 0.5)
  local text = GetMoneyString(copper, true)
  if negative then
    return "|cffff5050-|r" .. text
  end
  return text
end

-- Accepts "1g 50s 3c", "2.5g", "75s" or a bare number of copper
function AT.ParseMoney(text)
  if type(text) ~= "string" then
    return nil
  end
  text = text:lower():gsub("%s+", "")
  if text == "" then
    return nil
  end
  if text:match("^%d+$") then
    return tonumber(text)
  end
  local total, matched = 0, false
  local rest = text:gsub("(%d+%.?%d*)([gsc])", function(amount, unit)
    matched = true
    local multiplier = (unit == "g" and 10000) or (unit == "s" and 100) or 1
    total = total + tonumber(amount) * multiplier
    return ""
  end)
  if not matched or rest ~= "" then
    return nil
  end
  return math.floor(total + 0.5)
end

function AT.FormatMoneyPlain(copper)
  copper = math.floor((copper or 0) + 0.5)
  local gold = math.floor(copper / 10000)
  local silver = math.floor((copper % 10000) / 100)
  local rest = copper % 100
  local parts = {}
  if gold > 0 then table.insert(parts, gold .. "g") end
  if silver > 0 then table.insert(parts, silver .. "s") end
  if rest > 0 or #parts == 0 then table.insert(parts, rest .. "c") end
  return table.concat(parts, " ")
end

AT.OnEvent("ADDON_LOADED", function(loadedName)
  if loadedName ~= addonName then
    return
  end
  AUCTIONATOR_TOOLS_DB = AUCTIONATOR_TOOLS_DB or {}
  AUCTIONATOR_TOOLS_CHAR = AUCTIONATOR_TOOLS_CHAR or {}
  ApplyDefaults(AUCTIONATOR_TOOLS_DB, DEFAULTS)
  ApplyDefaults(AUCTIONATOR_TOOLS_CHAR, CHAR_DEFAULTS)
  AT.db = AUCTIONATOR_TOOLS_DB
  AT.char = AUCTIONATOR_TOOLS_CHAR
end)

AT.OnEvent("AUCTION_HOUSE_SHOW", function()
  AT.ahOpen = true
  AT.Send("AHStateChanged")
  if AT.db.autoOpen and AT.UI then
    AT.UI.Show()
  end
end)

AT.OnEvent("AUCTION_HOUSE_CLOSED", function()
  AT.ahOpen = false
  AT.Send("AHStateChanged")
end)

function AuctionatorTools_OnAddonCompartmentClick()
  AT.UI.Toggle()
end

SLASH_AUCTIONATORTOOLS1 = "/atools"
SLASH_AUCTIONATORTOOLS2 = "/auctionatortools"
SlashCmdList.AUCTIONATORTOOLS = function(message)
  local command = strtrim((message or ""):lower())
  if command == "" then
    AT.UI.Toggle()
  elseif command == "autoopen" then
    AT.db.autoOpen = not AT.db.autoOpen
    AT.Print("Open with the auction house: " .. (AT.db.autoOpen and "on" or "off"))
    AT.Send("SettingsChanged")
  elseif command == "reset" then
    AT.db.point = nil
    AT.UI.ResetPosition()
    AT.Print("Window position reset.")
  else
    AT.Print("/atools - toggle the window")
    AT.Print("/atools autoopen - toggle opening with the auction house")
    AT.Print("/atools reset - reset the window position")
  end
end
