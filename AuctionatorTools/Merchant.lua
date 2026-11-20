local _, AT = ...

-- Learns what vendors sell and for how much as the player visits them
local function GetMerchantEntry(index)
  if C_MerchantFrame and C_MerchantFrame.GetItemInfo then
    local info = C_MerchantFrame.GetItemInfo(index)
    if info then
      return info.price, info.stackCount, info.numAvailable, info.hasExtendedCost, info.isPurchasable ~= false
    end
  elseif GetMerchantItemInfo then
    local _, _, price, stackCount, numAvailable, isPurchasable, _, hasExtendedCost = GetMerchantItemInfo(index)
    return price, stackCount, numAvailable, hasExtendedCost, isPurchasable ~= false
  end
end

local function VendorName()
  local name = UnitName("npc")
  if issecretvalue and issecretvalue(name) then
    return nil
  end
  return name
end

local function RecordMerchant()
  if not AT.db then
    return
  end
  local prices = AT.db.vendorPrices
  local vendor = VendorName()
  local changed = false
  for index = 1, GetMerchantNumItems() do
    local itemID = GetMerchantItemID(index)
    local price, stackCount, numAvailable, hasExtendedCost, purchasable = GetMerchantEntry(index)
    if itemID and price and price > 0 and not hasExtendedCost and purchasable then
      local unit = price / math.max(stackCount or 1, 1)
      local limited = numAvailable ~= nil and numAvailable >= 0
      local existing = prices[itemID]
      if not existing or unit < existing.u or existing.v == vendor then
        if not existing or existing.u ~= unit or existing.l ~= (limited or nil) or existing.v ~= vendor then
          prices[itemID] = { u = unit, l = limited or nil, v = vendor }
          changed = true
        end
      end
    end
  end
  if changed then
    AT.Send("VendorPricesUpdated")
  end
end

AT.OnEvent("MERCHANT_SHOW", function()
  AT.Debounce("merchant", 0.3, RecordMerchant)
end)
AT.OnEvent("MERCHANT_UPDATE", function()
  AT.Debounce("merchant", 0.3, RecordMerchant)
end)

function AT.VendorBuyPrice(itemID)
  local entry = AT.db.vendorPrices[itemID]
  return entry and entry.u
end
