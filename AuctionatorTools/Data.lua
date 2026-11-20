local _, AT = ...

local Data = {}
AT.Data = Data

local API = Auctionator.API.v1
local GetItemInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
local RequestLoadItem = C_Item and C_Item.RequestLoadItemDataByID
local SUMMARY_PREFERENCE_SECONDS = 15 * 60
local MAX_LOAD_ATTEMPTS = 3

-- Static item info never changes, so it is cached for the session
local itemCache = {}
local loadAttempts = {}
local pendingLoads = {}

Data.missingItems = 0

function Data.Item(itemID)
  local cached = itemCache[itemID]
  if cached then
    return cached
  end
  local name, link, quality, _, _, _, _, maxStack, _, icon, sellPrice, classID, subclassID = GetItemInfo(itemID)
  if not name then
    local attempts = loadAttempts[itemID] or 0
    if attempts < MAX_LOAD_ATTEMPTS and not pendingLoads[itemID] and RequestLoadItem then
      loadAttempts[itemID] = attempts + 1
      pendingLoads[itemID] = true
      RequestLoadItem(itemID)
    end
    Data.missingItems = Data.missingItems + 1
    return nil
  end
  cached = {
    id = itemID,
    name = name,
    link = link,
    quality = quality or 1,
    icon = icon,
    sell = sellPrice or 0,
    classID = classID,
    subclassID = subclassID,
    maxStack = maxStack or 1,
  }
  itemCache[itemID] = cached
  return cached
end

AT.OnEvent("ITEM_DATA_LOAD_RESULT", function(itemID)
  if pendingLoads[itemID] then
    pendingLoads[itemID] = nil
    AT.Debounce("itemData", 0.5, function()
      AT.Send("ItemDataLoaded")
    end)
  end
end)

local commodityCache = {}
function Data.IsCommodity(itemID)
  local cached = commodityCache[itemID]
  if cached ~= nil then
    return cached
  end
  local result
  if C_AuctionHouse and C_AuctionHouse.GetItemCommodityStatus and Enum.ItemCommodityStatus then
    local status = C_AuctionHouse.GetItemCommodityStatus(itemID)
    if status == Enum.ItemCommodityStatus.Commodity then
      result = true
    elseif status == Enum.ItemCommodityStatus.Item then
      result = false
    end
  end
  if result == nil then
    local item = Data.Item(itemID)
    if not item then
      return false
    end
    result = item.maxStack > 1
  end
  commodityCache[itemID] = result
  return result
end

function Data.CurrentPrice(itemID)
  return API.GetAuctionPriceByItemID(AT.CALLER_ID, itemID)
end

function Data.PriceAge(itemID)
  return API.GetAuctionAgeByItemID(AT.CALLER_ID, itemID)
end

function Data.DisenchantValue(itemID)
  if not API.GetDisenchantPriceByItemID then
    return nil
  end
  return API.GetDisenchantPriceByItemID(AT.CALLER_ID, itemID)
end

-- Typical price: median of the daily lowest prices before today
local marketCache = {}
local dayValues = {}

function Data.MarketPrice(itemID)
  local cached = marketCache[itemID]
  if cached ~= nil then
    return cached or nil
  end
  local result = false
  local db = Auctionator.Database and Auctionator.Database.db
  local entry = db and db[tostring(itemID)]
  if entry and entry.h then
    local today = math.floor((time() - Auctionator.Constants.SCAN_DAY_0) / 86400)
    local lows = entry.l or {}
    local count = 0
    for day = today - 1, today - AT.db.historyDays, -1 do
      local key = tostring(day)
      local value = lows[day] or entry.h[day] or lows[key] or entry.h[key]
      if value then
        count = count + 1
        dayValues[count] = value
      end
    end
    if count >= AT.MIN_HISTORY_DAYS then
      for i = count + 1, #dayValues do
        dayValues[i] = nil
      end
      table.sort(dayValues)
      if count % 2 == 1 then
        result = dayValues[(count + 1) / 2]
      else
        result = math.floor((dayValues[count / 2] + dayValues[count / 2 + 1]) / 2)
      end
    end
  end
  marketCache[itemID] = result
  return result or nil
end

function Data.ClearPriceCache()
  wipe(marketCache)
end

-- Auction scans are produced by Auctionator; we only keep a reference
Data.full = nil
Data.summary = nil
Data.scanning = nil

local function OnScanComplete(kind, rows)
  if type(rows) ~= "table" then
    return
  end
  Data[kind] = { time = time(), rows = rows }
  Data.scanning = nil
  Data.ClearPriceCache()
  AT.Send("ScanUpdated", kind)
end

local listener = {}
function listener:ReceiveEvent(eventName, eventData)
  local full = Auctionator.FullScan and Auctionator.FullScan.Events
  local summary = Auctionator.IncrementalScan and Auctionator.IncrementalScan.Events
  if full and eventName == full.ScanComplete then
    OnScanComplete("full", eventData)
  elseif summary and eventName == summary.ScanComplete then
    OnScanComplete("summary", eventData)
  elseif (full and eventName == full.ScanStart) or (summary and eventName == summary.ScanStart) then
    Data.scanning = 0
    AT.Send("ScanProgress")
  elseif (full and eventName == full.ScanProgress) or (summary and eventName == summary.ScanProgress) then
    Data.scanning = tonumber(eventData) or Data.scanning or 0
    AT.Send("ScanProgress")
  elseif (full and eventName == full.ScanFailed) or (summary and eventName == summary.ScanFailed) then
    Data.scanning = nil
    AT.Send("ScanProgress")
  elseif summary and eventName == summary.PricesProcessed then
    Data.ClearPriceCache()
  end
end

local scanEvents = {}
for _, module in ipairs({ "FullScan", "IncrementalScan" }) do
  local group = Auctionator[module] and Auctionator[module].Events
  if group then
    for _, key in ipairs({ "ScanStart", "ScanProgress", "ScanComplete", "ScanFailed", "PricesProcessed" }) do
      if group[key] then
        table.insert(scanEvents, group[key])
      end
    end
  end
end
if #scanEvents > 0 then
  Auctionator.EventBus:Register(listener, scanEvents)
end

-- Reuse the last scan saved by the optional PreserveAuctionatorAHScan addon
AT.OnEvent("PLAYER_LOGIN", function()
  local ok, realm = pcall(Auctionator.Variables.GetConnectedRealmRoot)
  if not ok or not realm then
    return
  end
  local function Load(kind, saved)
    if type(saved) == "table" and saved.realm == realm and type(saved.data) == "table" and not Data[kind] then
      Data[kind] = { time = saved.time or time(), rows = saved.data }
    end
  end
  Load("full", PRESERVE_AUCTIONATOR_AH_SCAN_LAST_SCAN)
  Load("summary", PRESERVE_AUCTIONATOR_AH_SCAN_LAST_SUMMARY)
  if Data.full or Data.summary then
    AT.Send("ScanUpdated")
  end
end)

-- Full scans include every listing; summary scans only the lowest price per item
function Data.GetScan(needFull)
  local full, summary = Data.full, Data.summary
  if needFull then
    return full and "full", full
  end
  if full and (not summary or summary.time <= full.time + SUMMARY_PREFERENCE_SECONDS) then
    return "full", full
  end
  if summary then
    return "summary", summary
  end
  return nil, nil
end

function Data.StartScan()
  if not AT.ahOpen then
    return false, "Open the auction house to scan."
  end
  local state = Auctionator.State or {}
  local fullFrame = state.FullScanFrameRef
  if fullFrame and fullFrame.CanInitiate and fullFrame:CanInitiate() then
    fullFrame:InitiateScan()
    return true
  end
  local summaryFrame = state.IncrementalScanFrameRef
  if summaryFrame and summaryFrame.InitiateScan then
    summaryFrame:InitiateScan()
    local message = fullFrame and fullFrame.NextScanMessage and fullFrame:NextScanMessage()
    return true, message and ("Full scan on cooldown, running a summary scan. " .. message) or nil
  end
  return false, "Auctionator's scanner isn't ready yet. Try again in a moment."
end

function Data.FormatAge(timestamp)
  local seconds = time() - timestamp
  if seconds < 60 then
    return "just now"
  elseif seconds < 3600 then
    return math.floor(seconds / 60) .. "m ago"
  elseif seconds < 86400 then
    return math.floor(seconds / 3600) .. "h " .. math.floor((seconds % 3600) / 60) .. "m ago"
  end
  return math.floor(seconds / 86400) .. "d ago"
end
