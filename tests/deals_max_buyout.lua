-- Run from the repository root with Lua 5.1 or later.
local frames = {}
local methods = {}
function methods:SetScript(event, callback) self.scripts[event] = callback end
function methods:HookScript(event, callback) self.scripts[event] = callback end
function methods:RegisterEvent() end
function methods:SetSize() end
function methods:SetPoint() end
function methods:SetAutoFocus() end
function methods:SetNumeric() end
function methods:SetMaxLetters() end
function methods:SetShown(shown) self.shown = shown end
function methods:SetText(text) self.text = text end
function methods:GetText() return self.text end
function methods:CreateFontString() return setmetatable({ scripts = {} }, { __index = methods }) end
function CreateFrame()
  local frame = setmetatable({ scripts = {} }, { __index = methods })
  table.insert(frames, frame)
  return frame
end
function GetMoney() error("Deals must not depend on character money") end
Enum = {}
SlashCmdList = {}

local AT = {}
assert(loadfile("AuctionatorTools/Core.lua"))("AuctionatorTools", AT)
AUCTIONATOR_TOOLS_DB = { views = { deals = { discount = 40 } } }
frames[1].scripts.OnEvent(frames[1], "ADDON_LOADED", "AuctionatorTools")
assert(AT.db.views.deals.maxBuyout == 50000, "existing settings must receive the 5g default")
assert(AT.db.views.deals.discount == 40, "existing settings must be preserved")
AT.db.views.deals.maxBuyout = 100
frames[1].scripts.OnEvent(frames[1], "ADDON_LOADED", "AuctionatorTools")
assert(AT.db.views.deals.maxBuyout == 100, "saved maximum must survive initialization")

local scan
AT.Buy = { exhausted = {} }
AT.Data = {
  GetScan = function(needFull)
    AT.needFull = needFull
    if needFull and scan.kind ~= "full" then
      return nil, nil
    end
    return scan.kind, scan
  end,
  MarketPrice = function() return 1000 end,
  Item = function(id) return { name = tostring(id), sell = 1000, classID = 4, quality = 2 } end,
  DisenchantValue = function() return 1000 end,
  IsCommodity = function(id) return id == 13 end,
  CurrentPrice = function(id)
    if id == 50 then return 0 end
    return id == 51 and 6000 or 1000
  end,
  PriceAge = function() return 0 end,
}
AT.AHCut = function() return 0.95 end
AT.VendorBuyPrice = function() return nil end
AT.MaybeYield = function() end
AT.RunJob = function(_, job, onDone) onDone(job()) end

assert(loadfile("AuctionatorTools/Analysis.lua"))("AuctionatorTools", AT)
assert(loadfile("AuctionatorTools/UI.lua"))("AuctionatorTools", AT)

local function fullListing(id, quantity, buyout, currentBid, increment)
  return { replicateInfo = { [3] = quantity, [8] = 50, [9] = increment or 10, [10] = buyout,
    [11] = currentBid or 0, [12] = false, [17] = id } }
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
  fullListing(4, 2, 120),
} }
local rows = run("deals")
assert(rows[1] and rows[1].cost == 100, "the maximum must be inclusive")
assert(not rows[2] and not rows[4], "exclude full listings above the total-buyout limit")
assert(rows[3] and rows[3].cost == 120 and rows[3].qty == 2,
  "apply the limit to each listing, not the group total")
assert(rows[3].profit == 890, "Deals profit must be calculated per item")
assert(run("vendor")[2], "other views must not be filtered")

scan = { kind = "summary", rows = {
  { itemKey = { itemID = 5 }, minPrice = 100 },
  { itemKey = { itemID = 6 }, minPrice = 101 },
} }
rows = run("deals")
assert(rows[5] and not rows[6], "summary prices must respect the limit")
AT.db.views.deals.maxBuyout = 101
assert(run("deals")[6], "changing the maximum must update results")

AT.db.views.deals.minProfit = 400
AT.db.views.deals.maxBuyout = 10000
scan = { kind = "full", rows = { fullListing(9, 10, 5800) } }
assert(not run("deals")[9], "Deals min profit must apply per item, not to the total stack profit")
AT.db.views.deals.minProfit = 1
AT.db.views.deals.maxBuyout = 101

AT.db.views.deals.mode = "bid"
AT.Data.summary = scan
scan = { kind = "full", rows = { fullListing(7, 1, 100, 100, 10) } }
local bidRows = run("deals")
assert(AT.needFull, "bid mode must request a full scan")
assert(bidRows[7] and bidRows[7].cost == 110 and bidRows[7].buy.mode == "bid",
  "Deals bid mode must price and buy at the next bid")
local highestBidder = fullListing(12, 1, 100)
highestBidder.replicateInfo[12] = true
scan = { kind = "full", rows = { highestBidder, fullListing(13, 1, 100) } }
assert(not run("deals")[12], "Deals must not substitute a buyout when the player is the highest bidder")
assert(not run("deals")[13], "Deals must not offer bids on commodities")
AT.db.views.vendor.mode = "bid"
assert(not run("vendor")[12], "Below Vendor must not substitute a buyout for an unavailable bid")
AT.db.views.vendor.mode = "buyout"
scan = { kind = "summary", rows = { { itemKey = { itemID = 8 }, minPrice = 100 } } }
local noRows, meta
AT.Analysis.Run("deals", function(rows, resultMeta) noRows, meta = rows, resultMeta end)
assert(AT.needFull and #noRows == 0 and meta.needFull,
  "Deals bid mode must require a full scan")
AT.db.views.deals.mode = "buyout"

scan = { kind = "full", rows = {
  fullListing(20, 2, 100, 40, 10),
  fullListing(20, 2, 80),
} }
for _, view in ipairs({ "vendor", "deals" }) do
  AT.db.views[view].mode = "buyout"
  local buyoutRow = run(view)[20]
  assert(buyoutRow.unit == 45 and buyoutRow.cost == 180,
    "buyout mode must average buyout prices across stacks")
  AT.db.views[view].mode = "bid"
  local bidRow = run(view)[20]
  local saleValue = view == "deals" and 950 or 1000
  assert(bidRow.unit == 25 and bidRow.cost == 100 and bidRow.profit == saleValue - 25,
    "bid mode must use starting bids and next-bid increments for cost and profit")
  assert(buyoutRow.profit == saleValue - 45 and bidRow.profit - buyoutRow.profit == 20,
    "sale value must stay unchanged when comparing bid and buyout profit")
  if view == "deals" then
    assert(bidRow.discount == 0.975 and buyoutRow.discount == 0.955,
      "Deals discounts must use the selected acquisition price")
  end
  AT.db.views[view].mode = "buyout"
  assert(run(view)[20].profit == buyoutRow.profit, "switching back must restore buyout profit")
end

scan = { kind = "full", rows = {
  fullListing(10, 2, 100),
  fullListing(10, 2, 200),
  fullListing(11, 10, 6000),
} }
AT.db.views.vendor.minProfit = 500
local vendorRows = run("vendor")
assert(vendorRows[10] and vendorRows[10].profit == 925, "Vendor profit must be an average per item")
assert(not vendorRows[11], "Vendor min profit must apply per item")

AT.db.views.disenchant.minProfit = 400
local disenchantRows = run("disenchant")
assert(disenchantRows[10] and disenchantRows[10].profit == 875,
  "Disenchant profit must be calculated per item")
assert(not disenchantRows[11], "Disenchant min profit must apply per item")

AT.char.professions = {
  Test = { recipes = { [1] = { out = 50, yield = 10, reagents = { { id = 51, n = 1 } } } } },
}
AT.db.views.crafting.minProfit = 500
assert(#run("crafting") == 0, "Crafting min profit must apply per output item")
AT.db.views.crafting.minProfit = 400
local craftRows = run("crafting")
assert(craftRows[50] and craftRows[50].profit == 400,
  "Crafting profit must be calculated per output item")

AT.db.vendorPrices = { [60] = { u = 600, v = "Vendor" } }
AT.db.views.resale.minProfit = 350
local resaleRows = run("resale")
assert(resaleRows[60] and resaleRows[60].profit == 350,
  "Vendor resale profit must be calculated per item")

local function upvalue(fn, wanted)
  for i = 1, math.huge do
    local name, value = debug.getupvalue(fn, i)
    if not name then break end
    if name == wanted then return value end
  end
  error("missing upvalue: " .. wanted)
end
local create = upvalue(AT.UI.Show, "Create")
local createRow = upvalue(upvalue(create, "CreateList"), "CreateRow")
local startBuy = upvalue(createRow, "StartBuy")
local buyRequest
AT.Buy.Start = function(request) buyRequest = request end
AT.db.activeView = "deals"
AT.db.views.deals.discount = 40
AT.db.views.deals.maxBuyout = 100
startBuy({ itemID = 7, name = "Item", market = 1000, buy = { mode = "buyout", unitValue = 950 } })
assert(buyRequest.maxBuyout == 100 and buyRequest.maxUnitPrice == 600,
  "Deals must pass its buyout and discount limits to live searches")
AT.db.views.deals.maxBuyout = 101
local createFilters = upvalue(create, "CreateFilters")
local widgets = upvalue(createFilters, "widgets")
createFilters(CreateFrame())
local input = widgets.maxBuyout
local updateFilters = upvalue(widgets.mode.scripts.OnClick, "UpdateFilters")
AT.db.activeView = "deals"
updateFilters()
assert(input.shown and input.label.shown and input:GetText() == "1s 1c",
  "Deals must display the saved maximum")
assert(widgets.mode.shown, "the mode toggle must be available on Deals")
AT.db.activeView = "vendor"
updateFilters()
assert(not input.shown and not input.label.shown, "the maximum must be hidden in other views")
assert(widgets.mode.shown, "the mode toggle must remain available on Below Vendor")
AT.db.activeView = "disenchant"
updateFilters()
assert(not widgets.mode.shown, "the mode toggle must be hidden on unrelated views")
AT.db.activeView = "deals"
local dirty = upvalue(upvalue(input.scripts.OnEditFocusLost, "MarkDirty"), "dirty")
dirty.deals = false
input:SetText("2g 50s")
input.scripts.OnEditFocusLost(input)
assert(AT.db.views.deals.maxBuyout == 25000 and input:GetText() == "2g 50s",
  "editing the maximum must save and format it")
assert(dirty.deals, "editing the maximum must invalidate Deals")
input:SetText("invalid")
input.scripts.OnEditFocusLost(input)
assert(AT.db.views.deals.maxBuyout == 25000 and input:GetText() == "2g 50s",
  "invalid input must restore the saved maximum")
input:SetText("0")
input.scripts.OnEditFocusLost(input)
assert(AT.db.views.deals.maxBuyout == 0, "zero must be accepted")
frames[1].scripts.OnEvent(frames[1], "ADDON_LOADED", "AuctionatorTools")
assert(AT.db.views.deals.maxBuyout == 0, "the last entered value must persist")
print("Deals maximum buyout tests passed")
