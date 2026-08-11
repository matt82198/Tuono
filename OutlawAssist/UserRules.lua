local ADDON_NAME, OA = ...

-- ============================================================================
-- USER-EDITABLE PRIORITY RULES
-- ============================================================================
-- Hekili-shaped: an ORDERED list of rows, each row = one ability + zero or more
-- conditions, all AND-ed. The engine walks top to bottom, FIRST MATCH WINS. That is how
-- rotation guides are written, how the built-in profiles are written, and what the
-- in-game editor edits -- one vocabulary end to end, so a user copy of a built-in
-- profile round-trips without losing meaning.
--
-- Rows are plain data (no functions), so they serialise straight into SavedVariables
-- and can later be shared as strings without executing anything a stranger wrote.
-- Conditions are COMPILED to a predicate at load; the editor never stores Lua.
-- ============================================================================

OA.UserRules = OA.UserRules or {}
local U = OA.UserRules

-- Condition vocabulary. `readable` documents whether the underlying value survives
-- Midnight's secret-value system, so the editor can warn instead of letting someone
-- build a rule that can never fire in a keystone.
U.CONDITION_TYPES = {
	{ id = "always",     label = "Always",              needsOp = false, needsValue = false, readable = true },
	{ id = "cp",         label = "Combo points",        needsOp = true,  needsValue = true,  readable = true },
	{ id = "energy",     label = "Energy (estimated)",  needsOp = true,  needsValue = true,  readable = false },
	{ id = "cdReady",    label = "This spell is ready", needsOp = false, needsValue = false, readable = true },
	{ id = "cdReadyOf",  label = "Other spell ready",   needsOp = false, needsValue = false, readable = true,  needsSpell = true },
	{ id = "buffUp",     label = "Buff is up",          needsOp = false, needsValue = false, readable = false, needsSpell = true },
	{ id = "stealthed",  label = "Stealthed",           needsOp = false, needsValue = false, readable = true },
	{ id = "enemyCount", label = "Enemies nearby",      needsOp = true,  needsValue = true,  readable = true },
	{ id = "rtbStage",   label = "Roll the Bones stage",needsOp = true,  needsValue = true,  readable = false },
}

U.OPERATORS = { "<", "<=", "==", ">=", ">" }

function U.GetConditionType(id)
	for _, t in ipairs(U.CONDITION_TYPES) do
		if t.id == id then return t end
	end
	return nil
end

local function compare(op, a, b)
	if op == "<"  then return a <  b end
	if op == "<=" then return a <= b end
	if op == "==" then return a == b end
	if op == ">=" then return a >= b end
	if op == ">"  then return a >  b end
	return false
end

-- Compile one condition into a predicate. Unknown-resource handling mirrors the engine:
-- an unprovable "at least" fails, an unprovable "at most" passes. See Rotation.lua.
local function compileCondition(cond, profile, ownSpellKey)
	local H = function() return OA.RuleHelpers end
	local ctype = cond.type

	if ctype == "always" then
		return function() return true end

	elseif ctype == "cp" then
		return function(S)
			local h = H()
			if not h.cpIsKnown(S) then
				-- Lower bounds are unprovable when CP is hidden; upper bounds pass.
				return (cond.op == "<" or cond.op == "<=")
			end
			return compare(cond.op, S.comboPoints, cond.value or 0)
		end

	elseif ctype == "energy" then
		return function(S)
			local h = H()
			if not h.energyKnown(S) then return true end   -- never block on an estimate we lack
			return compare(cond.op, S.energy, cond.value or 0)
		end

	elseif ctype == "cdReady" then
		return function(S)
			return H().cdOf(S, ownSpellKey).ready
		end

	elseif ctype == "cdReadyOf" then
		local key = cond.spell
		return function(S)
			return H().cdOf(S, key).ready
		end

	elseif ctype == "buffUp" then
		local key = cond.spell
		return function(S)
			local b = S.buffs and S.buffs[key]
			if b == nil then return false end
			if type(b) == "table" then return b.up == true or (b.stage or 0) > 0 end
			return b == true
		end

	elseif ctype == "stealthed" then
		return function(S) return S.stealthed == true end

	elseif ctype == "enemyCount" then
		return function(S)
			-- nil means "could not count", which must not read as zero enemies.
			if S.enemyCount == nil then return false end
			return compare(cond.op, S.enemyCount, cond.value or 0)
		end

	elseif ctype == "rtbStage" then
		return function(S)
			local stage = (S.buffs and S.buffs.rtb and S.buffs.rtb.stage) or 0
			return compare(cond.op, stage, cond.value or 0)
		end
	end

	-- Unknown condition type: fail CLOSED. A row nobody can interpret must not silently
	-- become "always true" and hijack position 1.
	return function() return false end
end

-- Compile a stored row into the rule shape Rotation.Predict consumes.
function U.Compile(row, profile)
	local spells = profile.spells or {}
	local spellID = spells[row.spellKey]
	if not spellID then return nil end

	local preds = {}
	for _, cond in ipairs(row.conditions or {}) do
		table.insert(preds, compileCondition(cond, profile, row.spellKey))
	end

	return {
		name = row.name or (row.spellKey .. " (custom)"),
		spellKey = row.spellKey,
		spellID = spellID,
		requiresSpell = row.requiresSpell,
		conditions = row.conditions,
		userRow = row,
		when = function(S, A)
			-- Affordability is enforced for every user rule, so the editor cannot produce
			-- a row that recommends something the player provably cannot cast.
			if not OA.RuleHelpers.canAfford(S, spellID) then return false end
			for _, p in ipairs(preds) do
				local ok, res = pcall(p, S, A)
				if not ok or not res then return false end
			end
			return true
		end
	}
end

-- Storage: OA.db.profiles[profileId] = { priority = { row, ... } }
local function store(profileId)
	OA.db = OA.db or {}
	OA.db.profiles = OA.db.profiles or {}
	OA.db.profiles[profileId] = OA.db.profiles[profileId] or {}
	return OA.db.profiles[profileId]
end
U.Store = store

-- Turn a built-in profile's priority list into editable rows. The built-ins carry
-- `conditions` metadata precisely so the editor can seed from them rather than
-- presenting the user a blank page.
-- A profile carries two independently editable rotations. "single" and "aoe" are the
-- only kinds; everything below is parameterised by kind so the editor, the store and
-- the engine all address the same two lists.
U.LIST_KINDS = { "single", "aoe" }

local function profileList(profile, kind)
	if kind == "aoe" then return profile.priorityAoE end
	return profile.priority
end

function U.RowsFromProfile(profile, kind)
	local rows = {}
	for _, rule in ipairs(profileList(profile, kind) or {}) do
		table.insert(rows, {
			name = rule.name,
			spellKey = rule.spellKey,
			requiresSpell = rule.requiresSpell,
			enabled = true,
			conditions = rule.conditions and (function()
				local c = {}
				for _, cond in ipairs(rule.conditions) do
					local copy = {}
					for k, v in pairs(cond) do copy[k] = v end
					table.insert(c, copy)
				end
				return c
			end)() or { { type = "always" } },
		})
	end
	return rows
end

local function storeKey(kind)
	return (kind == "aoe") and "priorityAoE" or "priority"
end

function U.IsCustomised(profileId, kind)
	local s = OA.db and OA.db.profiles and OA.db.profiles[profileId]
	return s ~= nil and s[storeKey(kind)] ~= nil
end

-- Materialise an editable copy, seeded from the built-in list on first open.
function U.GetRows(profile, kind)
	local s = store(profile.id)
	local key = storeKey(kind)
	if not s[key] then
		s[key] = U.RowsFromProfile(profile, kind)
	end
	return s[key]
end

function U.ResetToDefault(profileId, kind)
	store(profileId)[storeKey(kind)] = nil
end

-- What the engine actually runs. Falls back to the built-in list whenever the user has
-- not customised, so an untouched install behaves exactly as the profile author wrote.
function U.EffectivePriority(profile, kind)
	if not U.IsCustomised(profile.id, kind) then
		return profileList(profile, kind) or {}
	end
	local compiled = {}
	for _, row in ipairs(store(profile.id)[storeKey(kind)] or {}) do
		if row.enabled ~= false then
			local rule = U.Compile(row, profile)
			if rule then table.insert(compiled, rule) end
		end
	end
	-- An all-disabled or fully broken custom list would render an empty bar, which reads
	-- as "the addon is broken". Fall back rather than show nothing.
	if #compiled == 0 then return profileList(profile, kind) or {} end
	return compiled
end

function U.MoveRow(profileId, kind, index, delta)
	local rows = store(profileId)[storeKey(kind)]
	if not rows then return false end
	local target = index + delta
	if target < 1 or target > #rows then return false end
	rows[index], rows[target] = rows[target], rows[index]
	return true
end

function U.DeleteRow(profileId, kind, index)
	local rows = store(profileId)[storeKey(kind)]
	if not rows or not rows[index] then return false end
	table.remove(rows, index)
	return true
end

function U.AddRow(profileId, kind, spellKey)
	local rows = store(profileId)[storeKey(kind)]
	if not rows then return false end
	table.insert(rows, {
		name = nil,
		spellKey = spellKey,
		enabled = true,
		conditions = { { type = "always" } },
	})
	return true
end

-- Human-readable one-liner for the editor list.
function U.DescribeRow(row)
	local parts = {}
	for _, cond in ipairs(row.conditions or {}) do
		local t = U.GetConditionType(cond.type)
		local label = t and t.label or cond.type
		if t and t.needsOp and t.needsValue then
			table.insert(parts, label .. " " .. tostring(cond.op) .. " " .. tostring(cond.value))
		elseif t and t.needsSpell then
			table.insert(parts, label .. ": " .. tostring(cond.spell))
		else
			table.insert(parts, label)
		end
	end
	if #parts == 0 then return "always" end
	return table.concat(parts, " AND ")
end
