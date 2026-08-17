local ADDON_NAME, Tuono = ...

-- ============================================================================
-- FIRST-LOAD MIGRATION FROM OutlawAssist
-- ============================================================================
-- Tuono was OutlawAssist until the rebrand. WoW keys saved variables to the ADDON
-- FOLDER name, so the rename makes every existing user look like a fresh install: bar
-- position, scale, icon count, glow settings and any edited priority rows all appear
-- to vanish. This copies them across, once.
--
-- HOW THE OLD DATA IS REACHABLE
-- Saved variables live in WTF/.../SavedVariables/<AddonName>.lua and are loaded into
-- the global environment by the addon that DECLARES them. So `OutlawAssistDB` exists
-- here only while the old OutlawAssist folder is still installed and enabled. That is
-- the normal state immediately after upgrading, which is exactly when this runs.
--
-- We deliberately do NOT declare OutlawAssistDB in Tuono.toc. Declaring another
-- addon's saved variable makes WoW look for it in OUR saved-variables file (where it
-- does not exist) and write it back there on logout -- two addons owning one global,
-- which is how you corrupt the source you were trying to read.
--
-- TIMING
-- ADDON_LOADED is too early: addon load order is not guaranteed, so OutlawAssist may
-- not have populated its globals yet. PLAYER_LOGIN fires after every addon has loaded,
-- so it is the first safe point.
--
-- IDEMPOTENCE AND SAFETY
-- Runs only when Tuono's own DB was EMPTY before defaults were merged (Core.lua
-- captures Tuono.dbWasFresh for exactly this). A user who has already configured
-- Tuono never has their settings overwritten by a stale OutlawAssist profile, even if
-- the old folder is still lying around.
-- ============================================================================

Tuono.Migration = Tuono.Migration or {}
local M = Tuono.Migration

local LEGACY_GLOBAL = "OutlawAssistDB"
local LEGACY_NAME = "OutlawAssist"

-- Keys worth carrying over. An explicit allowlist rather than a blind deep copy: the
-- old schema contained keys that no longer exist, and silently importing them would
-- resurrect dead settings that nothing reads and nothing can clear.
local MIGRATE_KEYS = {
	"show",
	"display",
	"highlight",
	"aoeMode",
	"aoeThreshold",
	"updateInterval",
	"activeProfile",
	"profiles",
	"showedWelcome",
}

local function deepCopy(v)
	if type(v) ~= "table" then return v end
	local out = {}
	for k, val in pairs(v) do out[k] = deepCopy(val) end
	return out
end

-- Merge source INTO target without clobbering keys the target already defines.
-- Defaults have already populated the target, so this fills in the user's old values
-- for keys that exist in both, and leaves new-in-Tuono keys at their defaults.
local function overlay(target, source)
	if type(source) ~= "table" then return end
	for k, v in pairs(source) do
		if type(v) == "table" and type(target[k]) == "table" then
			overlay(target[k], v)
		else
			target[k] = deepCopy(v)
		end
	end
end

-- aoeMode changed shape in the rebrand: it was a boolean (AoE on/off) and is now a
-- tri-state string ("auto" | "on" | "off") because a boolean cannot express "decide
-- from the live enemy count", which is the new default. An imported boolean would be
-- carried by the engine's compatibility branch, but normalising here means the config
-- UI shows the right label and the stored value matches its documented type.
local function normalise(db)
	if db.aoeMode == true then
		db.aoeMode = "on"
	elseif db.aoeMode == false then
		-- false meant "not currently in AoE mode", not "never use AoE". Auto is the
		-- honest translation now that detection is real rather than manual.
		db.aoeMode = "auto"
	elseif type(db.aoeMode) ~= "string" then
		db.aoeMode = "auto"
	end

	if type(db.aoeThreshold) ~= "number" or db.aoeThreshold < 1 then
		db.aoeThreshold = 2
	end
end

-- Returns a SINGLE value: the list of carried keys on success, nil otherwise.
-- Deliberately not (ok, detail) -- Tuono.safe is `local ok, r = pcall(...); return r`,
-- so it collapses multiple returns to the first one and the detail would vanish.
function M.Run()
	local db = Tuono.db
	if not db then return nil end

	-- Already migrated, or the user has configured Tuono themselves.
	if db.migratedFrom then return nil end
	if Tuono.dbWasFresh == false then return nil end

	local legacy = _G[LEGACY_GLOBAL]
	if type(legacy) ~= "table" or next(legacy) == nil then
		return nil
	end

	local carried = {}
	for _, key in ipairs(MIGRATE_KEYS) do
		local value = legacy[key]
		if value ~= nil then
			if type(value) == "table" and type(db[key]) == "table" then
				overlay(db[key], value)
			else
				db[key] = deepCopy(value)
			end
			table.insert(carried, key)
		end
	end

	if #carried == 0 then return nil end

	normalise(db)

	db.migratedFrom = LEGACY_NAME
	-- Wall-clock is unavailable here in any portable form; the session timestamp is
	-- enough to distinguish "migrated this session" for support purposes.
	db.migratedAt = GetTime()

	return carried
end

Tuono.RegisterEvent("PLAYER_LOGIN", function()
	local carried = Tuono.safe(M.Run)
	if type(carried) == "table" and #carried > 0 then
		Tuono.print("Imported your " .. LEGACY_NAME .. " settings (" ..
			table.concat(carried, ", ") .. ").")
		Tuono.print("|cffffcc00Both addons are loaded right now, so you are seeing TWO " ..
			"bars.|r Disable or delete Interface/AddOns/" .. LEGACY_NAME ..
			" and /reload -- the import is done and will not run again.")
	elseif Tuono.dbWasFresh and type(_G[LEGACY_GLOBAL]) == "table" then
		-- Old addon is loaded and has data, but nothing was carried. Either it was
		-- already migrated or the keys did not match. Say so rather than staying silent,
		-- because the user is looking at two bars and deserves to know why.
		Tuono.print("Found " .. LEGACY_NAME .. " but imported nothing (already migrated, " ..
			"or no recognised settings). Safe to remove the old folder.")
	end
	-- WARN WHENEVER THE OLD ADDON IS STILL LOADED, not only during the import.
	--
	-- Both branches above are gated on migration state, so once Tuono has settings of its
	-- own the warning goes silent -- while OutlawAssist keeps running. It is not passive:
	-- it draws its own bar, installs its own action-button glows, and it still contains
	-- every secret-value bug fixed here since the rename. A live report of a strobing icon,
	-- a second icon "underneath the first", and
	--
	--     attempt to perform boolean test on field isFullUpdate ... is a secret value
	--
	-- turned out to be OutlawAssist/StateTracker.lua:249 -- the pre-fix copy of a bug this
	-- addon fixed months of commits ago -- with two rotation addons fighting over the same
	-- action buttons. None of it was Tuono, and nothing in Tuono said so.
	local stillLoaded = false
	if C_AddOns and C_AddOns.IsAddOnLoaded then
		local ok, loaded = pcall(C_AddOns.IsAddOnLoaded, LEGACY_NAME)
		stillLoaded = ok and loaded and true or false
	elseif _G.IsAddOnLoaded then
		local ok, loaded = pcall(_G.IsAddOnLoaded, LEGACY_NAME)
		stillLoaded = ok and loaded and true or false
	end
	if not stillLoaded and type(_G[LEGACY_GLOBAL]) == "table" then
		-- The global only exists if the old addon declared it, so its presence is itself
		-- evidence, even when the IsAddOnLoaded API is unavailable.
		stillLoaded = true
	end

	if stillLoaded then
		Tuono.print("|cffff4444" .. LEGACY_NAME .. " is still enabled.|r You are running two " ..
			"rotation addons at once: two bars, two sets of action-button glows, and the old " ..
			"one still has secret-value bugs that Tuono has since fixed (it throws on " ..
			"UNIT_AURA).")
		Tuono.print("Disable it in the AddOns list, or delete Interface/AddOns/" ..
			LEGACY_NAME .. ", then /reload. Your settings are already here.")
	end
	-- Silent otherwise. A fresh install with no old addon present is the normal
	-- first-run path; a "could not migrate" warning there would be pure noise.
end)
