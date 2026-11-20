local events = {}
local itemResults = {}
local commodityResults = {}
local commodity = false

local AT = {
  ahOpen = true,
  Data = { IsCommodity = function() return commodity end },
}
function AT.OnEvent(event, callback) events[event] = callback end
function AT.Listen() end
function AT.Send() end
function AT.FormatMoney(value) return tostring(value) end

Enum = { AuctionHouseSortOrder = { Price = "price", Bid = "bid" } }
Auctionator = {
  AH = {
    Events = {
      ItemSearchResultsReady = "items-ready",
      CommoditySearchResultsReady = "commodities-ready",
    },
    SendSellSearchQueryByItemKey = function() end,
    SendSearchQueryByItemKey = function() end,
  },
  EventBus = { Register = function(_, listener) Auctionator.listener = listener end },
}
C_Timer = {
  NewTimer = function()
    return { Cancel = function() end }
  end,
}
C_AuctionHouse = {
  MakeItemKey = function(itemID) return itemID end,
  GetNumItemSearchResults = function() return #itemResults end,
  GetItemSearchResultInfo = function(_, index) return itemResults[index] end,
  GetNumCommoditySearchResults = function() return #commodityResults end,
  GetCommoditySearchResultInfo = function(_, index) return commodityResults[index] end,
  StartCommoditiesPurchase = function() end,
  CancelCommoditiesPurchase = function() end,
}
function GetMoney() return 100000 end

assert(loadfile("AuctionatorTools/Buy.lua"))("AuctionatorTools", AT)

local function searchResults(info, mode)
  itemResults = { info }
  AT.Buy.Start({
    view = "test",
    itemID = 1,
    name = "Test item",
    mode = mode or "buyout",
    unitValue = 1000,
    minProfit = 500,
  })
  Auctionator.listener:ReceiveEvent("items-ready", { itemID = 1 })
end

searchResults({ auctionID = 1, quantity = 10, buyoutAmount = 6000 })
assert(AT.Buy.state == "idle", "a stack's total profit must not satisfy the per-item threshold")

searchResults({ auctionID = 2, quantity = 10, buyoutAmount = 4000 })
assert(AT.Buy.state == "offer" and AT.Buy.text:find("profit each 600", 1, true),
  "buy offers must report per-item profit")
AT.Buy.Cancel(true)

searchResults({ auctionID = 3, quantity = 10, minBid = 6000 }, "bid")
assert(AT.Buy.state == "idle", "bid offers must use the per-item threshold")

commodity = true
commodityResults = { { unitPrice = 600, quantity = 10 } }
AT.Buy.Start({
  view = "test",
  itemID = 2,
  name = "Test commodity",
  mode = "buyout",
  unitValue = 1000,
  minProfit = 500,
})
Auctionator.listener:ReceiveEvent("commodities-ready", 2)
assert(AT.Buy.state == "idle", "commodity stacks must use the per-item threshold")

commodityResults = { { unitPrice = 400, quantity = 10 } }
AT.Buy.Start({
  view = "test",
  itemID = 2,
  name = "Test commodity",
  mode = "buyout",
  unitValue = 1000,
  minProfit = 500,
})
Auctionator.listener:ReceiveEvent("commodities-ready", 2)
assert(AT.Buy.state == "offer" and AT.Buy.text:find("profit each 600", 1, true),
  "commodity offers must report per-item profit")
AT.Buy.Confirm()
events.COMMODITY_PRICE_UPDATED(0, 5000)
assert(AT.Buy.state == "commodityConfirm" and AT.Buy.text:find("profit each 500", 1, true),
  "commodity confirmation must recheck profit per item")

print("Buy per-item profit tests passed")
