-- Run from the repository root with Lua 5.1 or later.
local money = 100
function GetMoney() return money end
Enum = {}

local scan
local events = {}
local AT = {
  db = { views = {
    deals = { minProfit = 1, discount = 30 },
    vendor = { minProfit = 1, mode = "buyout" },
  } },
  Buy = { exhausted = {} },
  Data = {
    GetScan = function() return scan.kind, scan end,
    MarketPrice = function() return 1000 end,
    Item = function(id) return { name = tostring(id), sell = 1000 } end,
  },
  AHCut = function() return 0.95 end,
  MaybeYield = function() end,
  RunJob = function(_, job, onDone) onDone(job()) end,
  OnEvent = function(event, callback) events[event] = callback end,
  Listen = function() end,
}

assert(loadfile("AuctionatorTools/Analysis.lua"))("AuctionatorTools", AT)
assert(loadfile("AuctionatorTools/UI.lua"))("AuctionatorTools", AT)

local function fullListing(id, quantity, buyout)
  local info = { [3] = quantity, [10] = buyout, [17] = id }
  return { replicateInfo = info }
end

local function run(view)
  local found
  AT.Analysis.Run(view, function(rows) found = rows end)
  local byID = {}
  for _, row in ipairs(found) do byID[row.itemID] = row end
  return byID
end

scan = { kind = "full", rows = {
  fullListing(1, 1, 100),
  fullListing(2, 1, 101),
  fullListing(3, 1, 60),
  fullListing(3, 1, 60),
  fullListing(3, 1, 40),
  fullListing(4, 2, 120),
} }
local rows = run("deals")
assert(rows[1] and rows[1].cost == 100, "exact balance must be affordable")
assert(not rows[2] and not rows[4], "unaffordable full listings must be excluded")
assert(rows[3] and rows[3].cost == 100 and rows[3].qty == 2,
  "grouped listings must not exceed the balance and later affordable listings must be included")
assert(run("vendor")[2], "other views must not be filtered")

money = 0
assert(next(run("deals")) == nil, "zero balance must exclude paid listings")

money = 100
scan = { kind = "summary", rows = {
  { itemKey = { itemID = 5 }, minPrice = 100 },
  { itemKey = { itemID = 6 }, minPrice = 101 },
} }
rows = run("deals")
assert(rows[5] and not rows[6], "summary prices must respect the balance")
money = 101
assert(run("deals")[6], "a higher balance must allow newly affordable items")

local function upvalue(fn, wanted)
  for i = 1, math.huge do
    local name, value = debug.getupvalue(fn, i)
    if not name then break end
    if name == wanted then return value end
  end
  error("missing upvalue: " .. wanted)
end
local dirty = upvalue(upvalue(events.PLAYER_MONEY, "MarkDirty"), "dirty")
for view in pairs(dirty) do dirty[view] = false end
events.PLAYER_MONEY()
assert(dirty.deals and not dirty.vendor and not dirty.resale,
  "money changes must invalidate only the deals view")
print("Deals affordability tests passed")
