local _, AT = ...

-- Every purchase starts with a live search, so only listings that are still
-- profitable right now are offered. Each buy needs its own click.
local Buy = { state = "idle", text = nil, exhausted = {} }
AT.Buy = Buy

local SEARCH_TIMEOUT = 10
local PLACE_TIMEOUT = 8
local MAX_FAILURES = 3

local request, candidates, offer
local bought = {}
local skipped = {}
local timer

local function StopTimer()
  if timer then
    timer:Cancel()
    timer = nil
  end
end

local function SetState(state, text)
  Buy.state = state
  Buy.text = text
  Buy.mode = request and request.mode
  AT.Send("BuyStateChanged")
end

local function Finish(text)
  StopTimer()
  request, candidates, offer = nil, nil, nil
  SetState("idle", text)
end

local function StartTimer(seconds, message)
  StopTimer()
  timer = C_Timer.NewTimer(seconds, function()
    timer = nil
    if Buy.state == "commodityPending" or Buy.state == "commodityConfirm" then
      C_AuctionHouse.CancelCommoditiesPurchase()
    end
    Finish(message)
  end)
end

local function Describe(qty, price, profitEach)
  local verb = request.mode == "bid" and "Bid on" or "Buy"
  return string.format("%s %dx %s for %s (profit each %s)", verb, qty, request.link or request.name,
    AT.FormatMoney(price), AT.FormatMoney(profitEach))
end

local function Exhausted()
  local view = request.view or "none"
  Buy.exhausted[view] = Buy.exhausted[view] or {}
  Buy.exhausted[view][request.itemID] = true
  AT.Send("ItemExhausted", view, request.itemID)
  Finish("No more profitable listings for " .. request.name .. ".")
end

local function Search()
  local sortOrder = request.mode == "bid" and Enum.AuctionHouseSortOrder.Bid or Enum.AuctionHouseSortOrder.Price
  local sorts = { { sortOrder = sortOrder, reverseSort = false } }
  local itemKey = C_AuctionHouse.MakeItemKey(request.itemID)
  SetState("searching", "Searching for " .. request.name .. "...")
  StartTimer(SEARCH_TIMEOUT, "The search timed out. Try again.")
  if request.commodity then
    Auctionator.AH.SendSearchQueryByItemKey(itemKey, sorts, false)
  else
    Auctionator.AH.SendSellSearchQueryByItemKey(itemKey, sorts, false)
  end
end

local function IsPlayer(guid)
  if not guid then
    return false
  end
  local ok, same = pcall(function()
    return guid == UnitGUID("player")
  end)
  return ok and same
end

local function ShowNextCandidate()
  offer = table.remove(candidates, 1)
  if not offer then
    Exhausted()
    return
  end
  SetState("offer", Describe(offer.qty, offer.price, offer.profit))
end

local function ProcessItemResults(itemKey)
  candidates = {}
  for index = 1, C_AuctionHouse.GetNumItemSearchResults(itemKey) do
    local info = C_AuctionHouse.GetItemSearchResultInfo(itemKey, index)
    if info and not info.containsOwnerItem and not bought[info.auctionID] and not skipped[info.auctionID] then
      local price
      if request.mode == "bid" then
        if info.minBid and not IsPlayer(info.bidder) then
          price = info.minBid
        end
      else
        price = info.buyoutAmount
      end
      local qty = info.quantity or 1
      if price and price > 0 and qty > 0
        and (not request.maxBuyout or (info.buyoutAmount and info.buyoutAmount > 0 and info.buyoutAmount <= request.maxBuyout))
        and (not request.maxUnitPrice or price / qty <= request.maxUnitPrice) then
        local profitEach = request.unitValue - price / qty
        if profitEach >= request.minProfit then
          table.insert(candidates, { auctionID = info.auctionID, price = price, qty = qty, profit = profitEach })
        end
      end
    end
  end
  table.sort(candidates, function(a, b)
    return a.profit > b.profit
  end)
  ShowNextCandidate()
end

local function ProcessCommodityResults(itemID)
  local money = GetMoney()
  if request.maxBuyout then
    money = math.min(money, request.maxBuyout)
  end
  local qty, total = 0, 0
  for index = 1, C_AuctionHouse.GetNumCommoditySearchResults(itemID) do
    local info = C_AuctionHouse.GetCommoditySearchResultInfo(itemID, index)
    if not info or not info.unitPrice or info.unitPrice <= 0
      or info.unitPrice > request.unitValue - request.minProfit
      or (request.maxUnitPrice and info.unitPrice > request.maxUnitPrice) then
      break
    end
    local available = info.quantity - (info.numOwnerItems or 0)
    local affordable = math.floor((money - total) / info.unitPrice)
    local take = math.min(available, affordable)
    if take > 0 then
      qty = qty + take
      total = total + take * info.unitPrice
    end
    if affordable <= available then
      break
    end
  end
  local profitEach = qty > 0 and (request.unitValue * qty - total) / qty or 0
  if qty == 0 or profitEach < request.minProfit then
    Exhausted()
    return
  end
  offer = { qty = qty, price = total, profit = profitEach }
  SetState("offer", Describe(qty, total, profitEach))
end

local listener = {}
function listener:ReceiveEvent(eventName, eventData)
  if Buy.state ~= "searching" or not request then
    return
  end
  if eventName == Auctionator.AH.Events.ItemSearchResultsReady and not request.commodity
    and eventData and eventData.itemID == request.itemID then
    StopTimer()
    ProcessItemResults(eventData)
  elseif eventName == Auctionator.AH.Events.CommoditySearchResultsReady and request.commodity
    and eventData == request.itemID then
    StopTimer()
    ProcessCommodityResults(eventData)
  end
end
Auctionator.EventBus:Register(listener, {
  Auctionator.AH.Events.ItemSearchResultsReady,
  Auctionator.AH.Events.CommoditySearchResultsReady,
})

local function AttemptFailed(message)
  request.failures = request.failures + 1
  if request.failures >= MAX_FAILURES then
    Finish(message)
  else
    Search()
  end
end

-- request: { view, itemID, name, link, mode, unitValue, minProfit, maxBuyout, maxUnitPrice }
function Buy.Start(newRequest)
  if not AT.ahOpen then
    Finish("Open the auction house to buy.")
    return
  end
  Buy.Cancel(true)
  skipped = {}
  request = newRequest
  request.failures = 0
  request.commodity = request.mode ~= "bid" and AT.Data.IsCommodity(request.itemID)
  Search()
end

function Buy.Confirm()
  if not request or not offer then
    return
  end
  if Buy.state == "offer" then
    if GetMoney() < offer.price then
      Finish("Not enough money.")
      return
    end
    if request.commodity then
      SetState("commodityPending", "Checking the final price...")
      StartTimer(PLACE_TIMEOUT, "The auction house didn't respond. Try again.")
      C_AuctionHouse.StartCommoditiesPurchase(request.itemID, offer.qty)
    else
      bought[offer.auctionID] = true
      SetState("placing", (request.mode == "bid" and "Bidding" or "Buying") .. "...")
      StartTimer(PLACE_TIMEOUT, "The auction house didn't respond. Try again.")
      C_AuctionHouse.PlaceBid(offer.auctionID, offer.price)
    end
  elseif Buy.state == "commodityConfirm" then
    SetState("placing", "Buying...")
    StartTimer(PLACE_TIMEOUT, "The auction house didn't respond. Try again.")
    C_AuctionHouse.ConfirmCommoditiesPurchase(request.itemID, offer.qty)
  end
end

function Buy.Skip()
  if Buy.state == "offer" and candidates and not request.commodity then
    skipped[offer.auctionID] = true
    ShowNextCandidate()
  else
    Buy.Cancel()
  end
end

function Buy.Cancel(silent)
  if Buy.state == "commodityPending" or Buy.state == "commodityConfirm" then
    C_AuctionHouse.CancelCommoditiesPurchase()
  end
  if Buy.state ~= "idle" then
    Finish(not silent and "Cancelled." or nil)
  end
end

AT.OnEvent("COMMODITY_PRICE_UPDATED", function(unitPrice, totalPrice)
  if Buy.state ~= "commodityPending" then
    return
  end
  StopTimer()
  local profitEach = (request.unitValue * offer.qty - totalPrice) / offer.qty
  if profitEach >= request.minProfit and totalPrice <= GetMoney()
    and (not request.maxBuyout or totalPrice <= request.maxBuyout)
    and (not request.maxUnitPrice or totalPrice / offer.qty <= request.maxUnitPrice) then
    offer.price = totalPrice
    offer.profit = profitEach
    SetState("commodityConfirm", "Confirm: " .. Describe(offer.qty, totalPrice, profitEach))
  else
    C_AuctionHouse.CancelCommoditiesPurchase()
    AttemptFailed("The price changed and is no longer profitable.")
  end
end)

AT.OnEvent("COMMODITY_PRICE_UNAVAILABLE", function()
  if Buy.state == "commodityPending" then
    StopTimer()
    C_AuctionHouse.CancelCommoditiesPurchase()
    AttemptFailed("The price is no longer available.")
  end
end)

local function Succeeded()
  if Buy.state == "placing" then
    StopTimer()
    AT.Print((request.mode == "bid" and "Bid placed: " or "Bought: ") .. offer.qty .. "x " .. (request.link or request.name))
    AT.Send("Purchased", request.itemID)
    Search()
  end
end

local function Failed()
  if Buy.state == "placing" then
    StopTimer()
    if offer.auctionID then
      bought[offer.auctionID] = nil
    end
    AttemptFailed("The purchase failed.")
  end
end

AT.OnEvent("COMMODITY_PURCHASE_SUCCEEDED", Succeeded)
AT.OnEvent("AUCTION_HOUSE_PURCHASE_COMPLETED", Succeeded)
AT.OnEvent("BID_ADDED", Succeeded)
AT.OnEvent("COMMODITY_PURCHASE_FAILED", Failed)
AT.OnEvent("AUCTION_HOUSE_SHOW_ERROR", Failed)

AT.Listen("AHStateChanged", function()
  if not AT.ahOpen then
    Buy.Cancel(true)
  end
end)

AT.Listen("ScanUpdated", function()
  wipe(Buy.exhausted)
end)
