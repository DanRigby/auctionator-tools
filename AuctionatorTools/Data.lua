local _, AT = ...

local Data = {}
AT.Data = Data

local API = Auctionator.API.v1
local GetItemInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
local RequestLoadItem = C_Item and C_Item.RequestLoadItemDataByID
local SUMMARY_PREFERENCE_SECONDS = 15 * 60
local MAX_LOAD_ATTEMPTS = 3
local ITEM_LOAD_TIMEOUT = 5
local MAX_PROGRESS_GRACE = 60
local LOAD_BATCH_SIZE = 64
local LOAD_BATCH_DELAY = 0.05

-- Static item info never changes, so it is cached for the session
local itemCache = {}
local loadAttempts = {}
local pendingLoads = {}
local loadQueue, queueHead, queueTail = {}, 1, 0
local loadTimer, notifyTimer, stateTimer
local checkingLoads = false
local lastProgress = 0
local changedItems = {}

local function NotifyLoaded(itemID)
  changedItems[itemID] = true
  -- A fixed batching window also flushes during a steady stream of arrivals.
  if not notifyTimer then
    notifyTimer = C_Timer.NewTimer(0.5, function()
      notifyTimer = nil
      local changed = changedItems
      changedItems = {}
      AT.Send("ItemDataLoaded", changed)
    end)
  end
end

local function NotifyLoadStateChanged()
  if not stateTimer then
    stateTimer = C_Timer.NewTimer(0.5, function()
      stateTimer = nil
      AT.Send("ItemLoadStateChanged")
    end)
  end
end

local function CacheItem(itemID)
  local name, link, quality, _, _, _, _, maxStack, _, icon, sellPrice, classID, subclassID = GetItemInfo(itemID)
  if not name then
    return nil
  end
  local cached = {
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
  if loadAttempts[itemID] then
    pendingLoads[itemID] = nil
    loadAttempts[itemID] = nil
    lastProgress = GetTime()
    NotifyLoaded(itemID)
  end
  return cached
end

local CheckPendingLoads

local function ScheduleLoadCheck()
  if not checkingLoads and not loadTimer and queueHead <= queueTail then
    local delay = math.max(LOAD_BATCH_DELAY, loadQueue[queueHead].deadline - GetTime())
    loadTimer = C_Timer.NewTimer(delay, CheckPendingLoads)
  end
end

local function QueueLoad(itemID, started)
  local entry = { itemID = itemID, started = started, deadline = GetTime() + ITEM_LOAD_TIMEOUT }
  pendingLoads[itemID] = entry
  queueTail = queueTail + 1
  loadQueue[queueTail] = entry
  ScheduleLoadCheck()
end

local function RequestItem(itemID, started)
  loadAttempts[itemID] = (loadAttempts[itemID] or 0) + 1
  QueueLoad(itemID, started or GetTime())
  if RequestLoadItem then
    RequestLoadItem(itemID)
  end
end

CheckPendingLoads = function()
  loadTimer = nil
  checkingLoads = true
  local now = GetTime()
  local batch = {}
  for _ = 1, LOAD_BATCH_SIZE do
    local entry = loadQueue[queueHead]
    if not entry or entry.deadline > now then
      break
    end
    loadQueue[queueHead] = nil
    queueHead = queueHead + 1
    local itemID = entry.itemID
    if pendingLoads[itemID] == entry then
      CacheItem(itemID)
      table.insert(batch, entry)
    end
  end
  local unavailable = false
  local makingProgress = now - lastProgress < ITEM_LOAD_TIMEOUT
  for _, entry in ipairs(batch) do
    local itemID = entry.itemID
    if pendingLoads[itemID] == entry then
      -- Allow slow bulk loads to progress, but never postpone an item forever.
      if makingProgress and now - entry.started < MAX_PROGRESS_GRACE then
        QueueLoad(itemID, entry.started)
      elseif loadAttempts[itemID] < MAX_LOAD_ATTEMPTS then
        RequestItem(itemID, entry.started)
      else
        pendingLoads[itemID] = nil
        unavailable = true
      end
    end
  end
  if queueHead > queueTail then
    queueHead, queueTail = 1, 0
  end
  checkingLoads = false
  if unavailable then
    NotifyLoadStateChanged()
  end
  ScheduleLoadCheck()
end

function Data.Item(itemID, missingItems)
  local cached = itemCache[itemID]
  if cached then
    return cached
  end
  if missingItems and missingItems[itemID] then
    return nil
  end
  cached = CacheItem(itemID)
  if cached then
    return cached
  end
  if missingItems then
    missingItems[itemID] = true
  end
  if not pendingLoads[itemID] and (loadAttempts[itemID] or 0) < MAX_LOAD_ATTEMPTS then
    RequestItem(itemID)
  end
  return nil
end

function Data.ItemLoadCounts(missingItems)
  local loading, unavailable = 0, 0
  for itemID in pairs(missingItems or {}) do
    if not itemCache[itemID] then
      if pendingLoads[itemID] then
        loading = loading + 1
      else
        unavailable = unavailable + 1
      end
    end
  end
  return loading, unavailable
end

local function OnItemLoadResult(itemID, success)
  if success ~= false and loadAttempts[itemID] then
    CacheItem(itemID)
  end
end
AT.OnEvent("ITEM_DATA_LOAD_RESULT", OnItemLoadResult)
AT.OnEvent("GET_ITEM_INFO_RECEIVED", OnItemLoadResult)

local commodityCache = {}
function Data.IsCommodity(itemID, missingItems)
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
    local item = Data.Item(itemID, missingItems)
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

-- Lowest daily low, highest daily high and mean daily low, including today
local statsCache = {}

function Data.PriceStats(itemID)
  local cached = statsCache[itemID]
  if cached ~= nil then
    return cached or nil
  end
  local result = false
  local db = Auctionator.Database and Auctionator.Database.db
  local entry = db and db[tostring(itemID)]
  if entry and entry.h then
    local today = math.floor((time() - Auctionator.Constants.SCAN_DAY_0) / 86400)
    local lows, highs = entry.l or {}, entry.h
    local minPrice, maxPrice, total, count
    for day = today, today - AT.db.historyDays + 1, -1 do
      local key = tostring(day)
      local high = highs[day] or highs[key]
      local low = lows[day] or lows[key] or high
      high = high or low
      if low then
        count = (count or 0) + 1
        total = (total or 0) + low
        minPrice = math.min(minPrice or low, low)
        maxPrice = math.max(maxPrice or high, high)
      end
    end
    if count then
      result = { min = minPrice, max = maxPrice, avg = math.floor(total / count + 0.5), days = count }
    end
  end
  statsCache[itemID] = result
  return result or nil
end

function Data.ClearPriceCache()
  wipe(marketCache)
  wipe(statsCache)
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
