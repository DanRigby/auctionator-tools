-- Run from the repository root with Lua 5.1 or later.
local function upvalue(fn, wanted, replacement)
  for i = 1, math.huge do
    local name, value = debug.getupvalue(fn, i)
    if not name then break end
    if name == wanted then
      if replacement ~= nil then debug.setupvalue(fn, i, replacement) end
      return value
    end
  end
  error("missing upvalue: " .. wanted)
end

local function widget()
  local w = {}
  function w:SetText(text) self.text = text end
  function w:GetText() return self.text end
  function w:SetScript(event, callback) self[event] = callback end
  function w:HookScript(event, callback) self[event] = callback end
  function w:CreateFontString() return widget() end
  function w:SetAutoFocus() end
  function w:SetNumeric() end
  function w:SetMaxLetters() end
  function w:IsShown() return self.shown end
  function w:Show() self.shown = true end
  function w:Hide() self.shown = false end
  function w:SetShown(shown) self.shown = shown end
  function w:SetEnabled(enabled) self.enabled = enabled end
  function w:Enable() end
  function w:Disable() end
  function w:SetMinMaxValues() end
  function w:SetValue() end
  function w:ClearAllPoints() end
  function w:SetPoint() end
  function w:SetSize() end
  return w
end
function wipe(t) for key in pairs(t) do t[key] = nil end end
function CreateFrame() return widget() end

local function harness()
  local h = { runs = {}, pending = {}, loaded = {}, listeners = {}, timers = {}, now = 0 }
  local currentJob
  local AT = {
    ahOpen = true,
    db = { activeView = "vendor", views = {} },
    Data = {},
    Buy = { state = "idle", exhausted = {} },
    Analysis = { scanViews = { vendor = true, deals = true, disenchant = true } },
  }
  for _, view in ipairs({ "vendor", "deals", "disenchant", "crafting", "resale" }) do
    AT.db.views[view] = { minProfit = 1, mode = "buyout", sortKey = "profit", discount = 30, maxBuyout = 50000 }
  end
  function AT.Listen(event, callback) h.listeners[event] = callback end
  function AT.Debounce(key, delay, callback) h.timers[key] = { at = h.now + delay, callback = callback } end
  function AT.CancelJob() if currentJob then currentJob.cancelled = true end end
  function AT.FormatMoneyPlain(value) return tostring(value) end
  function AT.Data.GetScan() end
  function AT.Data.ItemLoadCounts(missing)
    local loading, unavailable = 0, 0
    for id in pairs(missing or {}) do
      if not h.loaded[id] then
        if h.pending[id] then loading = loading + 1 else unavailable = unavailable + 1 end
      end
    end
    return loading, unavailable
  end
  function AT.Analysis.Run(view, onDone)
    local job = { view = view, done = onDone, missing = {} }
    currentJob = job
    table.insert(h.runs, job)
    return job.missing
  end
  function h.advance(seconds)
    local target = h.now + seconds
    while true do
      local key, nextTimer
      for name, timer in pairs(h.timers) do
        if timer.at <= target and (not nextTimer or timer.at < nextTimer.at) then
          key, nextTimer = name, timer
        end
      end
      if not key then break end
      h.timers[key] = nil
      h.now = nextTimer.at
      nextTimer.callback()
    end
    h.now = target
  end
  function h.finish(index, rows, meta)
    local job = h.runs[index]
    job.done(rows or {}, meta or { missingItems = job.missing })
  end
  assert(loadfile("AuctionatorTools/UI.lua"))("AuctionatorTools", AT)
  local create = upvalue(AT.UI.Show, "Create")
  local frame = widget()
  frame.shown = true
  upvalue(create, "frame", frame)
  h.widgets = upvalue(create, "widgets")
  for _, name in ipairs({ "empty", "status", "message", "buy", "skip", "search", "scan",
    "minProfit", "mode", "discount", "maxBuyout" }) do
    h.widgets[name] = widget()
    h.widgets[name].label = widget()
  end
  h.widgets.list = { rows = {}, scrollBar = widget() }
  h.widgets.tabs, h.widgets.headers = {}, {}
  for i = 1, 7 do
    h.widgets.headers[i] = widget()
    h.widgets.headers[i].label = widget()
  end
  h.widgets.viewIndex = { vendor = 1, deals = 2, disenchant = 3, crafting = 4, resale = 5 }
  h.recompute = upvalue(create, "Recompute")
  h.cancel = upvalue(create, "CancelComputation")
  h.dirty = upvalue(h.recompute, "dirty")
  h.results = upvalue(h.recompute, "results")
  h.select = upvalue(upvalue(create, "CreateTabs"), "SelectView")
  h.markDirty = upvalue(h.listeners.ScanUpdated, "MarkDirty")
  h.createFilters = upvalue(create, "CreateFilters")
  h.display = upvalue(upvalue(create, "RefreshDisplay"), "display")
  local columns = upvalue(upvalue(create, "LayoutColumns"), "COLUMNS")
  function h.toggle()
    h.createFilters(frame)
    for i, column in ipairs(columns[AT.db.activeView]) do
      h.widgets.headers[i].column = column
    end
    h.widgets.mode.OnClick()
  end
  h.frame, h.AT = frame, AT
  return h
end

local h = harness()
h.recompute()
h.runs[1].missing[1] = true
h.listeners.ItemDataLoaded({ [1] = true })
h.listeners.ItemDataLoaded({ [1] = true })
h.advance(1)
assert(#h.runs == 1, "item arrivals must not restart an unfinished analysis")
h.finish(1)
h.advance(2)
assert(#h.runs == 2, "arrivals for missed items must schedule one follow-up analysis")
h.finish(2)
h.advance(1)
assert(#h.runs == 2, "a completed follow-up must not repeatedly rebuild")
h.listeners.ItemDataLoaded({ [999] = true })
h.advance(1)
assert(#h.runs == 2, "unrelated item loads must not rebuild the active view")
h.results.deals = { rows = {}, meta = { missingItems = { [3] = true } } }
h.dirty.deals = false
h.listeners.ItemDataLoaded({ [3] = true })
h.advance(1)
assert(h.dirty.deals and #h.runs == 2, "an inactive dependent view must be invalidated without rebuilding the active view")

h = harness()
h.recompute()
h.runs[1].missing[1] = true
h.pending[1] = true
h.finish(1)
assert(h.widgets.status.text:find("loading item info", 1, true))
h.pending[1] = nil
h.listeners.ItemLoadStateChanged()
assert(h.widgets.status.text:find("item info unavailable", 1, true)
  and not h.widgets.status.text:find("loading item info", 1, true),
  "exhaustion must replace the loading status immediately")
h.advance(1)
assert(#h.runs == 1, "a loading-state change must not rebuild unchanged results")
h.loaded[1] = true
h.listeners.ItemDataLoaded({ [1] = true })
h.advance(2)
assert(#h.runs == 2, "a late success must rebuild dependent results")

h = harness()
h.markDirty({ vendor = true })
h.recompute()
h.runs[1].missing[1] = true
h.listeners.ItemDataLoaded({ [1] = true })
h.advance(0.2)
assert(#h.runs == 1, "a stale debounce must not restart a newer analysis")
h.finish(1)
h.advance(2)
assert(#h.runs == 2)
h.markDirty({ vendor = true })
h.advance(0.2)
assert(#h.runs == 3, "settings changes must still restart a stale analysis promptly")
local previous = h.results.vendor
h.finish(2)
assert(h.results.vendor == previous, "obsolete callbacks must not publish replaced results")

h = harness()
h.recompute()
for id = 1, 10 do h.runs[1].missing[id] = true end
h.finish(1)
local finished = 1
for id = 1, 10 do
  h.loaded[id] = true
  h.listeners.ItemDataLoaded({ [id] = true })
  h.advance(0.5)
  if #h.runs > finished then
    for remaining = id + 1, 10 do h.runs[#h.runs].missing[remaining] = true end
    h.finish(#h.runs)
    finished = #h.runs
  end
end
h.advance(2)
assert(#h.runs >= 2 and #h.runs <= 4, "a steady stream of arrivals must coalesce into bounded, non-starving refreshes")
h.finish(#h.runs)
local settledRuns = #h.runs
h.advance(5)
assert(#h.runs == settledRuns and not h.widgets.status.text:find("Calculating", 1, true),
  "the list must settle after the arrival stream ends")

h = harness()
h.results.vendor = { rows = {}, meta = {} }
h.results.deals = { rows = {}, meta = {} }
h.dirty.deals = false
h.recompute()
h.select("deals")
assert(h.runs[1].cancelled and h.dirty.vendor, "switching to a cached view must invalidate the canceled computation")
assert(not h.widgets.status.text:find("Calculating", 1, true), "a cached view must not show an inactive calculation")
h.frame.shown = false
h.cancel()
h.frame.shown = true
h.select("vendor")
assert(#h.runs == 2, "returning to the canceled view must rebuild it")

for _, view in ipairs({ "vendor", "deals" }) do
  h = harness()
  h.AT.db.activeView = view
  h.recompute()
  local oldRows = { { id = 1, name = "Item", unit = 100, cost = 200, profit = 50 } }
  h.finish(1, oldRows)
  h.AT.Buy.exhausted[view] = { [2] = true }
  h.markDirty({ [view] = true })
  h.advance(0.2)
  h.toggle()
  assert(h.AT.db.views[view].mode == "bid" and #h.runs == 3,
    "the toggle must start bid analysis immediately")
  assert(h.runs[2].cancelled and h.results[view] == nil and #h.display == 0,
    "switching modes must cancel old work and hide stale buyout prices")
  assert(h.AT.Buy.exhausted[view] == nil, "buyout exhaustion must not hide bid opportunities")
  assert(h.widgets.buy.text == "Bid" and not h.widgets.buy.enabled,
    "bids must remain unavailable until bid results arrive")
  assert(h.widgets.headers[3].label.text == "Bid Each", "price headers must identify bid mode")
  h.finish(2, oldRows)
  assert(#h.display == 0, "a canceled buyout analysis must not republish buyout prices")
  local bidRows = { { id = 1, name = "Item", unit = 60, cost = 120, profit = 90 } }
  h.finish(3, bidRows)
  assert(h.display[1] == bidRows[1], "bid results must replace buyout results")
  h.toggle()
  assert(h.AT.db.views[view].mode == "buyout" and #h.runs == 4 and #h.display == 0,
    "switching back must rebuild buyout prices, not reuse bid results")
  assert(h.widgets.headers[3].label.text == "Buyout Each", "price headers must identify buyout mode")
  h.finish(4, oldRows)
  h.AT.Buy.state = "offer"
  h.toggle()
  assert(h.AT.db.views[view].mode == "buyout" and #h.runs == 4,
    "a pending confirmation must not be relabeled as a different purchase mode")
end

h = harness()
h.recompute()
h.finish(1, { { id = 1, name = "Summary item", profit = 10 } })
h.toggle()
h.finish(2, {}, { noData = true, needFull = true })
assert(#h.display == 0 and h.widgets.empty.text:find("Bid mode needs a full scan", 1, true),
  "summary-only bid mode must show the full-scan requirement instead of old buyouts")

print("List refresh tests passed")
