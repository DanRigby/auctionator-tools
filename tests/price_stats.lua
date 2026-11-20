-- Run from the repository root with Lua 5.1 or later.
function CreateFrame() return { RegisterEvent = function() end, SetScript = function() end } end
function wipe(t) for k in pairs(t) do t[k] = nil end return t end
C_EventUtils = { IsEventValid = function() return false end }

local DAY = 86400
local today = 100
Auctionator = {
  API = { v1 = {} },
  Constants = { SCAN_DAY_0 = 0 },
  Database = { db = {
    ["1"] = {
      h = { [today] = 500, [today - 5] = 300, ["90"] = 900, [today - 14] = 99999 },
      l = { [today] = 200, [today - 5] = 100 },
    },
    ["2"] = { h = { [today - 20] = 100 } },
  } },
}
function time() return today * DAY + 10 end

local AT = { db = { historyDays = 14 }, OnEvent = function() end }
assert(loadfile("AuctionatorTools/Data.lua"))("AuctionatorTools", AT)

local stats = AT.Data.PriceStats(1)
assert(stats.days == 3, "today and the 13 days before count, older days don't")
assert(stats.min == 100, "min uses the daily lows")
assert(stats.max == 900, "max uses the daily highs, including string day keys")
assert(stats.avg == 400, "average is the mean daily low, falling back to the high")
assert(AT.Data.PriceStats(2) == nil, "no stats without recent history")
assert(AT.Data.PriceStats(3) == nil, "no stats without any history")
print("price_stats: ok")
