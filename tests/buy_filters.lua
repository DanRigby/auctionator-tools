-- Run from the repository root with Lua 5.1 or later.
local events, itemResults, commodityResults = {}, {}, {}
local commodity = false
local placed, commodityQuantity, cancelled

local AT = {
  ahOpen = true,
  Data = { IsCommodity = function() return commodity end },
}
function AT.OnEvent(event, callback) events[event] = callback end
function AT.Listen() end
function AT.Send() end
function AT.Print() end
function AT.FormatMoney(value) return tostring(value) end
function UnitGUID() return "player" end
function GetMoney() return 100000 end

Enum = { AuctionHouseSortOrder = { Price = "price", Bid = "bid" } }
Auctionator = {
  AH = {
    Events = { ItemSearchResultsReady = "items-ready", CommoditySearchResultsReady = "commodities-ready" },
    SendSellSearchQueryByItemKey = function() end,
    SendSearchQueryByItemKey = function() end,
  },
  EventBus = { Register = function(_, listener) Auctionator.listener = listener end },
}
C_Timer = { NewTimer = function() return { Cancel = function() end } end }
C_AuctionHouse = {
  MakeItemKey = function(itemID) return itemID end,
  GetNumItemSearchResults = function() return #itemResults end,
  GetItemSearchResultInfo = function(_, index) return itemResults[index] end,
  GetNumCommoditySearchResults = function() return #commodityResults end,
  GetCommoditySearchResultInfo = function(_, index) return commodityResults[index] end,
  PlaceBid = function(id) placed = id end,
  StartCommoditiesPurchase = function(_, qty) commodityQuantity = qty end,
  CancelCommoditiesPurchase = function() cancelled = (cancelled or 0) + 1 end,
}

assert(loadfile("AuctionatorTools/Buy.lua"))("AuctionatorTools", AT)

local function start(mode)
  AT.Buy.Start({
    view = "deals", itemID = 1, name = "Item", mode = mode or "buyout",
    unitValue = 1000, minProfit = 1, maxBuyout = 100, maxUnitPrice = 60,
  })
end
local function ready()
  Auctionator.listener:ReceiveEvent(commodity and "commodities-ready" or "items-ready",
    commodity and 1 or { itemID = 1 })
end

itemResults = {
  { auctionID = 1, quantity = 10, buyoutAmount = 101 },
  { auctionID = 2, quantity = 1, buyoutAmount = 61 },
  { auctionID = 3, quantity = 2, buyoutAmount = 100 },
}
start()
ready()
assert(AT.Buy.state == "offer", "a listing meeting both Deals limits should be offered")
AT.Buy.Confirm()
assert(placed == 3, "live listings exceeding either Deals limit must be excluded")
events.AUCTION_HOUSE_SHOW_ERROR()
ready()
AT.Buy.Confirm()
assert(placed == 3 and AT.Buy.state == "placing", "a failed purchase must remain eligible for retry")
events.AUCTION_HOUSE_SHOW_ERROR()
ready()
AT.Buy.Skip()
assert(AT.Buy.state == "idle", "skipping the only eligible listing should finish this search")
start()
ready()
assert(AT.Buy.state == "offer", "a skipped listing must be available in a new search")

itemResults = { { auctionID = 8, quantity = 1, buyoutAmount = 61 } }
start()
ready()
assert(AT.Buy.state == "idle", "a listing within the buyout cap must still meet the discount")

itemResults = {
  { auctionID = 4, quantity = 1, minBid = 10 },
  { auctionID = 5, quantity = 1, minBid = 10, buyoutAmount = 101 },
  { auctionID = 6, quantity = 1, minBid = 61, buyoutAmount = 100 },
  { auctionID = 7, quantity = 1, minBid = 20, buyoutAmount = 100 },
}
start("bid")
ready()
AT.Buy.Confirm()
assert(placed == 7, "bid searches must enforce the listing buyout and per-item discount limits")
events.BID_ADDED()
itemResults = { itemResults[4] }
start("bid")
ready()
assert(AT.Buy.state == "idle", "successfully submitted auctions must remain suppressed in new searches")

commodity = true
commodityResults = { { unitPrice = 40, quantity = 5 } }
start()
ready()
AT.Buy.Confirm()
assert(commodityQuantity == 2, "commodity purchases must not exceed the configured buyout cap")
events.COMMODITY_PRICE_UPDATED(0, 101)
assert(cancelled and AT.Buy.state == "searching", "a final commodity quote above the cap must be rejected")
ready()
AT.Buy.Confirm()
events.COMMODITY_PRICE_UPDATED(0, 100)
assert(AT.Buy.state == "commodityConfirm", "a final commodity quote within the limits must be offered")

commodityResults = { { unitPrice = 20, quantity = 2 } }
AT.Buy.Start({
  view = "deals", itemID = 1, name = "Item", mode = "buyout",
  unitValue = 1000, minProfit = 1, maxBuyout = 100, maxUnitPrice = 30,
})
ready()
AT.Buy.Confirm()
events.COMMODITY_PRICE_UPDATED(0, 80)
assert(AT.Buy.state == "searching", "a final commodity quote must still meet the discount")

print("Buy filter and retry tests passed")
