local ADDON_NAME, Tuono = ...

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

Tuono.UserRules = Tuono.UserRules or {}
local U = Tuono.UserRules

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
	local H = function() return Tuono.RuleHelpers end
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
			-- PREFER THE INTERVAL OVER THE POINT ESTIMATE. S.energy is a single number
			-- carried through the simulation, but the authoritative model brackets energy
			-- in [energyLo, energyHi]. Testing the point estimate lets an UNPROVABLE claim
			-- read as false -- the unknown-as-no defect in a different costume. The house
			-- rule for energy is that an unprovable claim PASSES and carries its
			-- uncertainty into the confidence rating instead.
			local lo, hi, value = S.energyLo, S.energyHi, cond.value or 0
			if type(lo) == "number" and type(hi) == "number" then
				if cond.op == ">=" then return hi >= value end
				if cond.op == ">"  then return hi >  value end
				if cond.op == "<=" then return lo <= value end
				if cond.op == "<"  then return lo <  value end
				-- Equality against a bracketed value is disprovable, never provable.
				return lo <= value and hi >= value
			end
			return compare(cond.op, S.energy, value)
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
			if type(b) == "table" then
				-- A STAGED BUFF CARRIES ITS OWN READABILITY FLAG. `stage` reads 0 both
				-- when the buff is absent and when we could not see it, so inferring
				-- "the buff is up" from a stage we cannot read is the same defect the
				-- rtbStage branch below guards against. Fall back to `up`, which is at
				-- least a direct claim.
				if b.stageKnown == false then return b.up == true end
				return b.up == true or (b.stage or 0) > 0
			end
			return b == true
		end

	elseif ctype == "stealthed" then
		return function(S) return S.stealthed == true end

	elseif ctype == "enemyCount" then
		return function(S)
			-- nil means "could not count", which must not read as zero enemies -- but it
			-- must not suppress every single-target gate either. Same asymmetry as combo
			-- points, for the same reason: an unprovable LOWER bound fails (we will not
			-- claim three enemies we cannot see), an unprovable UPPER bound passes.
			-- Failing both directions is what left an unreadable count killing every
			-- rule that mentioned it.
			if S.enemyCount == nil then
				return (cond.op == "<" or cond.op == "<=")
			end
			return compare(cond.op, S.enemyCount, cond.value or 0)
		end

	elseif ctype == "rtbStage" then
		return function(S)
			-- FAIL CLOSED ON AN UNREADABLE STAGE. Every rtbStage comparison authorises
			-- spending a cooldown -- rerolling below a stage, or Keep It Rolling above
			-- one -- so every one of them is a positive claim, whichever way the operator
			-- points. `stage` reads 0 both when there is no buff and when we cannot see
			-- one, and treating the second as the first is what told players to reroll a
			-- Jackpot every 45 seconds.
			--
			-- This branch had no guard at all while the built-in closures did, and
			-- compiled rows REPLACE those closures -- so merely opening the editor
			-- reinstated the bug in full.
			local stage, known = H().rtbStage(S)
			if not known then return false end
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
			if not Tuono.RuleHelpers.canAfford(S, spellID) then return false end
			for _, p in ipairs(preds) do
				local ok, res = pcall(p, S, A)
				if not ok or not res then return false end
			end
			return true
		end
	}
end

-- Storage: Tuono.db.profiles[profileId] = { priority = { row, ... } }
local function store(profileId)
	Tuono.db = Tuono.db or {}
	Tuono.db.profiles = Tuono.db.profiles or {}
	Tuono.db.profiles[profileId] = Tuono.db.profiles[profileId] or {}
	return Tuono.db.profiles[profileId]
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

-- ---------------------------------------------------------------------------
-- ROW IDENTITY
-- ---------------------------------------------------------------------------
-- A row's SIGNATURE is a canonical string of everything about it that changes
-- behaviour. Comparing a row against the signature it was SEEDED WITH answers the only
-- question that matters for maintenance: has this user actually edited this row, or is
-- it still the author's?
--
-- Fields are enumerated explicitly rather than walked with pairs(), because pairs()
-- order is undefined and a signature that varies run to run would mark every row edited.
local function condSignature(cond)
	return table.concat({
		tostring(cond.type), tostring(cond.op), tostring(cond.value), tostring(cond.spell),
	}, "\1")
end

local function rowSignature(row)
	local parts = {
		tostring(row.name), tostring(row.spellKey), tostring(row.requiresSpell),
		tostring(row.enabled ~= false),
	}
	for _, cond in ipairs(row.conditions or {}) do
		parts[#parts + 1] = condSignature(cond)
	end
	return table.concat(parts, "\2")
end
U.RowSignature = rowSignature

-- A row is TOUCHED when it no longer matches the baseline it was seeded from. A row with
-- no baseline at all predates this bookkeeping and is treated as touched, which is the
-- conservative direction: it can never discard a real edit.
local function rowIsTouched(row)
	if row.__baseline == nil then return true end
	return row.__baseline ~= rowSignature(row)
end
U.RowIsTouched = rowIsTouched

function U.RowsFromProfile(profile, kind)
	local rows = {}
	for _, rule in ipairs(profileList(profile, kind) or {}) do
		local row = {
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
		}
		-- Stamp the baseline at seed time. This is what lets a later read distinguish
		-- "the user opened the editor" from "the user changed something".
		row.__baseline = rowSignature(row)
		table.insert(rows, row)
	end
	return rows
end

local function storeKey(kind)
	return (kind == "aoe") and "priorityAoE" or "priority"
end

-- Structural edits -- adding, deleting or reordering rows -- cannot be detected by
-- comparing a row against its own baseline, so they are recorded explicitly.
local function structuralKey(kind)
	return storeKey(kind) .. "Edited"
end

-- Adopt baselines for rows stored before this bookkeeping existed.
--
-- Those users were forked by the old write-on-read behaviour, most of them without ever
-- editing anything. A legacy row whose content still matches the built-in it was seeded
-- from is adopted as untouched, so built-in fixes start flowing again. One that DIFFERS
-- is left alone and therefore counts as edited -- that direction can never discard a
-- real edit, which matters more than reclaiming a row whose built-in has since changed.
local function normaliseBaselines(profile, kind)
	local rows = store(profile.id)[storeKey(kind)]
	if not rows then return nil end

	local needs = false
	for _, row in ipairs(rows) do
		if row.__baseline == nil then needs = true break end
	end
	if not needs then return rows end

	local builtinSig = {}
	for _, r in ipairs(U.RowsFromProfile(profile, kind)) do
		builtinSig[tostring(r.name)] = rowSignature(r)
	end
	for _, row in ipairs(rows) do
		if row.__baseline == nil then
			local sig = rowSignature(row)
			if builtinSig[tostring(row.name)] == sig then row.__baseline = sig end
		end
	end
	return rows
end

-- CUSTOMISED MEANS EDITED, NOT MERELY OPENED.
--
-- This used to be `the store has an entry`, and GetRows created that entry on READ -- so
-- looking at the rule list forked a user off the built-in profile permanently and cut
-- them off from every future APL fix, silently, forever. Customisation is now a property
-- of the CONTENT: a structural change, or any row that no longer matches the baseline it
-- was seeded from. Reading cannot produce either.
function U.IsCustomised(profileId, kind)
	local s = Tuono.db and Tuono.db.profiles and Tuono.db.profiles[profileId]
	if not s then return false end
	local rows = s[storeKey(kind)]
	if rows == nil then return false end
	if s[structuralKey(kind)] then return true end

	local profile = Tuono.Profiles and Tuono.Profiles.Get and Tuono.Profiles.Get(profileId)
	if profile then normaliseBaselines(profile, kind) end

	for _, row in ipairs(rows) do
		if rowIsTouched(row) then return true end
	end
	return false
end

-- Materialise an editable copy, seeded from the built-in list on first open. Safe to
-- call from a pure display path: the copy it creates is byte-identical to the built-ins
-- and therefore reads as untouched, so nothing about the player's rotation changes.
function U.GetRows(profile, kind)
	local s = store(profile.id)
	local key = storeKey(kind)
	if not s[key] then
		s[key] = U.RowsFromProfile(profile, kind)
	end
	normaliseBaselines(profile, kind)
	return s[key]
end

-- Rows to mutate. Materialises on demand, because the editing entry points take a
-- profile id rather than a profile and can now be reached before anything has read.
local function rowsForEdit(profileId, kind)
	local s = store(profileId)
	local key = storeKey(kind)
	if not s[key] then
		local profile = Tuono.Profiles and Tuono.Profiles.Get and Tuono.Profiles.Get(profileId)
		if not profile then return nil end
		s[key] = U.RowsFromProfile(profile, kind)
	end
	return s[key]
end

local function markStructural(profileId, kind)
	store(profileId)[structuralKey(kind)] = true
end

function U.ResetToDefault(profileId, kind)
	local s = store(profileId)
	s[storeKey(kind)] = nil
	s[structuralKey(kind)] = nil
end

-- What the engine actually runs. Falls back to the built-in list whenever the user has
-- not customised, so an untouched install behaves exactly as the profile author wrote.
function U.EffectivePriority(profile, kind)
	if not U.IsCustomised(profile.id, kind) then
		return profileList(profile, kind) or {}
	end
	normaliseBaselines(profile, kind)

	-- AN UNTOUCHED ROW KEEPS RUNNING THE AUTHOR'S OWN CLOSURE.
	--
	-- The built-in rules are hand-written Lua carrying guards the condition compiler does
	-- not reproduce row for row, and a user who edited ONE row should not thereby freeze
	-- the other twelve at the version shipped the day they edited it. Indexing by name
	-- lets a shipped fix reach every row that user never touched, in whatever order they
	-- arranged them.
	local builtinByName = {}
	for _, rule in ipairs(profileList(profile, kind) or {}) do
		builtinByName[tostring(rule.name)] = rule
	end

	local compiled = {}
	for _, row in ipairs(store(profile.id)[storeKey(kind)] or {}) do
		if row.enabled ~= false then
			local rule = nil
			if not rowIsTouched(row) then rule = builtinByName[tostring(row.name)] end
			if not rule then rule = U.Compile(row, profile) end
			if rule then table.insert(compiled, rule) end
		end
	end
	-- An all-disabled or fully broken custom list would render an empty bar, which reads
	-- as "the addon is broken". Fall back rather than show nothing.
	if #compiled == 0 then return profileList(profile, kind) or {} end
	return compiled
end

-- Reorder, delete and add all change the LIST rather than a row, which no per-row
-- baseline can detect, so each one records the structural edit explicitly.
function U.MoveRow(profileId, kind, index, delta)
	local rows = rowsForEdit(profileId, kind)
	if not rows then return false end
	local target = index + delta
	if target < 1 or target > #rows then return false end
	if not rows[index] then return false end
	rows[index], rows[target] = rows[target], rows[index]
	markStructural(profileId, kind)
	return true
end

function U.DeleteRow(profileId, kind, index)
	local rows = rowsForEdit(profileId, kind)
	if not rows or not rows[index] then return false end
	table.remove(rows, index)
	markStructural(profileId, kind)
	return true
end

function U.AddRow(profileId, kind, spellKey)
	local rows = rowsForEdit(profileId, kind)
	if not rows then return false end
	table.insert(rows, {
		name = nil,
		spellKey = spellKey,
		enabled = true,
		conditions = { { type = "always" } },
	})
	markStructural(profileId, kind)
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
