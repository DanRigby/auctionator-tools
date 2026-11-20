-- Run from the repository root with Lua 5.1 or later.
local function harness(legacy)
  local h = { available = { [2] = true }, reads = {}, requests = {}, messages = {}, events = {},
    totalReads = 0, totalRequests = 0, maxTimerReads = 0, maxTimerRequests = 0 }
  local now, timers = 0, {}
  function GetTime() return now end
  function time() return 100 * 86400 end
  local function itemInfo(id)
    h.totalReads = h.totalReads + 1
    h.reads[id] = (h.reads[id] or 0) + 1
    if h.available[id] then
      return "Item " .. id, "item:" .. id, 2, 1, 1, nil, nil, 1, nil, nil, 1000, 4, 0
    end
  end
  GetItemInfo = itemInfo
  C_Item = not legacy and {
    GetItemInfo = itemInfo,
    RequestLoadItemDataByID = function(id)
      h.totalRequests = h.totalRequests + 1
      h.requests[id] = (h.requests[id] or 0) + 1
      if h.onRequest then h.onRequest(id) end
    end,
  } or nil
  C_Timer = {
    NewTimer = function(delay, callback)
      local timer = { at = now + delay, callback = callback }
      function timer:Cancel() self.cancelled = true end
      table.insert(timers, timer)
      return timer
    end,
  }
  function h.advance(seconds)
    local target = now + seconds
    while true do
      local first
      for i, timer in ipairs(timers) do
        if not timer.cancelled and timer.at <= target and (not first or timer.at < timers[first].at) then
          first = i
        end
      end
      if not first then break end
      local timer = table.remove(timers, first)
      now = timer.at
      local reads, requests = h.totalReads, h.totalRequests
      timer.callback()
      h.maxTimerReads = math.max(h.maxTimerReads, h.totalReads - reads)
      h.maxTimerRequests = math.max(h.maxTimerRequests, h.totalRequests - requests)
    end
    now = target
  end
  Enum = {}
  C_AuctionHouse = nil
  Auctionator = {
    API = { v1 = {
      GetDisenchantPriceByItemID = function() return 1000 end,
      GetAuctionPriceByItemID = function() return 1000 end,
      GetAuctionAgeByItemID = function() return 0 end,
    } },
    Constants = { SCAN_DAY_0 = 0 },
    Database = { db = {} },
  }
  for id = 1, 3 do
    Auctionator.Database.db[tostring(id)] = { h = { [99] = 1000, [98] = 1000, [97] = 1000 } }
  end
  local AT = {
    db = { historyDays = 14, views = {
      vendor = { minProfit = 1, mode = "buyout" },
      deals = { minProfit = 1, mode = "buyout", maxBuyout = 50000, discount = 30 },
      disenchant = { minProfit = 1 },
    } },
    Buy = { exhausted = {} },
    MIN_HISTORY_DAYS = 3,
    CALLER_ID = "test",
  }
  function AT.OnEvent(event, callback) h.events[event] = callback end
  function AT.Send(event, payload)
    h.messages[event] = h.messages[event] or {}
    table.insert(h.messages[event], payload or true)
  end
  function AT.AHCut() return 0.95 end
  function AT.VendorBuyPrice() end
  function AT.RunJob(_, job, onDone) onDone(job()) end
  function AT.MaybeYield() end
  assert(loadfile("AuctionatorTools/Data.lua"))("AuctionatorTools", AT)
  assert(loadfile("AuctionatorTools/Analysis.lua"))("AuctionatorTools", AT)
  h.AT = AT
  function h.count(event) return #(h.messages[event] or {}) end
  function h.counts(missing, loading, unavailable)
    local actualLoading, actualUnavailable = AT.Data.ItemLoadCounts(missing)
    assert(actualLoading == loading and actualUnavailable == unavailable,
      string.format("expected %d loading/%d unavailable, got %d/%d",
        loading, unavailable, actualLoading, actualUnavailable))
  end
  return h
end

for _, view in ipairs({ "vendor", "deals", "disenchant" }) do
  local h = harness()
  local rows = {}
  for i = 1, 50 do
    rows[i] = { replicateInfo = { [3] = 1, [10] = 100, [17] = 1 } }
  end
  rows[51] = { replicateInfo = { [3] = 1, [10] = 100, [17] = 2 } }
  rows[52] = { replicateInfo = { [3] = 1, [10] = 100, [17] = 3 } }
  h.AT.Data.full = { time = time(), rows = rows }
  local found, meta
  local function run()
    h.AT.Analysis.Run(view, function(result, resultMeta) found, meta = result, resultMeta end)
  end
  run()
  assert(#found == 1 and found[1].itemID == 2, view .. " must retain available results")
  assert(h.requests[1] == 1 and h.reads[1] == 1, "duplicate listings must share one missing-item lookup")
  h.counts(meta.missingItems, 2, 0)
  h.events.ITEM_DATA_LOAD_RESULT(3, false)
  assert(h.requests[3] == 1 and h.count("ItemDataLoaded") == 0,
    "failures must not immediately retry or rebuild lists")
  h.events.ITEM_DATA_LOAD_RESULT(1, true)
  h.counts(meta.missingItems, 2, 0)
  assert(h.count("ItemDataLoaded") == 0, "a success event must not complete an item whose info is still missing")

  h.available[1] = true
  h.events.ITEM_DATA_LOAD_RESULT(1, true)
  h.events.GET_ITEM_INFO_RECEIVED(1, true)
  h.advance(0.5)
  assert(h.count("ItemDataLoaded") == 1, "duplicate completion events must produce one update")
  assert(h.messages.ItemDataLoaded[1][1] and not h.messages.ItemDataLoaded[1][3],
    "updates must name only successfully loaded IDs")
  run()
  assert(#found == 2, view .. " must populate newly loaded rows")
  h.counts(meta.missingItems, 1, 0)
  h.advance(16)
  assert(h.requests[3] == 3, "missing items must have bounded retries")
  h.counts(meta.missingItems, 0, 1)
  assert(h.count("ItemLoadStateChanged") == 1 and h.count("ItemDataLoaded") == 1,
    "exhaustion must update status without rebuilding the list")
  h.advance(30)
  assert(h.requests[3] == 3, "exhausted requests must stop")

  h.available[3] = true
  h.events.GET_ITEM_INFO_RECEIVED(3, true)
  h.advance(0.5)
  h.counts(meta.missingItems, 0, 0)
  assert(h.count("ItemDataLoaded") == 2, "late successes must still update affected views")
  run()
  assert(#found == 3, view .. " must recover late-loading rows")
end

h = harness()
local missing = {}
h.AT.Data.Item(1, missing)
h.advance(16)
h.counts(missing, 0, 1)
h.available[1] = true
h.advance(30.5)
h.counts(missing, 0, 0)
assert(h.requests[1] == 3 and h.count("ItemDataLoaded") == 1,
  "silent metadata arriving after retry exhaustion must be discovered without another request")

h = harness()
missing = {}
for id = 1000, 1069 do h.AT.Data.Item(id, missing) end
h.advance(20)
h.counts(missing, 0, 70)
h.available[1069] = true
h.advance(31)
h.counts(missing, 0, 69)
assert(h.count("ItemDataLoaded") == 1 and h.maxTimerReads <= 64,
  "exhausted-item recovery must probe large backlogs in bounded batches")

for _, view in ipairs({ "crafting", "resale" }) do
  local h = harness()
  h.AT.db.views[view] = { minProfit = 1 }
  h.AT.db.vendorPrices = { [1] = { u = 100 }, [2] = { u = 100 } }
  h.AT.char = { professions = { Test = { recipes = {
    [1] = { out = 1, yield = 2, reagents = { { id = 3, n = 1 } } },
    [2] = { out = 2, yield = 2, reagents = { { id = 3, n = 1 } } },
  } } } }
  local found, meta
  local function run()
    h.AT.Analysis.Run(view, function(result, resultMeta) found, meta = result, resultMeta end)
  end
  run()
  assert(#found == 1 and meta.missingItems[1], view .. " must track missing items independently of auction scans")
  h.available[1] = true
  h.events.ITEM_DATA_LOAD_RESULT(1, true)
  h.advance(0.5)
  run()
  assert(#found == 2, view .. " must populate newly loaded items")
end

local h = harness(true)
local missing = {}
assert(h.AT.Data.Item(1, missing) == nil)
h.available[1] = true
h.events.GET_ITEM_INFO_RECEIVED(1, true)
h.advance(0.5)
assert(h.AT.Data.Item(1).name == "Item 1" and h.count("ItemDataLoaded") == 1,
  "legacy item-info events must complete loads without C_Item")
h.AT.Data.Item(3, missing)
h.advance(20)
h.counts(missing, 0, 1)

h = harness()
missing = {}
for id = 10, 17 do h.AT.Data.Item(id, missing) end
for id = 10, 16 do
  h.advance(3)
  h.available[id] = true
  h.events.ITEM_DATA_LOAD_RESULT(id, true)
end
h.counts(missing, 1, 0)
assert(h.requests[17] == 1, "slow bulk loads must not retry while successful arrivals continue")
h.advance(20)
h.counts(missing, 0, 1)

h = harness()
missing = {}
for _, id in ipairs({ 1, 10, 11, 12 }) do h.AT.Data.Item(id, missing) end
for id = 10, 12 do
  h.available[id] = true
  h.advance(5)
end
h.counts(missing, 1, 0)
assert(h.requests[1] == 1, "silent successes later in the batch must defer retries of earlier misses")
h.advance(20)
h.counts(missing, 0, 1)

h = harness()
missing = {}
h.AT.Data.Item(1, missing)
for id = 1000, 1024 do
  h.advance(4)
  h.AT.Data.Item(id, missing)
  h.available[id] = true
  h.events.ITEM_DATA_LOAD_RESULT(id, true)
end
h.counts(missing, 0, 1)
assert(h.requests[1] == 3, "continuous unrelated successes must not indefinitely postpone retries")

h = harness()
missing = {}
for id = 1000, 5999 do h.AT.Data.Item(id, missing) end
h.advance(30)
h.counts(missing, 0, 5000)
assert(h.requests[1000] == 3 and h.requests[5999] == 3,
  "every item in a large backlog must be retried and eventually exhausted")
assert(h.maxTimerReads <= 64 and h.maxTimerRequests <= 64,
  "timeout callbacks must bound item lookups and retry requests")

h = harness()
missing = {}
for id = 1000, 1499 do
  h.AT.Data.Item(id, missing)
  h.available[id] = true
  h.events.ITEM_DATA_LOAD_RESULT(id, true)
end
h.AT.Data.Item(1, missing)
h.advance(20)
h.counts(missing, 0, 1)
assert(h.requests[1] == 3, "completed queue entries must not block later pending items")
assert(h.requests[1000] == 1, "completed queue entries must not be retried")

h = harness()
missing = {}
for id = 1000, 1063 do
  h.AT.Data.Item(id, missing)
  h.available[id] = true
  h.events.ITEM_DATA_LOAD_RESULT(id, true)
end
h.AT.Data.Item(1, missing)
h.advance(5)
assert(h.requests[1] == 1 and h.reads[1] == 1,
  "stale entries must count toward the per-callback batch limit")
h.advance(0.05)
assert(h.requests[1] == 2, "remaining work must run in a later timer callback")

h = harness()
missing = {}
h.onRequest = function(id)
  h.available[id] = true
  h.events.ITEM_DATA_LOAD_RESULT(id, true)
end
h.AT.Data.Item(1, missing)
h.advance(20)
h.counts(missing, 0, 0)
assert(h.requests[1] == 1 and h.count("ItemDataLoaded") == 1,
  "a synchronous load event must clear the pending request without retrying")

h = harness()
missing = {}
for id = 1000, 1063 do h.AT.Data.Item(id, missing) end
h.onRequest = function(id)
  h.available[id] = true
  h.events.ITEM_DATA_LOAD_RESULT(id, true)
  h.events.GET_ITEM_INFO_RECEIVED(id, true)
end
h.advance(5.5)
h.counts(missing, 0, 0)
assert(h.requests[1000] == 2 and h.requests[1063] == 2 and h.count("ItemDataLoaded") == 1,
  "synchronous retry successes must not duplicate requests or notifications")
assert(h.maxTimerReads <= 128 and h.maxTimerRequests <= 64,
  "synchronous retry events must still process only one bounded batch")

h = harness()
missing = {}
for id = 10, 109 do h.AT.Data.Item(id, missing) end
for id = 10, 108 do
  h.available[id] = true
  h.events.ITEM_DATA_LOAD_RESULT(id, true)
end
h.events.GET_ITEM_INFO_RECEIVED(999, true)
assert(not h.reads[999], "unrelated item events must not trigger lookups")
h.advance(0.5)
h.counts(missing, 1, 0)
assert(h.count("ItemDataLoaded") == 1, "bulk arrivals must be batched without waiting for one unresponsive item")
h.advance(20)
assert(h.count("ItemDataLoaded") == 1, "retries of the remaining item must not rebuild completed results")

h = harness()
missing = {}
h.AT.Data.Item(1, missing)
h.available[1] = true
h.advance(5.5)
h.counts(missing, 0, 0)
assert(h.count("ItemDataLoaded") == 1, "timeout checks must recover successful loads with no completion event")

h = harness()
local completed
h.AT.Data.full = { time = time(), rows = {
  { replicateInfo = { [3] = 1, [10] = 100, [17] = 1 } },
  { replicateInfo = { [3] = 1, [10] = 100, [17] = 2 } },
} }
local co
function h.AT.RunJob(_, job, onDone)
  co = coroutine.create(function() onDone(job()) end)
end
function h.AT.MaybeYield(i) if i == 2 then coroutine.yield() end end
missing = h.AT.Analysis.Run("vendor", function(_, meta) completed = meta end)
assert(coroutine.resume(co))
assert(missing[1])
h.AT.Data.Item(999)
assert(not missing[999], "tooltip lookups between frames must not contaminate analysis dependencies")
assert(coroutine.resume(co))
assert(completed.missingItems == missing and not completed.missingItems[999])

print("Item loading tests passed")
