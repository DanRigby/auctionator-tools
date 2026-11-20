local _, AT = ...

-- Recipe data is only available while a profession window is open, so it is
-- recorded per character whenever the player opens one of their professions
local TSUI = C_TradeSkillUI

local function IsOwnProfession()
  if not TSUI then
    return false
  end
  if TSUI.IsTradeSkillLinked and TSUI.IsTradeSkillLinked() then return false end
  if TSUI.IsTradeSkillGuild and TSUI.IsTradeSkillGuild() then return false end
  if TSUI.IsNPCCrafting and TSUI.IsNPCCrafting() then return false end
  return true
end

local function ProfessionName(recipeIDs)
  for _, getter in ipairs({ "GetBaseProfessionInfo", "GetChildProfessionInfo" }) do
    local info = TSUI[getter] and TSUI[getter]()
    if info and info.professionName and info.professionName ~= "" then
      return info.professionName
    end
  end
  if TSUI.GetTradeSkillLineForRecipe and recipeIDs[1] then
    local _, name = TSUI.GetTradeSkillLineForRecipe(recipeIDs[1])
    if name and name ~= "" then
      return name
    end
  end
end

local function ReadRecipe(recipeID)
  local info = TSUI.GetRecipeInfo(recipeID)
  if not info or not info.learned or info.isDummyRecipe or info.isGatheringRecipe
    or info.isSalvageRecipe or info.isRecraft then
    return nil
  end
  local schematic = TSUI.GetRecipeSchematic(recipeID, false)
  if not schematic or not schematic.outputItemID then
    return nil
  end
  local basic = Enum.CraftingReagentType and Enum.CraftingReagentType.Basic
  local reagents = {}
  for _, slot in ipairs(schematic.reagentSlotSchematics or {}) do
    local isBasic = (basic and slot.reagentType == basic) or (not basic and slot.required)
    local reagent = slot.reagents and slot.reagents[1]
    if isBasic and reagent and reagent.itemID and (slot.quantityRequired or 0) > 0 then
      table.insert(reagents, { id = reagent.itemID, n = slot.quantityRequired })
    end
  end
  if #reagents == 0 then
    return nil
  end
  local minYield = schematic.quantityMin or 1
  local maxYield = schematic.quantityMax or minYield
  return {
    name = info.name,
    out = schematic.outputItemID,
    yield = math.max((minYield + maxYield) / 2, 1),
    reagents = reagents,
  }
end

local function ScanProfession()
  if not AT.char or not IsOwnProfession() then
    return
  end
  local recipeIDs = TSUI.GetAllRecipeIDs and TSUI.GetAllRecipeIDs()
  if not recipeIDs or #recipeIDs == 0 then
    return
  end
  local name = ProfessionName(recipeIDs)
  if not name then
    return
  end
  AT.RunJob("professions", function()
    local recipes, count = {}, 0
    for i, recipeID in ipairs(recipeIDs) do
      AT.MaybeYield(i)
      local recipe = ReadRecipe(recipeID)
      if recipe then
        recipes[recipeID] = recipe
        count = count + 1
      end
    end
    return count > 0 and recipes or nil
  end, function(recipes)
    if recipes then
      AT.char.professions[name] = { recipes = recipes, time = time() }
      AT.Send("ProfessionsUpdated")
    end
  end)
end

local function QueueScan()
  AT.Debounce("professions", 0.5, ScanProfession)
end

AT.OnEvent("TRADE_SKILL_SHOW", QueueScan)
AT.OnEvent("TRADE_SKILL_LIST_UPDATE", QueueScan)
AT.OnEvent("TRADE_SKILL_DATA_SOURCE_CHANGED", QueueScan)

-- Forget professions the character has since dropped
local function PruneProfessions()
  if not AT.char or not GetProfessions or not GetProfessionInfo then
    return
  end
  local current = {}
  local any = false
  for _, index in pairs({ GetProfessions() }) do
    local name = GetProfessionInfo(index)
    if name then
      current[name] = true
      any = true
    end
  end
  if not any then
    return
  end
  local matched = false
  for name in pairs(AT.char.professions) do
    if current[name] then
      matched = true
    end
  end
  if not matched then
    return
  end
  local changed = false
  for name in pairs(AT.char.professions) do
    if not current[name] then
      AT.char.professions[name] = nil
      changed = true
    end
  end
  if changed then
    AT.Send("ProfessionsUpdated")
  end
end

AT.OnEvent("PLAYER_LOGIN", function()
  C_Timer.After(5, PruneProfessions)
end)
AT.OnEvent("SKILL_LINES_CHANGED", function()
  AT.Debounce("pruneProfessions", 2, PruneProfessions)
end)
