-- Moves raid members into the exact group and in-group position listed in a
-- positional invite list (5 fields per group). The raid roster only reflects
-- a change after GROUP_ROSTER_UPDATE, so the next move waits until the roster
-- shows the previous one.
WowauditGroupArranger = {}
local arranger = WowauditGroupArranger

local GROUP_SIZE = 5
local GROUP_COUNT = 8
local SLOT_COUNT = GROUP_SIZE * GROUP_COUNT
local UPDATE_TIMEOUT = 2
local STALL_TIMEOUT = 15
local MAX_OPERATIONS = 200
-- Fixing a position takes three swaps that can temporarily misplace more
-- members, so a few moves without improvement are expected.
local MAX_MOVES_WITHOUT_PROGRESS = 10
local DEFAULT_WATCH_DURATION = 120

local state = nil
local eventFrame = CreateFrame("Frame")
local ticker = nil
local stepScheduled = false

local function lower(text)
  return string.lower(text or "")
end

local function trim(text)
  return (text or ""):match("^%s*(.-)%s*$")
end

local function print_(message)
  print("|cff2ba8ffwowaudit|r " .. message)
end

local function fullName(name, fallbackRealm)
  if not name or name == "" then
    return nil
  end
  if not string.find(name, "-", 1, true) and fallbackRealm then
    return name .. "-" .. fallbackRealm
  end
  return name
end

local function canArrange()
  return IsInRaid() and (UnitIsGroupLeader("player") or UnitIsGroupAssistant("player"))
end

local function buildRoster()
  local _, selfRealm = UnitFullName("player")
  local roster = { members = {}, byName = {}, groupSize = {}, occupants = {} }
  for group = 1, GROUP_COUNT do
    roster.groupSize[group] = 0
    roster.occupants[group] = {}
  end

  for index = 1, GetNumGroupMembers() or 0 do
    local name, rank, subgroup = GetRaidRosterInfo(index)
    local memberName = fullName(name, selfRealm)
    if memberName and subgroup then
      local unit = "raid" .. index
      roster.groupSize[subgroup] = roster.groupSize[subgroup] + 1
      local member = {
        index = index,
        name = memberName,
        key = lower(memberName),
        subgroup = subgroup,
        pos = roster.groupSize[subgroup],
        leader = rank == 2,
        combat = UnitAffectingCombat(unit) and true or false,
      }
      table.insert(roster.members, member)
      roster.byName[member.key] = member
      roster.occupants[subgroup][member.pos] = member
    end
  end

  return roster
end

-- Listed players are compacted per group in list order because positions in a
-- group follow the roster order, so a gap inside a group cannot exist in-game.
-- The leader always shows first in their group, so they lead their target group.
-- Without exact positions, listed members only need to end up in their group.
local function assignTargets(roster, slots, exactPositions)
  local _, selfRealm = UnitFullName("player")
  local groups = {}
  for group = 1, GROUP_COUNT do
    groups[group] = {}
  end

  local listed = {}
  for slot = 1, SLOT_COUNT do
    local key = lower(fullName(trim(slots[slot]), selfRealm))
    local member = key ~= "" and roster.byName[key] or nil
    if member and not listed[member.key] then
      listed[member.key] = true
      member.flexible = not exactPositions
      table.insert(groups[math.ceil(slot / GROUP_SIZE)], member)
    end
  end

  for group = 1, GROUP_COUNT do
    for position, member in ipairs(groups[group]) do
      if member.leader and position > 1 then
        table.remove(groups[group], position)
        table.insert(groups[group], 1, member)
        break
      end
    end
  end

  -- Unlisted members fill up from the last group backwards, ordered by name, so
  -- they stay out of the raiding groups and their targets don't depend on where
  -- they currently are.
  local unlisted = {}
  local unlistedLeader = nil
  for _, member in ipairs(roster.members) do
    if not listed[member.key] then
      member.flexible = true
      if member.leader then
        unlistedLeader = member
      else
        table.insert(unlisted, member)
      end
    end
  end

  if unlistedLeader then
    local leaderGroup = nil
    for group = GROUP_COUNT, 1, -1 do
      if not leaderGroup and #groups[group] == 0 then
        leaderGroup = group
      end
    end
    for group = GROUP_COUNT, 1, -1 do
      if not leaderGroup and #groups[group] < GROUP_SIZE then
        leaderGroup = group
      end
    end
    if leaderGroup then
      table.insert(groups[leaderGroup], 1, unlistedLeader)
    end
  end
  table.sort(unlisted, function(left, right) return left.key < right.key end)

  for _, member in ipairs(unlisted) do
    for group = GROUP_COUNT, 1, -1 do
      if #groups[group] < GROUP_SIZE then
        table.insert(groups[group], member)
        break
      end
    end
  end

  for group = 1, GROUP_COUNT do
    for position, member in ipairs(groups[group]) do
      member.targetGroup = group
      member.targetPos = position
    end
  end

  return groups
end

local function misplacedNames(groups)
  local names = {}
  for group = 1, GROUP_COUNT do
    for position, member in ipairs(groups[group]) do
      local misplaced = member.subgroup ~= group or (not member.flexible and member.pos ~= position)
      if misplaced then
        table.insert(names, member.name)
      end
    end
  end
  return names
end

-- Every move changes the subgroup of the members involved, which is what the
-- next roster has to show before the move counts as applied.
local function swap(first, second)
  SwapRaidSubgroup(first.index, second.index)
  state.expectedSubgroups = { [first.key] = second.subgroup, [second.key] = first.subgroup }
  return true
end

local function moveIntoGroup(roster, member, group)
  for _, occupant in ipairs(roster.members) do
    if occupant.subgroup == group and occupant.targetGroup ~= group and not occupant.combat then
      return swap(member, occupant)
    end
  end
  if roster.groupSize[group] < GROUP_SIZE then
    SetRaidSubgroup(member.index, group)
    state.expectedSubgroups = { [member.key] = group }
    return true
  end
  return false
end

-- Members that left the raid can't show the move anymore, so they don't hold it up.
local function operationApplied(roster)
  for key, subgroup in pairs(state.expectedSubgroups or {}) do
    local member = roster.byName[key]
    if member and member.subgroup ~= subgroup then
      return false
    end
  end
  return true
end

local function runPendingSwap(roster)
  local pending = state.pendingSwap
  state.pendingSwap = nil
  if not pending then
    return false
  end

  local member = roster.byName[pending.member]
  local goal = roster.byName[pending.goal]
  if not member or not goal or member.combat or goal.combat then
    return false
  end
  if member.subgroup == pending.group or goal.subgroup ~= pending.group then
    return false
  end
  return swap(member, goal)
end

local function fixGroups(roster, groups)
  for group = 1, GROUP_COUNT do
    for _, member in ipairs(groups[group]) do
      if member.subgroup ~= group and not member.combat and moveIntoGroup(roster, member, group) then
        return true
      end
    end
  end
  return false
end

-- Two members of the same group cannot be swapped directly, so the misplaced
-- member is swapped out with someone from another group first and then swapped
-- into the slot of the member that holds its target position.
local function fixPositions(roster, groups)
  for group = 1, GROUP_COUNT do
    for position, member in ipairs(groups[group]) do
      if not member.flexible and member.subgroup == group and member.pos ~= position then
        local goal = roster.occupants[group][position]
        if goal and not goal.leader and not goal.combat and not member.combat then
          local helper = nil
          for _, candidate in ipairs(roster.members) do
            if candidate.subgroup ~= group and not candidate.combat then
              if not helper or (candidate.flexible and not helper.flexible) then
                helper = candidate
              end
            end
          end
          if helper then
            state.pendingSwap = { member = member.key, goal = goal.key, group = group }
            return swap(member, helper)
          end
        end
      end
    end
  end
  return false
end

-- Progress is a drop in misplaced members rather than any move, so a move
-- sequence that doesn't converge stops early. Joins and leaves change what is
-- achievable, so they start a fresh count.
local function trackProgress(roster, misplacedCount, now)
  if #roster.members ~= state.rosterSize then
    state.rosterSize = #roster.members
    state.fewestMisplaced = misplacedCount
    state.movesWithoutProgress = 0
    state.lastProgressAt = now
  elseif misplacedCount < state.fewestMisplaced then
    state.fewestMisplaced = misplacedCount
    state.movesWithoutProgress = 0
    state.lastProgressAt = now
  end
end

local function finish(message)
  if message then
    print_(message)
  end
  arranger:Stop()
end

function arranger:Step()
  stepScheduled = false
  if not state then
    return
  end

  local now = GetTime()
  if state.watchUntil and now > state.watchUntil then
    finish(state.arranged and "Group arrangement finished." or "Stopped watching for raid members to arrange.")
    return
  end

  if not IsInRaid() then
    if state.watchUntil and (GetNumGroupMembers() or 0) > 1 and UnitIsGroupLeader("player") then
      C_PartyInfo.ConvertToRaid()
    end
    return
  end

  if not canArrange() then
    finish("You need to be the raid leader or an assistant to arrange groups.")
    return
  end

  local roster = buildRoster()
  if state.awaitingUpdate then
    if not operationApplied(roster) and now - state.lastOperationAt < UPDATE_TIMEOUT then
      return
    end
    state.awaitingUpdate = false
    state.expectedSubgroups = nil
  end

  local groups = assignTargets(roster, state.slots, state.exactPositions)
  local misplaced = misplacedNames(groups)
  trackProgress(roster, #misplaced, now)

  if #misplaced == 0 then
    state.pendingSwap = nil
    if not state.arranged then
      state.arranged = true
      if not state.watchUntil then
        finish("Raid groups arranged.")
      end
    end
    return
  end
  state.arranged = false

  if state.operations >= MAX_OPERATIONS then
    finish("Stopped arranging groups after too many moves.")
    return
  end

  -- While watching, a roster change resets the count and allows another attempt.
  if state.movesWithoutProgress >= MAX_MOVES_WITHOUT_PROGRESS then
    state.pendingSwap = nil
    if not state.watchUntil then
      finish("Could not finish arranging groups: " .. table.concat(misplaced, ", "))
    end
    return
  end

  local moved = runPendingSwap(roster) or fixGroups(roster, groups) or fixPositions(roster, groups)
  if moved then
    state.operations = state.operations + 1
    state.movesWithoutProgress = state.movesWithoutProgress + 1
    state.awaitingUpdate = true
    state.lastOperationAt = now
    return
  end

  if not state.watchUntil and now - state.lastProgressAt > STALL_TIMEOUT then
    finish("Could not finish arranging groups (players in combat?): " .. table.concat(misplaced, ", "))
  end
end

function arranger:ScheduleStep()
  if stepScheduled or not state then
    return
  end
  stepScheduled = true
  C_Timer.After(0.1, function() arranger:Step() end)
end

-- slots: array of up to 40 names where index 1-5 is group 1, 6-10 group 2, etc.
-- options.watch keeps arranging new raid members for options.duration seconds.
-- options.exactPositions = false only enforces groups, for lists without positions.
function arranger:Start(slots, options)
  options = options or {}
  local now = GetTime()
  state = {
    slots = slots or {},
    exactPositions = options.exactPositions ~= false,
    operations = 0,
    movesWithoutProgress = 0,
    awaitingUpdate = false,
    lastOperationAt = 0,
    lastProgressAt = now,
    arranged = false,
    watchUntil = options.watch and (now + (options.duration or DEFAULT_WATCH_DURATION)) or nil,
  }

  eventFrame:RegisterEvent("GROUP_ROSTER_UPDATE")
  if ticker then
    ticker:Cancel()
  end
  ticker = C_Timer.NewTicker(1, function() arranger:Step() end)

  if not options.watch and not canArrange() then
    finish(IsInRaid() and "You need to be the raid leader or an assistant to arrange groups." or "You need to be in a raid to arrange groups.")
    return
  end

  if options.watch then
    print_(string.format("Arranging groups and watching for new raid members for %d seconds.", options.duration or DEFAULT_WATCH_DURATION))
  end
  arranger:ScheduleStep()
end

function arranger:Stop()
  state = nil
  stepScheduled = false
  eventFrame:UnregisterEvent("GROUP_ROSTER_UPDATE")
  if ticker then
    ticker:Cancel()
    ticker = nil
  end
end

function arranger:IsActive()
  return state ~= nil
end

eventFrame:SetScript("OnEvent", function()
  arranger:ScheduleStep()
end)
