if WowauditGameVersion ~= "classic_forever" then return end

local CAPTURE_DELAY = 1
-- Leveling a profession changes the skill with every craft, so the sync waits until crafting stops.
local SYNC_DEBOUNCE = 30
local MAX_PROFESSIONS = 2
local MAX_SKILL = 1000
local MAX_INDEX_LENGTH = 4000
local BASE36_DIGITS = "0123456789abcdefghijklmnopqrstuvwxyz"

-- Views of someone else's recipes or an NPC's crafting list must not overwrite our own.
local FOREIGN_VIEW_CHECKS = {
  "IsTradeSkillLinked",
  "IsTradeSkillGuild",
  "IsTradeSkillGuildMember",
  "IsNPCCrafting",
  "IsRuneforging",
}

local function isWholeNumber(value, min, max)
  return type(value) == "number" and value == math.floor(value) and value >= min and value <= max
end

local function toBase36(value)
  if value == 0 then return "0" end

  local digits = ""
  while value > 0 do
    local digit = value % 36
    digits = BASE36_DIGITS:sub(digit + 1, digit + 1) .. digits
    value = math.floor(value / 36)
  end
  return digits
end

-- Mirrors Audit::RecipeIndex in core: sorted ids collapsed into runs of consecutive ids, each run
-- written as the base36 delta from the end of the previous run plus "-<base36 extra length>" when
-- it holds more than one id, joined by ".". For example { 3, 4, 5, 9 } becomes "3-2.4".
local function encodeRecipeIndex(ids)
  local sorted, seen = {}, {}
  for _, id in ipairs(ids) do
    if not seen[id] then
      seen[id] = true
      sorted[#sorted + 1] = id
    end
  end
  table.sort(sorted)

  local tokens, previous, i = {}, 0, 1
  while i <= #sorted do
    local first, last = sorted[i], sorted[i]
    while sorted[i + 1] == last + 1 do
      i = i + 1
      last = sorted[i]
    end

    local token = toBase36(first - previous)
    if last > first then
      token = token .. "-" .. toBase36(last - first)
    end
    tokens[#tokens + 1] = token
    previous = last
    i = i + 1
  end
  return table.concat(tokens, ".")
end

local function isValidRecipeIndex(value)
  if type(value) ~= "string" or #value > MAX_INDEX_LENGTH then return false end
  if value == "" then return true end

  for token in (value .. "."):gmatch("([^.]*)%.") do
    if not token:match("^[%da-z]+$") and not token:match("^[%da-z]+%-[%da-z]+$") then return false end
  end
  return true
end

-- Recipes use the website's known recipe format, keyed by profession id as a string so the
-- desktop client exports them as objects: { ["164"] = { s = { ["2938"] = { 300, 300 } }, r = "3-2.4" } }.
-- On the guild channel each profession travels as "professionId:tierId:rank:maxRank:index".
local function encodeRecipes(recipes)
  if not recipes then return nil end

  local parts = {}
  for professionId, profession in pairs(recipes) do
    local tierId, skill = next(profession.s or {})
    if tierId and skill then
      parts[#parts + 1] = table.concat({ professionId, tierId, skill[1], skill[2], profession.r }, ":")
    end
  end
  table.sort(parts)
  return table.concat(parts, ";")
end

local function decodeRecipes(value)
  if type(value) ~= "string" then return nil end

  local recipes, count = {}, 0
  for part in value:gmatch("[^;]+") do
    local professionId, tierId, rank, maxRank, index = part:match("^(%d+):(%d+):(%d+):(%d+):([%da-z%.%-]*)$")
    rank, maxRank = tonumber(rank), tonumber(maxRank)
    if not professionId or rank > MAX_SKILL or maxRank > MAX_SKILL or not isValidRecipeIndex(index) then return nil end

    count = count + 1
    if count > MAX_PROFESSIONS or recipes[professionId] then return nil end
    recipes[professionId] = { s = { [tierId] = { rank, maxRank } }, r = index }
  end
  return recipes
end

ForeverSync.encodeRecipes = encodeRecipes
ForeverSync.decodeRecipes = decodeRecipes
ForeverSync.isValidRecipeTimestamp = function(value)
  return isWholeNumber(value, 1, math.huge)
end

local function isOwnTradeSkill()
  local api = C_TradeSkillUI
  if not api or not api.GetBaseProfessionInfo or not api.GetRecipeInfo then return false end

  for _, check in ipairs(FOREIGN_VIEW_CHECKS) do
    if api[check] and api[check]() then return false end
  end
  if api.IsTradeSkillReady and not api.IsTradeSkillReady() then return false end
  if api.IsDataSourceChanging and api.IsDataSourceChanging() then return false end
  return true
end

-- GetFilteredRecipeIDs follows the frame's search and filters, so it's only a fallback.
local function learnedRecipeIds()
  local api = C_TradeSkillUI
  local recipeIds = (api.GetAllRecipeIDs and api.GetAllRecipeIDs())
    or (api.GetFilteredRecipeIDs and api.GetFilteredRecipeIDs())
    or {}

  local ids = {}
  for _, recipeId in ipairs(recipeIds) do
    local info = api.GetRecipeInfo(recipeId)
    if info and info.learned and isWholeNumber(info.skillLineAbilityID, 1, math.huge) then
      ids[#ids + 1] = info.skillLineAbilityID
    end
  end
  return ids
end

local function hasProfession(professions, professionId)
  for _, profession in ipairs(professions) do
    if profession.skillLine == professionId then return true end
  end
  return false
end

local function sameRecipes(a, b)
  if not a or not b or a.r ~= b.r then return false end

  local tierA, skillA = next(a.s or {})
  local tierB, skillB = next(b.s or {})
  return tierA == tierB and skillA and skillB and skillA[1] == skillB[1] and skillA[2] == skillB[2]
end

function ForeverSync:RegisterRecipeSyncEvents()
  self:SafeRegisterEvent("TRADE_SKILL_SHOW", "ScheduleRecipeCapture")
  self:SafeRegisterEvent("TRADE_SKILL_LIST_UPDATE", "ScheduleRecipeCapture")
  self:SafeRegisterEvent("TRADE_SKILL_DATA_SOURCE_CHANGED", "ScheduleRecipeCapture")
end

function ForeverSync:ScheduleRecipeCapture()
  if self.recipeTimer then return end

  self.recipeTimer = self:ScheduleTimer(function()
    self.recipeTimer = nil
    self:CaptureRecipes()
  end, CAPTURE_DELAY)
end

-- Only primary professions are tracked, the same as on live.
function ForeverSync:CaptureRecipes()
  if not isOwnTradeSkill() then return end

  local base = C_TradeSkillUI.GetBaseProfessionInfo()
  local professionId = base and base.professionID
  if not professionId or not hasProfession(self.collectProfessions(), professionId) then return end

  local tier = C_TradeSkillUI.GetChildProfessionInfo and C_TradeSkillUI.GetChildProfessionInfo()
  if not tier or not tier.professionID or tier.professionID == 0 then
    tier = base
  end

  -- The list can still be loading right after the frame opens.
  local ids = learnedRecipeIds()
  if #ids == 0 then return end

  local profession = {
    s = { [tostring(tier.professionID)] = { tier.skillLevel or 0, tier.maxSkillLevel or 0 } },
    r = encodeRecipeIndex(ids),
  }

  local stored = self.db.char.recipes or {}
  if sameRecipes(stored[tostring(professionId)], profession) then return end

  stored[tostring(professionId)] = profession
  self.db.char.recipes = stored
  self.db.char.recipesUpdatedAt = GetServerTime()
  self:ScheduleRecipeSync()
end

function ForeverSync:ScheduleRecipeSync()
  if self.recipeSyncTimer then
    self:CancelTimer(self.recipeSyncTimer)
  end

  self.recipeSyncTimer = self:ScheduleTimer(function()
    self.recipeSyncTimer = nil
    self:CaptureGear()
  end, SYNC_DEBOUNCE)
end

-- Recipes are kept per character across sessions. Professions the character dropped are removed,
-- unless the profession list is empty, which can also mean it hasn't loaded yet.
function ForeverSync:OwnRecipes(professions)
  local stored = self.db.char.recipes
  if not stored then return nil end

  if #professions > 0 then
    local pruned = false
    for professionId in pairs(stored) do
      if not hasProfession(professions, tonumber(professionId)) then
        stored[professionId] = nil
        pruned = true
      end
    end
    if pruned then
      self.db.char.recipesUpdatedAt = GetServerTime()
    end
  end

  local recipes = {}
  for professionId, profession in pairs(stored) do
    recipes[professionId] = profession
  end
  return recipes, self.db.char.recipesUpdatedAt
end
