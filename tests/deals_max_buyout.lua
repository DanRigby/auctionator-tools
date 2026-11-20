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
  GetScan = function() return scan.kind, scan end,
  MarketPrice = function() return 1000 end,
  Item = function(id) return { name = tostring(id), sell = 1000 } end,
}
AT.AHCut = function() return 0.95 end
AT.MaybeYield = function() end
AT.RunJob = function(_, job, onDone) onDone(job()) end

assert(loadfile("AuctionatorTools/Analysis.lua"))("AuctionatorTools", AT)
assert(loadfile("AuctionatorTools/UI.lua"))("AuctionatorTools", AT)

local function fullListing(id, quantity, buyout)
  return { replicateInfo = { [3] = quantity, [10] = buyout, [17] = id } }
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
assert(run("vendor")[2], "other views must not be filtered")

scan = { kind = "summary", rows = {
  { itemKey = { itemID = 5 }, minPrice = 100 },
  { itemKey = { itemID = 6 }, minPrice = 101 },
} }
rows = run("deals")
assert(rows[5] and not rows[6], "summary prices must respect the limit")
AT.db.views.deals.maxBuyout = 101
assert(run("deals")[6], "changing the maximum must update results")

local function upvalue(fn, wanted)
  for i = 1, math.huge do
    local name, value = debug.getupvalue(fn, i)
    if not name then break end
    if name == wanted then return value end
  end
  error("missing upvalue: " .. wanted)
end
local create = upvalue(AT.UI.Show, "Create")
local createFilters = upvalue(create, "CreateFilters")
local widgets = upvalue(createFilters, "widgets")
createFilters(CreateFrame())
local input = widgets.maxBuyout
local updateFilters = upvalue(widgets.mode.scripts.OnClick, "UpdateFilters")
AT.db.activeView = "deals"
updateFilters()
assert(input.shown and input.label.shown and input:GetText() == "1s 1c",
  "Deals must display the saved maximum")
AT.db.activeView = "vendor"
updateFilters()
assert(not input.shown and not input.label.shown, "the maximum must be hidden in other views")
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
