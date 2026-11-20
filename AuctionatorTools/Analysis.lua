local _, AT = ...

local Data = AT.Data
local Analysis = {}
AT.Analysis = Analysis

local Builders = {}

-- Groups profitable listings of the same item into one row
local function AddListing(groups, itemID, qty, cost, unitValue, link)
  local group = groups[itemID]
  if not group then
    group = { id = itemID, itemID = itemID, qty = 0, cost = 0, profit = 0, listings = 0, link = link }
    groups[itemID] = group
  end
  group.qty = group.qty + qty
  group.cost = group.cost + cost
  group.profit = group.profit + unitValue * qty - cost
  group.listings = group.listings + 1
  group.value = unitValue
end

local function FinishGroups(groups, approx)
  local rows = {}
  for itemID, group in pairs(groups) do
    local item = Data.Item(itemID)
    if item then
      group.name = item.name
      group.icon = item.icon
      group.quality = item.quality
      group.link = group.link or item.link
      group.unit = group.cost / group.qty
      group.approx = approx
      table.insert(rows, group)
    end
  end
  return rows
end

-- Walks the newest scan, calling evaluate(itemID, count, buyout, bid, link)
-- for every listing. Summary scans only give the lowest buyout per item.
local function ForEachListing(view, kind, scan, evaluate)
  local exhausted = AT.Buy.exhausted[view] or {}
  if kind == "full" then
    for i, row in ipairs(scan.rows) do
      AT.MaybeYield(i)
      local info = row.replicateInfo
      local itemID = info and info[17]
      if itemID and not exhausted[itemID] then
        local bid
        if not info[12] then
          local current = info[11] or 0
          bid = current > 0 and (current + (info[9] or 0)) or info[8]
          if bid and bid <= 0 then
            bid = nil
          end
        end
        local buyout = info[10]
        evaluate(itemID, info[3] or 1, buyout and buyout > 0 and buyout or nil, bid, row.itemLink)
      end
    end
  else
    for i, row in ipairs(scan.rows) do
      AT.MaybeYield(i)
      local itemID = row.itemKey and row.itemKey.itemID
      if itemID and not exhausted[itemID] and row.minPrice and row.minPrice > 0 then
        evaluate(itemID, 1, row.minPrice, nil, nil)
      end
    end
  end
end

local function ScanMeta(kind, scan)
  return { source = kind, time = scan.time }
end

function Builders.vendor(settings)
  local bidMode = settings.mode == "bid"
  local kind, scan = Data.GetScan(bidMode)
  if not scan then
    return {}, { noData = true, needFull = bidMode and Data.summary ~= nil }
  end
  local minProfit = settings.minProfit
  local groups = {}
  ForEachListing("vendor", kind, scan, function(itemID, count, buyout, bid, link)
    local price = bidMode and bid or buyout
    if price and not (bidMode and Data.IsCommodity(itemID)) then
      local item = Data.Item(itemID)
      if item and item.sell > 0 and item.sell * count - price >= minProfit then
        AddListing(groups, itemID, count, price, item.sell, link)
      end
    end
  end)
  local rows = FinishGroups(groups, kind == "summary")
  for _, row in ipairs(rows) do
    row.buy = { mode = bidMode and "bid" or "buyout", unitValue = row.value }
  end
  return rows, ScanMeta(kind, scan)
end

function Builders.deals(settings)
  local kind, scan = Data.GetScan(false)
  if not scan then
    return {}, { noData = true }
  end
  local cut = AT.AHCut()
  local factor = 1 - settings.discount / 100
  local minProfit = settings.minProfit
  local groups = {}
  ForEachListing("deals", kind, scan, function(itemID, count, buyout, _, link)
    if buyout then
      local market = Data.MarketPrice(itemID)
      if market and buyout / count <= market * factor then
        local resale = market * cut
        if resale * count - buyout >= minProfit then
          AddListing(groups, itemID, count, buyout, resale, link)
          groups[itemID].market = market
        end
      end
    end
  end)
  local rows = FinishGroups(groups, kind == "summary")
  for _, row in ipairs(rows) do
    row.discount = 1 - row.unit / row.market
    row.buy = { mode = "buyout", unitValue = row.value }
  end
  return rows, ScanMeta(kind, scan)
end

local ARMOR = (Enum.ItemClass and Enum.ItemClass.Armor) or 4
local WEAPON = (Enum.ItemClass and Enum.ItemClass.Weapon) or 2

function Builders.disenchant(settings)
  local kind, scan = Data.GetScan(false)
  if not scan then
    return {}, { noData = true }
  end
  local cut = AT.AHCut()
  local minProfit = settings.minProfit
  local values = {}
  local groups = {}
  ForEachListing("disenchant", kind, scan, function(itemID, count, buyout, _, link)
    if buyout then
      local value = values[itemID]
      if value == nil then
        value = false
        local item = Data.Item(itemID)
        if item and (item.classID == ARMOR or item.classID == WEAPON) and item.quality >= 2 and item.quality <= 4 then
          local disenchant = Data.DisenchantValue(itemID)
          if disenchant and disenchant > 0 then
            value = disenchant * cut
          end
        end
        values[itemID] = value
      end
      if value and value * count - buyout >= minProfit then
        AddListing(groups, itemID, count, buyout, value, link)
      end
    end
  end)
  local rows = FinishGroups(groups, kind == "summary")
  for _, row in ipairs(rows) do
    row.buy = { mode = "buyout", unitValue = row.value }
  end
  return rows, ScanMeta(kind, scan)
end

-- Cheapest way to get a material: the auction house or a known vendor
local function MaterialPrice(itemID)
  local ah = Data.CurrentPrice(itemID)
  local vendor = AT.VendorBuyPrice(itemID)
  if ah and vendor then
    if vendor <= ah then
      return vendor, "vendor"
    end
    return ah, "ah"
  end
  if vendor then
    return vendor, "vendor"
  end
  return ah, ah and "ah" or nil
end

function Builders.crafting(settings)
  local professions = AT.char.professions
  if next(professions) == nil then
    return {}, { noProfessions = true }
  end
  local cut = AT.AHCut()
  local minProfit = settings.minProfit
  local rows = {}
  local count = 0
  for professionName, profession in pairs(professions) do
    for recipeID, recipe in pairs(profession.recipes) do
      count = count + 1
      AT.MaybeYield(count)
      local output = Data.Item(recipe.out)
      if output then
        local cost, complete, reagents = 0, true, {}
        for _, reagent in ipairs(recipe.reagents) do
          local price, source = MaterialPrice(reagent.id)
          if not price then
            complete = false
            break
          end
          cost = cost + price * reagent.n
          table.insert(reagents, { id = reagent.id, n = reagent.n, price = price, source = source })
        end
        if complete then
          local ah = Data.CurrentPrice(recipe.out)
          local saleUnit = math.max((ah or 0) * cut, output.sell)
          local value = saleUnit * recipe.yield
          local profit = value - cost
          if saleUnit > 0 and profit >= minProfit then
            table.insert(rows, {
              id = "r" .. recipeID,
              itemID = recipe.out,
              name = output.name,
              icon = output.icon,
              quality = output.quality,
              link = output.link,
              profession = professionName,
              yield = recipe.yield,
              cost = cost,
              value = value,
              profit = profit,
              margin = cost > 0 and profit / cost or nil,
              soldTo = (ah and ah * cut >= output.sell) and "ah" or "vendor",
              reagents = reagents,
            })
          end
        end
      end
    end
  end
  return rows, {}
end

function Builders.resale(settings)
  local prices = AT.db.vendorPrices
  if next(prices) == nil then
    return {}, { noVendors = true }
  end
  local cut = AT.AHCut()
  local minProfit = settings.minProfit
  local rows = {}
  local count = 0
  for itemID, entry in pairs(prices) do
    count = count + 1
    AT.MaybeYield(count)
    local ah = Data.CurrentPrice(itemID)
    if ah then
      local profit = ah * cut - entry.u
      if profit >= minProfit then
        local item = Data.Item(itemID)
        if item then
          table.insert(rows, {
            id = itemID,
            itemID = itemID,
            name = item.name,
            icon = item.icon,
            quality = item.quality,
            link = item.link,
            vendor = (entry.v or "Unknown") .. (entry.l and " (limited)" or ""),
            cost = entry.u,
            value = ah,
            profit = profit,
            margin = entry.u > 0 and profit / entry.u or nil,
            age = Data.PriceAge(itemID),
          })
        end
      end
    end
  end
  return rows, {}
end

Analysis.scanViews = { vendor = true, deals = true, disenchant = true }

-- Builds a view in the background and passes (rows, meta) to onDone
function Analysis.Run(view, onDone)
  AT.RunJob("analysis", function()
    Data.missingItems = 0
    local rows, meta = Builders[view](AT.db.views[view])
    meta.missingItems = Data.missingItems
    return { rows = rows, meta = meta }
  end, function(result)
    onDone(result.rows, result.meta)
  end)
end
