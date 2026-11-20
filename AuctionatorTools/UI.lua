local _, AT = ...

local Data, Analysis, Buy = AT.Data, AT.Analysis, AT.Buy
local UI = {}
AT.UI = UI

local WIDTH, HEIGHT = 900, 540
local ROW_HEIGHT = 20
local MARGIN = 12
local MAX_COLUMNS = 7

local VIEWS = {
  { key = "vendor", title = "Below Vendor", hint = "Listings you can buy and sell to a vendor for more." },
  { key = "deals", title = "Deals", hint = "Listings well below their typical price that you can relist." },
  { key = "disenchant", title = "Disenchant", hint = "Gear worth more as disenchanting materials than its price." },
  { key = "crafting", title = "Crafting", hint = "Your recipes whose product sells for more than its materials." },
  { key = "resale", title = "Vendor Resale", hint = "Items from vendors you've visited that sell for more on the AH." },
}

local COLUMNS = {
  vendor = {
    { key = "name", title = "Item" },
    { key = "qty", title = "Qty", width = 55, format = "qty" },
    { key = "unit", title = "Price Each", width = 115, format = "money" },
    { key = "value", title = "Vendor Each", width = 115, format = "money" },
    { key = "cost", title = "Total Cost", width = 115, format = "money" },
    { key = "profit", title = "Profit", width = 115, format = "money" },
  },
  deals = {
    { key = "name", title = "Item" },
    { key = "qty", title = "Qty", width = 55, format = "qty" },
    { key = "unit", title = "Price Each", width = 115, format = "money" },
    { key = "market", title = "Typical", width = 115, format = "money" },
    { key = "discount", title = "Below", width = 60, format = "percent" },
    { key = "cost", title = "Total Cost", width = 115, format = "money" },
    { key = "profit", title = "Profit", width = 115, format = "money" },
  },
  disenchant = {
    { key = "name", title = "Item" },
    { key = "qty", title = "Qty", width = 55, format = "qty" },
    { key = "unit", title = "Price Each", width = 115, format = "money" },
    { key = "value", title = "DE Value", width = 115, format = "money" },
    { key = "cost", title = "Total Cost", width = 115, format = "money" },
    { key = "profit", title = "Profit", width = 115, format = "money" },
  },
  crafting = {
    { key = "name", title = "Crafts" },
    { key = "profession", title = "Profession", width = 110 },
    { key = "cost", title = "Materials", width = 115, format = "money" },
    { key = "value", title = "Sells For", width = 115, format = "money" },
    { key = "profit", title = "Profit", width = 115, format = "money" },
    { key = "margin", title = "Margin", width = 65, format = "percent" },
  },
  resale = {
    { key = "name", title = "Item" },
    { key = "vendor", title = "Vendor", width = 130 },
    { key = "cost", title = "Vendor Price", width = 115, format = "money" },
    { key = "value", title = "AH Price", width = 115, format = "money" },
    { key = "profit", title = "Profit Each", width = 115, format = "money" },
    { key = "age", title = "Seen", width = 55, format = "age" },
  },
}

local frame
local widgets = {}
local results = {}
local dirty = { vendor = true, deals = true, disenchant = true, crafting = true, resale = true }
local computing
local computeToken = 0
local display = {}
local offset = 0
local selectedID
local searchText = ""

local function ActiveView()
  return AT.db.activeView
end

local function Settings()
  return AT.db.views[ActiveView()]
end

local function FormatCell(row, column)
  local value = row[column.key]
  local format = column.format
  if format == "money" then
    return AT.FormatMoney(value)
  elseif format == "qty" then
    return row.approx and (value .. "+") or tostring(value)
  elseif format == "percent" then
    return value and string.format("%d%%", math.floor(value * 100 + 0.5)) or "-"
  elseif format == "age" then
    if value == nil then
      return "-"
    end
    return value == 0 and "today" or (value .. "d ago")
  end
  return value and tostring(value) or ""
end

local function CompareRows(a, b)
  local settings = Settings()
  local key = settings.sortKey
  local va, vb = a[key], b[key]
  if va == vb then
    return (a.name or "") < (b.name or "")
  end
  if va == nil then
    return false
  end
  if vb == nil then
    return true
  end
  if settings.sortAsc then
    return va < vb
  end
  return va > vb
end

-- Scrolling list --------------------------------------------------------------

local function RowAt(index)
  return display[offset + index]
end

local function UpdateRows()
  local list = widgets.list
  local columns = COLUMNS[ActiveView()]
  for index, rowFrame in ipairs(list.rows) do
    local row = RowAt(index)
    if row then
      rowFrame.data = row
      rowFrame.icon:SetTexture(row.icon)
      for c = 1, MAX_COLUMNS do
        local cell = rowFrame.cells[c]
        local column = columns[c]
        if column then
          cell:SetText(FormatCell(row, column))
          if c == 1 then
            local color = ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[row.quality or 1]
            if color then
              cell:SetTextColor(color.r, color.g, color.b)
            end
          end
        end
      end
      rowFrame.selected:SetShown(row.id == selectedID)
      rowFrame:Show()
    else
      rowFrame.data = nil
      rowFrame:Hide()
    end
  end
  local maxOffset = math.max(0, #display - #list.rows)
  list.scrollBar:SetShown(maxOffset > 0)
  list.scrollBar:SetMinMaxValues(0, maxOffset)
  list.scrollBar:SetValue(offset)
end

local function SetOffset(value)
  local maxOffset = math.max(0, #display - #widgets.list.rows)
  value = math.max(0, math.min(maxOffset, math.floor(value + 0.5)))
  if value ~= offset then
    offset = value
    UpdateRows()
  end
end

local function LayoutColumns()
  local list = widgets.list
  local columns = COLUMNS[ActiveView()]
  local available = WIDTH - 2 * MARGIN - 16 - 26
  local fixed = 0
  for c = 2, #columns do
    fixed = fixed + columns[c].width
  end
  local nameWidth = available - fixed
  local function Place(region, c, x, width, isHeader)
    region:ClearAllPoints()
    region:SetPoint("LEFT", region:GetParent(), "LEFT", x, 0)
    region:SetWidth(width - 6)
    if not isHeader then
      region:SetJustifyH(c == 1 and "LEFT" or "RIGHT")
    end
  end
  local x = 26
  for c = 1, MAX_COLUMNS do
    local column = columns[c]
    local header = widgets.headers[c]
    if column then
      local width = c == 1 and nameWidth or column.width
      header:ClearAllPoints()
      header:SetPoint("TOPLEFT", widgets.headerBar, "TOPLEFT", x - 4, 0)
      header:SetSize(width, 20)
      header.label:SetText(column.title)
      header.label:ClearAllPoints()
      if c == 1 then
        header.label:SetPoint("LEFT", 4, 0)
      else
        header.label:SetPoint("RIGHT", -8, 0)
      end
      header.column = column
      header:Show()
      for _, rowFrame in ipairs(list.rows) do
        Place(rowFrame.cells[c], c, x, width)
        rowFrame.cells[c]:Show()
      end
      x = x + width
    else
      header:Hide()
      for _, rowFrame in ipairs(list.rows) do
        rowFrame.cells[c]:Hide()
      end
    end
  end
end

local function UpdateHeaders()
  local settings = Settings()
  for _, header in ipairs(widgets.headers) do
    if header.column then
      local arrow = ""
      if header.column.key == settings.sortKey then
        arrow = settings.sortAsc and " ^" or " v"
      end
      header.label:SetText(header.column.title .. arrow)
    end
  end
end

-- Data flow ------------------------------------------------------------------

local UpdateStatus, UpdateButtons

local function EmptyMessage(meta)
  if computing then
    return "Calculating..."
  end
  if not meta then
    return ""
  end
  if meta.needFull then
    return "Bid mode needs a full scan. Open the auction house and click Scan.\nAuctionator allows one full scan every 15 minutes."
  elseif meta.noData then
    return "No auction data yet.\nOpen the auction house and click Scan, or scan with Auctionator."
  elseif meta.noProfessions then
    return "No recipes recorded yet.\nOpen each of your profession windows once so your recipes can be read."
  elseif meta.noVendors then
    return "No vendor prices recorded yet.\nVisit vendors and anything they sell that is worth more on the auction house will show here."
  elseif searchText ~= "" then
    return "Nothing matches your search."
  end
  return "No opportunities found right now.\nTry a lower minimum profit or scan again later."
end

local function RefreshDisplay()
  local view = ActiveView()
  local result = results[view]
  wipe(display)
  if result then
    local search = searchText:lower()
    for _, row in ipairs(result.rows) do
      if search == "" or (row.name and row.name:lower():find(search, 1, true)) then
        table.insert(display, row)
      end
    end
    table.sort(display, CompareRows)
  end
  local found = false
  for _, row in ipairs(display) do
    if row.id == selectedID then
      found = true
      break
    end
  end
  if not found then
    selectedID = nil
  end
  offset = math.min(offset, math.max(0, #display - #widgets.list.rows))
  widgets.empty:SetText(#display == 0 and EmptyMessage(result and result.meta) or "")
  UpdateHeaders()
  UpdateRows()
  UpdateStatus()
  UpdateButtons()
end

local function Recompute()
  if not frame or not frame:IsShown() then
    return
  end
  local view = ActiveView()
  if computing and computing ~= view then
    dirty[computing] = true
  end
  dirty[view] = false
  computeToken = computeToken + 1
  local token = computeToken
  computing = view
  if not results[view] then
    RefreshDisplay()
  else
    UpdateStatus()
  end
  Analysis.Run(view, function(rows, meta)
    if token ~= computeToken then
      return
    end
    computing = nil
    results[view] = { rows = rows, meta = meta }
    if view == ActiveView() then
      RefreshDisplay()
    end
  end)
end

local function MarkDirty(views)
  for view in pairs(views) do
    dirty[view] = true
  end
  if frame and frame:IsShown() and dirty[ActiveView()] then
    AT.Debounce("recompute", 0.2, Recompute)
  end
end

local function MarkAllDirty()
  MarkDirty(dirty)
end

local function SelectedRow()
  for _, row in ipairs(display) do
    if row.id == selectedID then
      return row
    end
  end
end

-- Actions ----------------------------------------------------------------------

local function CleanSearchTerm(name)
  return (name or ""):gsub("[;^\"]", "")
end

local function SearchAuctionator(names)
  if not AT.ahOpen then
    AT.Print("Open the auction house to search.")
    return
  end
  local terms = {}
  for _, name in ipairs(names) do
    local term = CleanSearchTerm(name)
    if term ~= "" then
      table.insert(terms, term)
    end
  end
  if #terms > 0 then
    local ok, err = pcall(Auctionator.API.v1.MultiSearchExact, AT.CALLER_ID, terms)
    if not ok then
      AT.Print("Auctionator search failed: " .. tostring(err))
    end
  end
end

local function ShopMaterials(row)
  if not AT.ahOpen then
    AT.Print("Open the auction house to shop for materials.")
    return
  end
  local terms = {}
  for _, reagent in ipairs(row.reagents) do
    local item = Data.Item(reagent.id)
    if item and reagent.source == "ah" then
      table.insert(terms, { searchString = CleanSearchTerm(item.name), isExact = true, quantity = reagent.n })
    end
  end
  if #terms == 0 then
    AT.Print("All materials for " .. row.name .. " are cheapest from a vendor.")
    return
  end
  local ok, err = pcall(Auctionator.API.v1.MultiSearchAdvanced, AT.CALLER_ID, terms)
  if not ok then
    AT.Print("Auctionator search failed: " .. tostring(err))
  end
end

local function StartBuy(row)
  if not row then
    return
  end
  local view = ActiveView()
  if view == "crafting" then
    ShopMaterials(row)
  elseif view == "resale" then
    SearchAuctionator({ row.name })
  elseif row.buy then
    Buy.Start({
      view = view,
      itemID = row.itemID,
      name = row.name,
      link = row.link,
      mode = row.buy.mode,
      unitValue = row.buy.unitValue,
      minProfit = Settings().minProfit,
    })
  end
end

local function OnBuyClicked()
  if Buy.state == "offer" or Buy.state == "commodityConfirm" then
    Buy.Confirm()
  else
    StartBuy(SelectedRow())
  end
end

-- Status bar ---------------------------------------------------------------------

UpdateStatus = function()
  if not frame then
    return
  end
  local parts = {}
  if Data.scanning then
    table.insert(parts, string.format("Scanning... %d%%", math.floor(Data.scanning * 100)))
  end
  local view = ActiveView()
  if Analysis.scanViews[view] then
    local kind, scan = Data.GetScan(view == "vendor" and Settings().mode == "bid")
    if scan then
      table.insert(parts, (kind == "full" and "Full scan " or "Summary scan ") .. Data.FormatAge(scan.time))
    end
  end
  if computing then
    table.insert(parts, "Calculating...")
  elseif results[view] then
    table.insert(parts, #display .. " results")
    if results[view].meta.loadingItems then
      table.insert(parts, "loading item info...")
    elseif results[view].meta.unavailableItems then
      table.insert(parts, "some item info unavailable")
    end
  end
  widgets.status:SetText(table.concat(parts, "  |cff808080|||r  "))
  widgets.message:SetText(Buy.text or VIEWS[widgets.viewIndex[view]].hint)
end

UpdateButtons = function()
  if not frame then
    return
  end
  local view = ActiveView()
  local state = Buy.state
  local row = SelectedRow()
  local buyButton, skipButton = widgets.buy, widgets.skip
  buyButton:Show()
  if state == "offer" then
    buyButton:SetText(Buy.mode == "bid" and "Confirm Bid" or "Confirm Buy")
    buyButton:Enable()
  elseif state == "commodityConfirm" then
    buyButton:SetText("Confirm Buy")
    buyButton:Enable()
  elseif state ~= "idle" then
    buyButton:SetText("Working...")
    buyButton:Disable()
  else
    if view == "crafting" then
      buyButton:SetText("Shop Mats")
    elseif view == "resale" then
      buyButton:Hide()
    elseif view == "vendor" and Settings().mode == "bid" then
      buyButton:SetText("Bid")
    else
      buyButton:SetText("Buy")
    end
    buyButton:SetEnabled(row ~= nil and AT.ahOpen)
  end
  skipButton:SetShown(state ~= "idle")
  skipButton:SetText(state == "offer" and "Skip" or "Cancel")
  widgets.search:SetEnabled(row ~= nil and AT.ahOpen)
  widgets.scan:SetEnabled(AT.ahOpen and not Data.scanning)
end

-- Construction ---------------------------------------------------------------------

local function CreateInput(parent, width, label)
  local text = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  text:SetText(label)
  local box = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
  box:SetSize(width, 20)
  box:SetAutoFocus(false)
  box:SetPoint("LEFT", text, "RIGHT", 8, 0)
  box:SetScript("OnEscapePressed", box.ClearFocus)
  box:SetScript("OnEnterPressed", box.ClearFocus)
  box.label = text
  return box
end

local function ShowRowTooltip(rowFrame)
  local row = rowFrame.data
  if not row then
    return
  end
  GameTooltip:SetOwner(rowFrame, "ANCHOR_RIGHT")
  if row.link then
    GameTooltip:SetHyperlink(row.link)
  else
    GameTooltip:SetText(row.name or "")
  end
  if row.reagents then
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine(string.format("Makes %s per craft, sold to the %s", row.yield, row.soldTo == "ah" and "AH" or "vendor"), 1, 0.82, 0)
    for _, reagent in ipairs(row.reagents) do
      local item = Data.Item(reagent.id)
      GameTooltip:AddDoubleLine(
        string.format("%dx %s (%s)", reagent.n, item and item.name or ("item " .. reagent.id), reagent.source == "vendor" and "vendor" or "AH"),
        AT.FormatMoney(reagent.price * reagent.n), 1, 1, 1, 1, 1, 1)
    end
  end
  if row.approx then
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("From a summary scan: only the cheapest listing is known.\nRun a full scan for exact quantities.", 0.6, 0.6, 0.6, true)
  end
  GameTooltip:AddLine(" ")
  local view = ActiveView()
  if view == "crafting" then
    GameTooltip:AddLine("Double-click to shop for materials in Auctionator.", 0.5, 0.8, 1)
  elseif view == "resale" then
    GameTooltip:AddLine("Buy this from the vendor, then sell it on the auction house.", 0.5, 0.8, 1)
  else
    GameTooltip:AddLine("Double-click to buy. Right-click to search in Auctionator.", 0.5, 0.8, 1)
  end
  GameTooltip:Show()
end

local function CreateRow(list, index)
  local rowFrame = CreateFrame("Button", nil, list)
  rowFrame:SetHeight(ROW_HEIGHT)
  rowFrame:SetPoint("TOPLEFT", 0, -(index - 1) * ROW_HEIGHT)
  rowFrame:SetPoint("RIGHT", list, "RIGHT", -16, 0)
  rowFrame:RegisterForClicks("LeftButtonUp", "RightButtonUp")

  if index % 2 == 0 then
    local stripe = rowFrame:CreateTexture(nil, "BACKGROUND")
    stripe:SetAllPoints()
    stripe:SetColorTexture(1, 1, 1, 0.03)
  end
  rowFrame.selected = rowFrame:CreateTexture(nil, "BACKGROUND", nil, 1)
  rowFrame.selected:SetAllPoints()
  rowFrame.selected:SetColorTexture(0.2, 0.5, 1, 0.25)
  rowFrame.selected:Hide()
  local highlight = rowFrame:CreateTexture(nil, "HIGHLIGHT")
  highlight:SetAllPoints()
  highlight:SetColorTexture(1, 1, 1, 0.08)

  rowFrame.icon = rowFrame:CreateTexture(nil, "ARTWORK")
  rowFrame.icon:SetSize(ROW_HEIGHT - 4, ROW_HEIGHT - 4)
  rowFrame.icon:SetPoint("LEFT", 4, 0)

  rowFrame.cells = {}
  for c = 1, MAX_COLUMNS do
    local cell = rowFrame:CreateFontString(nil, "OVERLAY", c == 1 and "GameFontHighlight" or "GameFontHighlightSmall")
    cell:SetWordWrap(false)
    rowFrame.cells[c] = cell
  end

  rowFrame:SetScript("OnClick", function(self, button)
    local row = self.data
    if not row then
      return
    end
    if IsModifiedClick() and row.link and HandleModifiedItemClick(row.link) then
      return
    end
    if button == "RightButton" then
      SearchAuctionator({ row.name })
      return
    end
    selectedID = row.id
    UpdateRows()
    UpdateButtons()
  end)
  rowFrame:SetScript("OnDoubleClick", function(self, button)
    if button == "LeftButton" and self.data and Buy.state == "idle" then
      selectedID = self.data.id
      UpdateRows()
      StartBuy(self.data)
    end
  end)
  rowFrame:SetScript("OnEnter", ShowRowTooltip)
  rowFrame:SetScript("OnLeave", GameTooltip_Hide)
  return rowFrame
end

local function CreateList(parent)
  local list = CreateFrame("Frame", nil, parent)
  list:SetPoint("TOPLEFT", widgets.headerBar, "BOTTOMLEFT", 0, -2)
  list:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -MARGIN, 64)
  list:EnableMouseWheel(true)
  list:SetScript("OnMouseWheel", function(_, delta)
    SetOffset(offset - delta * 3)
  end)

  list.rows = {}
  local count = math.floor((HEIGHT - 64 - 120) / ROW_HEIGHT)
  for index = 1, count do
    list.rows[index] = CreateRow(list, index)
  end

  local scrollBar = CreateFrame("Slider", nil, list)
  scrollBar:SetPoint("TOPRIGHT", 0, 0)
  scrollBar:SetPoint("BOTTOMRIGHT", 0, 0)
  scrollBar:SetWidth(12)
  scrollBar:SetOrientation("VERTICAL")
  scrollBar:SetValueStep(1)
  scrollBar:SetObeyStepOnDrag(true)
  local track = scrollBar:CreateTexture(nil, "BACKGROUND")
  track:SetAllPoints()
  track:SetColorTexture(0, 0, 0, 0.3)
  scrollBar:SetThumbTexture("Interface\\Buttons\\WHITE8X8")
  local thumb = scrollBar:GetThumbTexture()
  thumb:SetVertexColor(0.6, 0.6, 0.6, 0.6)
  thumb:SetSize(12, 40)
  scrollBar:SetScript("OnValueChanged", function(_, value)
    SetOffset(value)
  end)
  list.scrollBar = scrollBar

  widgets.empty = list:CreateFontString(nil, "OVERLAY", "GameFontDisable")
  widgets.empty:SetPoint("CENTER", -8, 0)
  widgets.empty:SetWidth(500)
  return list
end

local function UpdateTabs()
  for _, tab in ipairs(widgets.tabs) do
    local active = tab.view == ActiveView()
    tab.background:SetColorTexture(active and 0.2 or 0.1, active and 0.45 or 0.1, active and 0.9 or 0.1, active and 0.6 or 0.6)
    tab.text:SetFontObject(active and "GameFontHighlight" or "GameFontNormal")
  end
end

local function UpdateFilters()
  local view = ActiveView()
  local settings = Settings()
  widgets.minProfit:SetText(AT.FormatMoneyPlain(settings.minProfit))
  widgets.mode:SetShown(view == "vendor")
  widgets.mode:SetText(settings.mode == "bid" and "Using: Bids" or "Using: Buyouts")
  widgets.discount:SetShown(view == "deals")
  widgets.discount.label:SetShown(view == "deals")
  if view == "deals" then
    widgets.discount:SetText(tostring(settings.discount))
  end
end

local function SelectView(view)
  if view == ActiveView() and results[view] then
    return
  end
  AT.db.activeView = view
  selectedID = nil
  offset = 0
  UpdateTabs()
  UpdateFilters()
  LayoutColumns()
  if dirty[view] or not results[view] then
    Recompute()
  end
  RefreshDisplay()
end

local function CreateTabs(parent)
  widgets.tabs = {}
  widgets.viewIndex = {}
  local x = MARGIN
  for index, info in ipairs(VIEWS) do
    widgets.viewIndex[info.key] = index
    local tab = CreateFrame("Button", nil, parent)
    tab.view = info.key
    tab.text = tab:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    tab.text:SetPoint("CENTER")
    tab.text:SetText(info.title)
    tab:SetSize(tab.text:GetStringWidth() + 28, 24)
    tab:SetPoint("TOPLEFT", parent, "TOPLEFT", x, -30)
    tab.background = tab:CreateTexture(nil, "BACKGROUND")
    tab.background:SetAllPoints()
    local highlight = tab:CreateTexture(nil, "HIGHLIGHT")
    highlight:SetAllPoints()
    highlight:SetColorTexture(1, 1, 1, 0.1)
    tab:SetScript("OnClick", function()
      SelectView(info.key)
    end)
    tab:SetScript("OnEnter", function(self)
      GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
      GameTooltip:SetText(info.title)
      GameTooltip:AddLine(info.hint, 1, 1, 1, true)
      GameTooltip:Show()
    end)
    tab:SetScript("OnLeave", GameTooltip_Hide)
    widgets.tabs[index] = tab
    x = x + tab:GetWidth() + 4
  end
end

local function CreateFilters(parent)
  local search = CreateFrame("EditBox", nil, parent, "SearchBoxTemplate")
  search:SetSize(200, 20)
  search:SetPoint("TOPLEFT", parent, "TOPLEFT", MARGIN + 6, -64)
  search:HookScript("OnTextChanged", function(self)
    local text = self:GetText() or ""
    if text ~= searchText then
      searchText = text
      offset = 0
      RefreshDisplay()
    end
  end)
  widgets.searchBox = search

  local minProfit = CreateInput(parent, 100, "Min profit")
  minProfit.label:SetPoint("LEFT", search, "RIGHT", 20, 0)
  local function ApplyMinProfit(self)
    local value = AT.ParseMoney(self:GetText())
    local settings = Settings()
    if value then
      value = math.max(1, value)
      if value ~= settings.minProfit then
        settings.minProfit = value
        MarkDirty({ [ActiveView()] = true })
      end
    end
    self:SetText(AT.FormatMoneyPlain(settings.minProfit))
  end
  minProfit:SetScript("OnEditFocusLost", ApplyMinProfit)
  minProfit:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
    GameTooltip:SetText("Minimum profit")
    GameTooltip:AddLine("Hide anything that makes less than this. Examples: 1c, 50s, 1g 25s. A plain number is copper.", 1, 1, 1, true)
    GameTooltip:Show()
  end)
  minProfit:SetScript("OnLeave", GameTooltip_Hide)
  widgets.minProfit = minProfit

  local mode = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
  mode:SetSize(120, 22)
  mode:SetPoint("LEFT", minProfit, "RIGHT", 16, 0)
  mode:SetScript("OnClick", function()
    local settings = Settings()
    settings.mode = settings.mode == "bid" and "buyout" or "bid"
    UpdateFilters()
    MarkDirty({ vendor = true })
    RefreshDisplay()
  end)
  mode:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
    GameTooltip:SetText("Buyouts or bids")
    GameTooltip:AddLine("Compare the vendor price with each listing's buyout, or with the next bid you would need to place. Bids need a full scan.", 1, 1, 1, true)
    GameTooltip:Show()
  end)
  mode:SetScript("OnLeave", GameTooltip_Hide)
  widgets.mode = mode

  local discount = CreateInput(parent, 40, "At least % below typical")
  discount.label:SetPoint("LEFT", minProfit, "RIGHT", 16, 0)
  discount:SetNumeric(true)
  discount:SetMaxLetters(2)
  discount:SetScript("OnEditFocusLost", function(self)
    local settings = AT.db.views.deals
    local value = tonumber(self:GetText())
    if value then
      value = math.max(1, math.min(95, value))
      if value ~= settings.discount then
        settings.discount = value
        MarkDirty({ deals = true })
      end
    end
    self:SetText(tostring(settings.discount))
  end)
  discount:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
    GameTooltip:SetText("Discount")
    GameTooltip:AddLine("Only show listings at least this far below the item's typical price (the median daily low over the last " .. AT.db.historyDays .. " days).", 1, 1, 1, true)
    GameTooltip:Show()
  end)
  discount:SetScript("OnLeave", GameTooltip_Hide)
  widgets.discount = discount
end

local function CreateHeaders(parent)
  local bar = CreateFrame("Frame", nil, parent)
  bar:SetPoint("TOPLEFT", parent, "TOPLEFT", MARGIN, -92)
  bar:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -MARGIN, -92)
  bar:SetHeight(20)
  local background = bar:CreateTexture(nil, "BACKGROUND")
  background:SetAllPoints()
  background:SetColorTexture(0, 0, 0, 0.4)
  widgets.headerBar = bar

  widgets.headers = {}
  for c = 1, MAX_COLUMNS do
    local header = CreateFrame("Button", nil, bar)
    header.label = header:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    local highlight = header:CreateTexture(nil, "HIGHLIGHT")
    highlight:SetAllPoints()
    highlight:SetColorTexture(1, 1, 1, 0.08)
    header:SetScript("OnClick", function(self)
      local settings = Settings()
      local key = self.column.key
      if settings.sortKey == key then
        settings.sortAsc = not settings.sortAsc
      else
        settings.sortKey = key
        settings.sortAsc = key == "name" or key == "profession" or key == "vendor" or key == "age"
      end
      RefreshDisplay()
    end)
    widgets.headers[c] = header
  end
end

local function CreateBottomBar(parent)
  local scan = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
  scan:SetSize(80, 22)
  scan:SetPoint("BOTTOMLEFT", parent, "BOTTOMLEFT", MARGIN, 10)
  scan:SetText("Scan")
  scan:SetScript("OnClick", function()
    local ok, message = Data.StartScan()
    if message then
      AT.Print(message)
    end
    if ok then
      Data.scanning = Data.scanning or 0
      UpdateStatus()
      UpdateButtons()
    end
  end)
  scan:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:SetText("Scan the auction house")
    GameTooltip:AddLine("Runs Auctionator's full scan, or its quicker summary scan while the full scan is on cooldown.", 1, 1, 1, true)
    GameTooltip:Show()
  end)
  scan:SetScript("OnLeave", GameTooltip_Hide)
  widgets.scan = scan

  local status = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  status:SetPoint("LEFT", scan, "RIGHT", 10, 0)
  status:SetJustifyH("LEFT")
  widgets.status = status

  local buy = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
  buy:SetSize(110, 22)
  buy:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -MARGIN, 10)
  buy:SetScript("OnClick", OnBuyClicked)
  widgets.buy = buy

  local skip = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
  skip:SetSize(80, 22)
  skip:SetPoint("RIGHT", buy, "LEFT", -4, 0)
  skip:SetScript("OnClick", function()
    Buy.Skip()
  end)
  widgets.skip = skip

  local search = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
  search:SetSize(140, 22)
  search:SetPoint("RIGHT", skip, "LEFT", -4, 0)
  search:SetText("Search in Auctionator")
  search:SetScript("OnClick", function()
    local row = SelectedRow()
    if row then
      SearchAuctionator({ row.name })
    end
  end)
  widgets.search = search

  local message = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  message:SetPoint("BOTTOMLEFT", parent, "BOTTOMLEFT", MARGIN + 4, 40)
  message:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -MARGIN - 4, 40)
  message:SetJustifyH("LEFT")
  message:SetWordWrap(false)
  widgets.message = message
end

local function SavePosition()
  local point, _, relativePoint, x, y = frame:GetPoint()
  AT.db.point = { point, relativePoint, x, y }
end

local function RestorePosition()
  frame:ClearAllPoints()
  local saved = AT.db.point
  if saved then
    frame:SetPoint(saved[1], UIParent, saved[2], saved[3], saved[4])
  else
    frame:SetPoint("CENTER")
  end
end

local ticker

local function Create()
  frame = CreateFrame("Frame", "AuctionatorToolsFrame", UIParent, "BasicFrameTemplateWithInset")
  frame:SetSize(WIDTH, HEIGHT)
  frame:SetFrameStrata("HIGH")
  frame:SetToplevel(true)
  frame:SetClampedToScreen(true)
  frame:SetMovable(true)
  frame:EnableMouse(true)
  frame:RegisterForDrag("LeftButton")
  frame:SetScript("OnDragStart", frame.StartMoving)
  frame:SetScript("OnDragStop", function()
    frame:StopMovingOrSizing()
    SavePosition()
  end)
  frame:Hide()
  table.insert(UISpecialFrames, frame:GetName())

  local title = frame.TitleText or (frame.TitleContainer and frame.TitleContainer.TitleText)
  if title then
    title:SetText("Auctionator Tools")
  end

  CreateTabs(frame)
  CreateFilters(frame)
  CreateHeaders(frame)
  widgets.list = CreateList(frame)
  CreateBottomBar(frame)

  frame:SetScript("OnShow", function()
    UpdateTabs()
    UpdateFilters()
    LayoutColumns()
    if dirty[ActiveView()] then
      Recompute()
    end
    RefreshDisplay()
    ticker = C_Timer.NewTicker(30, UpdateStatus)
  end)
  frame:SetScript("OnHide", function()
    if ticker then
      ticker:Cancel()
      ticker = nil
    end
    AT.CancelJob("analysis")
    if computing then
      computing = nil
      dirty[ActiveView()] = true
    end
  end)
  RestorePosition()
end

function UI.Show()
  if not frame then
    Create()
  end
  frame:Show()
end

function UI.Toggle()
  if frame and frame:IsShown() then
    frame:Hide()
  else
    UI.Show()
  end
end

function UI.ResetPosition()
  if frame then
    RestorePosition()
  end
end

-- Keep views up to date as data changes; only the visible view is rebuilt
AT.Listen("ScanUpdated", function()
  MarkDirty(Analysis.scanViews)
  if frame and frame:IsShown() then
    UpdateStatus()
    UpdateButtons()
  end
end)
AT.Listen("ScanProgress", function()
  if frame and frame:IsShown() then
    UpdateStatus()
    UpdateButtons()
  end
end)
AT.Listen("VendorPricesUpdated", function()
  MarkDirty({ resale = true, crafting = true })
end)
AT.Listen("ProfessionsUpdated", function()
  MarkDirty({ crafting = true })
end)
AT.Listen("ItemDataLoaded", MarkAllDirty)
AT.Listen("BuyStateChanged", function()
  if frame and frame:IsShown() then
    UpdateStatus()
    UpdateButtons()
  end
end)
AT.Listen("AHStateChanged", function()
  if AT.ahOpen then
    -- Auctionator's prices may have been refreshed since the last view build
    MarkDirty({ crafting = true, resale = true })
  end
  if frame and frame:IsShown() then
    UpdateButtons()
  end
end)
AT.Listen("ItemExhausted", function(view, itemID)
  local result = results[view]
  if not result then
    return
  end
  for index = #result.rows, 1, -1 do
    if result.rows[index].itemID == itemID then
      table.remove(result.rows, index)
    end
  end
  if frame and frame:IsShown() and view == ActiveView() then
    RefreshDisplay()
  end
end)
