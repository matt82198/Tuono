local ADDON_NAME, Tuono = ...

-- ============================================================================
-- FLIGHT RECORDER
-- ============================================================================
-- The development loop was: play, notice something wrong, describe it in chat, have it
-- interpreted, guess. That loses almost everything -- "isFullUpdate 271" turned out to
-- be the single most valuable observation of the session and it very nearly went
-- unread.
--
-- SavedVariables are just a Lua file on disk. WoW serialises them on /reload and on
-- logout, so the addon can write a structured trace of what it ACTUALLY SAW and that
-- file can be read directly off disk afterwards. No transcription, no interpretation.
--
-- One /reload closes the whole loop: it applies newly-written addon code AND flushes
-- the previous run's trace.
--
-- WHAT IS WORTH RECORDING is not the addon's conclusions -- those are reproducible from
-- source. It is the OBSERVATIONS: what the client returned, and critically whether each
-- value was secret. That is the one thing that cannot be reconstructed offline, and it
-- is exactly what every bug this session turned on.
--
-- A recorded trace also replays: feed the observation stream back through the harness
-- and a live bug becomes a permanent regression test. Capture once, test forever.
-- ============================================================================

Tuono.Recorder = Tuono.Recorder or {}
local R = Tuono.Recorder

local MAX_SAMPLES = 1500        -- ring buffer; ~1-2 MB of SavedVariables at worst
local SNAPSHOT_INTERVAL = 0.5   -- state snapshots; events are recorded unthrottled

local buf, cursor, wrapped = nil, 1, false
local lastSnapshot = 0
local recording = false

local function db()
	TuonoDiagDB = TuonoDiagDB or {}
	return TuonoDiagDB
end

-- Compact tri-state for "what did the client actually give us": readable value,
-- the string "SECRET", or nil for absent. This distinction is the entire point of the
-- recorder, so it must never be collapsed.
local function obs(v)
	if v == nil then return nil end
	if Tuono.isSecret(v) then return "SECRET" end
	local t = type(v)
	if t == "number" or t == "boolean" or t == "string" then return v end
	return "<" .. t .. ">"
end

local function push(rec)
	if not recording or not buf then return end
	rec.t = math.floor(GetTime() * 100) / 100
	buf[cursor] = rec
	cursor = cursor + 1
	if cursor > MAX_SAMPLES then cursor = 1 wrapped = true end
end
R.Push = push

-- ---------------------------------------------------------------------------
-- One-shot environment probe: every secrecy question, answered machine-readably.
-- This is /tuono secrets, but as data rather than chat text.
-- ---------------------------------------------------------------------------
-- ============================================================================
-- CHANNEL PROBE  --  does laundering a secret through a UI widget work?
-- ============================================================================
-- The recurring idea, and a reasonable one: addons like TellMeWhen and WeakAuras track
-- "everything" with a layer of icons, so build a layer of INVISIBLE ones, hand them the
-- values the client will happily render, and read them back out. If the client can draw
-- your energy on a status bar, the number is evidently in there somewhere.
--
-- It is worth measuring rather than arguing about, because the answer is a property of
-- this build and not of anyone's opinion. Blizzard's stated design is that widgets ACCEPT
-- secrets and their getters RETURN secrets -- the taint rides along rather than being
-- washed off -- and string formatting of secrets was closed in 12.0.1. But "documented as
-- closed" and "closed on the client in front of me" are different claims, and this repo's
-- rule is that the second one is the one that counts.
--
-- Every call is pcall'd and no arithmetic is ever performed on a result: if a setter
-- raises on a secret argument, that is itself the finding, and must not take the addon
-- with it.
--
-- Reading a value back out is NOT the same as reading the hidden state, IF the value comes
-- back secret -- which is the expected result. Nothing here attempts to defeat that; the
-- point is to know, and to re-check when Blizzard changes something.
local probeHost = nil

local function tryReadBack()
	local out = {}

	if not probeHost then
		local ok, f = pcall(CreateFrame, "Frame", nil, UIParent)
		if not ok or not f then return { error = "NO_FRAME" } end
		f:Hide()
		probeHost = f
	end

	-- 1. Cooldown widget. The classic candidate: cooldown remaining is secret in combat,
	--    but the swipe animation obviously knows how far along it is.
	local cdInfo
	local okInfo, info = pcall(C_Spell.GetSpellCooldown, Tuono.SpellIDs and Tuono.SpellIDs.adrenalineRush or 13750)
	if okInfo then cdInfo = info end
	if cdInfo then
		out.sourceStart = obs(cdInfo.startTime)
		out.sourceDuration = obs(cdInfo.duration)
		local okC, cd = pcall(CreateFrame, "Cooldown", nil, probeHost, "CooldownFrameTemplate")
		if okC and cd then
			local okSet = pcall(cd.SetCooldown, cd, cdInfo.startTime, cdInfo.duration)
			out.cooldownSetCooldown = okSet and "ACCEPTED" or "RAISED"
			if okSet then
				if cd.GetCooldownTimes then
					local okG, a, b = pcall(cd.GetCooldownTimes, cd)
					out.cooldownGetTimes = okG and { obs(a), obs(b) } or "RAISED"
				end
				if cd.GetCooldownDuration then
					local okD, d = pcall(cd.GetCooldownDuration, cd)
					out.cooldownGetDuration = okD and obs(d) or "RAISED"
				end
			end
		else
			out.cooldownGetTimes = "NO_WIDGET"
		end
	end

	-- 2. StatusBar. The direct form of the idea: hand it the secret power value.
	local energyType = (Enum and Enum.PowerType and Enum.PowerType.Energy) or 3
	local energy = UnitPower("player", energyType)
	out.sourceEnergy = obs(energy)
	local okB, bar = pcall(CreateFrame, "StatusBar", nil, probeHost)
	if okB and bar then
		local okSet = pcall(bar.SetValue, bar, energy)
		out.statusBarSetValue = okSet and "ACCEPTED" or "RAISED"
		if okSet then
			local okG, v = pcall(bar.GetValue, bar)
			out.statusBarGetValue = okG and obs(v) or "RAISED"
		end
	else
		out.statusBarGetValue = "NO_WIDGET"
	end

	-- 3. FontString. Formatting was closed in 12.0.1; confirm on this build.
	local okF, fs = pcall(probeHost.CreateFontString, probeHost, nil, "OVERLAY", "GameFontNormal")
	if okF and fs then
		local okSet = pcall(fs.SetFormattedText, fs, "%s", energy)
		out.fontStringSetFormatted = okSet and "ACCEPTED" or "RAISED"
		if okSet then
			local okG, t = pcall(fs.GetText, fs)
			out.fontStringGetText = okG and obs(t) or "RAISED"
		end
	end

	return out
end

-- Functions we do NOT currently consume, each of which would matter if readable.
-- GetPowerRegenForPowerType is the interesting one: MaxDps (a live 12.x rotation addon)
-- calls it, and if it is never-secret it hands over the regen rate directly -- the exact
-- quantity EnergyModel currently reconstructs from two threshold crossings.
local function tryUnusedReads()
	local out = {}
	local energyType = (Enum and Enum.PowerType and Enum.PowerType.Energy) or 3

	local candidates = {
		{ "GetPowerRegenForPowerType", function() return _G.GetPowerRegenForPowerType(energyType) end },
		{ "GetPowerRegen",             function() return _G.GetPowerRegen() end },
		{ "UnitPowerDisplayMod",       function() return _G.UnitPowerDisplayMod(energyType) end },
		{ "UnitSpellHaste",            function() return _G.UnitSpellHaste("player") end },
		{ "GetHaste",                  function() return _G.GetHaste() end },
		{ "GetMeleeHaste",             function() return _G.GetMeleeHaste() end },
		{ "UnitAttackSpeed",           function() return _G.UnitAttackSpeed("player") end },
	}
	for _, c in ipairs(candidates) do
		local name, fn = c[1], c[2]
		if type(_G[name]) ~= "function" then
			out[name] = "ABSENT"
		else
			local ok, v = pcall(fn)
			out[name] = ok and obs(v) or "RAISED"
		end
	end
	return out
end

-- Keybinds went missing from the icons. There are four places that can fail and no way to
-- tell them apart from the outside, so record all four per rotation ability:
--   * C_ActionBar.FindSpellActionButtons returning nothing or raising
--   * GetActionInfo returning a SECRET actionID (which makes the == comparison raise)
--   * the slot -> binding-name mapping missing a bar
--   * GetBindingKey itself coming back empty
local function tryKeybinds()
	local out = {}
	local abilities = Tuono.Rotation and Tuono.Rotation.ABILITIES
	if not abilities then return { error = "NO_ABILITIES" } end

	-- Sample the raw action bar first: how many slots are even readable right now?
	local readable, secretID, empty, raised = 0, 0, 0, 0
	for slot = 1, 120 do
		local ok, aType, aID = pcall(GetActionInfo, slot)
		if not ok then raised = raised + 1
		elseif aType == nil then empty = empty + 1
		elseif Tuono.isSecret(aID) or Tuono.isSecret(aType) then secretID = secretID + 1
		else readable = readable + 1 end
	end
	out.slots = { readable = readable, secret = secretID, empty = empty, raised = raised }

	local n = 0
	for spellID in pairs(abilities) do
		if n < 8 then
			n = n + 1
			local row = {}
			if C_ActionBar and C_ActionBar.FindSpellActionButtons then
				local ok, buttons = pcall(C_ActionBar.FindSpellActionButtons, spellID)
				if not ok then row.find = "RAISED"
				elseif type(buttons) ~= "table" then row.find = "NOT_A_TABLE"
				else
					row.find = #buttons
					if buttons[1] ~= nil then row.slot = obs(buttons[1]) end
				end
			else
				row.find = "ABSENT"
			end
			if type(row.slot) == "number" and _G.GetBindingKey then
				-- Mirror Display's mapping for the main 12 only; enough to tell whether the
				-- binding lookup or the mapping is at fault.
				local name = (row.slot >= 1 and row.slot <= 12) and ("ACTIONBUTTON" .. row.slot) or nil
				row.bindingName = name or "UNMAPPED_HERE"
				if name then
					local okB, key = pcall(_G.GetBindingKey, name)
					row.key = okB and (obs(key) or "NONE") or "RAISED"
				end
			end
			out[tostring(spellID)] = row
		end
	end
	return out
end

-- Ask the client what it considers secret, instead of inferring it from behaviour.
local function trySecrecyPredicates()
	local out = {}
	local S = _G.C_Secrets
	if not S then return { error = "NO_C_SECRETS" } end
	local energyType = (Enum and Enum.PowerType and Enum.PowerType.Energy) or 3
	local cpType = (Enum and Enum.PowerType and Enum.PowerType.ComboPoints) or 4

	local queries = {
		{ "GetPowerTypeSecrecy.energy", function() return S.GetPowerTypeSecrecy(energyType) end },
		{ "GetPowerTypeSecrecy.combo",  function() return S.GetPowerTypeSecrecy(cpType) end },
		{ "ShouldUnitPowerBeSecret",    function() return S.ShouldUnitPowerBeSecret("player", energyType) end },
		{ "ShouldUnitStatsBeSecret",    function() return S.ShouldUnitStatsBeSecret("player") end },
		{ "ShouldAurasBeSecret",        function() return S.ShouldAurasBeSecret("player") end },
		{ "ShouldCooldownsBeSecret",    function() return S.ShouldCooldownsBeSecret() end },
		{ "HasSecretRestrictions",      function() return S.HasSecretRestrictions() end },
	}
	for _, q in ipairs(queries) do
		local name, fn = q[1], q[2]
		local ok, v = pcall(fn)
		out[name] = ok and obs(v) or "CALL_FAILED"
	end
	return out
end

function R.Probe()
	local p = { at = date and date("%Y-%m-%d %H:%M:%S") or nil }

	p.build = { GetBuildInfo and select(1, GetBuildInfo()) or nil,
	            GetBuildInfo and select(2, GetBuildInfo()) or nil }
	p.inCombat = Tuono.State and Tuono.State.inCombat or false
	p.hasIsSecret = type(_G.issecretvalue) == "function"

	if _G.GetInstanceInfo then
		local ok, name, instType, _, diff = pcall(_G.GetInstanceInfo)
		if ok then p.instance = { obs(name), obs(instType), obs(diff) } end
	end

	-- Which restriction contexts are live. Explains every other row.
	local api = _G.C_RestrictedActions
	if api and api.IsAddOnRestrictionActive and Enum and Enum.AddOnRestrictionType then
		p.restrictions = {}
		for _, n in ipairs({ "Combat", "Encounter", "ChallengeMode", "PvPMatch", "Map", "Chat" }) do
			local e = Enum.AddOnRestrictionType[n]
			if e ~= nil then
				local ok, active = pcall(api.IsAddOnRestrictionActive, e)
				p.restrictions[n] = ok and obs(active) or "CALL_FAILED"
			end
		end
	end

	local energyType = (Enum and Enum.PowerType and Enum.PowerType.Energy) or 3
	local cpType = (Enum and Enum.PowerType and Enum.PowerType.ComboPoints) or 4
	p.power = {
		energy = obs(UnitPower("player", energyType)),
		energyMax = obs(UnitPowerMax("player", energyType)),
		combo = obs(UnitPower("player", cpType)),
		comboMax = obs(UnitPowerMax("player", cpType)),
	}

	if _G.GetHaste then
		local ok, h = pcall(_G.GetHaste)
		p.haste = ok and obs(h) or "CALL_FAILED"
	end

	-- The load-bearing claim: is IsSpellUsable really never-secret?
	local probeSpell = Tuono.SpellIDs and Tuono.SpellIDs.sinisterStrike
	if probeSpell and C_Spell then
		if C_Spell.IsSpellUsable then
			local ok, u, np = pcall(C_Spell.IsSpellUsable, probeSpell)
			p.isSpellUsable = ok and { obs(u), obs(np) } or "CALL_FAILED"
		end
		if C_Spell.GetSpellPowerCost then
			local ok, costs = pcall(C_Spell.GetSpellPowerCost, probeSpell)
			p.powerCost = (ok and type(costs) == "table" and costs[1]) and obs(costs[1].cost) or "NO_DATA"
		end
		if C_Spell.GetSpellCooldown then
			local ok, cd = pcall(C_Spell.GetSpellCooldown, probeSpell)
			if ok and type(cd) == "table" then
				p.cooldownFields = {
					startTime = obs(cd.startTime), duration = obs(cd.duration),
					isEnabled = obs(cd.isEnabled), isActive = obs(cd.isActive),
					isOnGCD = obs(cd.isOnGCD),
				}
			else
				p.cooldownFields = "CALL_FAILED"
			end
		end
	end

	-- Aura paths: which survive, and does the index path raise?
	if C_UnitAuras then
		if C_UnitAuras.GetPlayerAuraBySpellID and Tuono.SpellIDs then
			local ok, a = pcall(C_UnitAuras.GetPlayerAuraBySpellID, Tuono.SpellIDs.rollTheBones)
			if not ok then p.auraBySpellID = "THREW"
			elseif a == nil then p.auraBySpellID = "NIL"
			else p.auraBySpellID = { spellId = obs(a.spellId), applications = obs(a.applications),
			                         expirationTime = obs(a.expirationTime), name = obs(a.name) } end
		end
		if C_UnitAuras.GetAuraDataByIndex then
			local ok, a = pcall(C_UnitAuras.GetAuraDataByIndex, "player", 1, "HELPFUL")
			p.auraByIndex = ok and (a and "OK" or "NIL") or "THREW"
		end
	end

	if _G.C_AssistedCombat then
		if C_AssistedCombat.IsAvailable then
			local ok, av = pcall(C_AssistedCombat.IsAvailable)
			p.assistAvailable = ok and obs(av) or "CALL_FAILED"
		end
		if C_AssistedCombat.GetNextCastSpell then
			local ok, id = pcall(C_AssistedCombat.GetNextCastSpell, false)
			p.assistPick = ok and obs(id) or "CALL_FAILED"
		end
	end

	-- Enumerate C_Secrets so we learn what runtime predicates actually exist.
	if _G.C_Secrets then
		p.cSecrets = {}
		for k, v in pairs(_G.C_Secrets) do
			if type(v) == "function" then table.insert(p.cSecrets, k) end
		end
		table.sort(p.cSecrets)
	end

	-- Three measurements, not three opinions. See the block comments above each.
	local okR, readBack = pcall(tryReadBack)
	p.readBack = okR and readBack or "PROBE_RAISED"
	local okU, unused = pcall(tryUnusedReads)
	p.unusedReads = okU and unused or "PROBE_RAISED"
	local okS, secrecy = pcall(trySecrecyPredicates)
	p.secrecyPredicates = okS and secrecy or "PROBE_RAISED"
	local okK, keys = pcall(tryKeybinds)
	p.keybinds = okK and keys or "PROBE_RAISED"

	return p
end

-- ---------------------------------------------------------------------------
-- THE UNKNOWN-AURA CAPTURE. Every buff on the player, by index, out of combat.
-- This is what resolves the Roll the Bones stage IDs without anyone transcribing
-- anything: roll, /reload, and the buff list is on disk.
-- ---------------------------------------------------------------------------
function R.CaptureAuras()
	local out = {}
	if not (C_UnitAuras and C_UnitAuras.GetAuraDataByIndex) then return out end
	for i = 1, 40 do
		local ok, a = pcall(C_UnitAuras.GetAuraDataByIndex, "player", i, "HELPFUL")
		if not ok then table.insert(out, { i = i, error = "THREW" }) break end
		if not a then break end
		table.insert(out, {
			i = i, spellId = obs(a.spellId), name = obs(a.name),
			applications = obs(a.applications), duration = obs(a.duration),
			expirationTime = obs(a.expirationTime),
		})
	end
	return out
end

-- ---------------------------------------------------------------------------
-- Per-tick snapshot: what we believe, and how well.
-- ---------------------------------------------------------------------------
function R.Snapshot()
	if not recording then return end
	local now = GetTime()
	if (now - lastSnapshot) < SNAPSHOT_INTERVAL then return end
	lastSnapshot = now

	local S = Tuono.State
	local lo, hi = nil, nil
	if Tuono.Energy and Tuono.Energy.Interval then lo, hi = Tuono.Energy.Interval() end

	-- HOW MANY ICONS THE PLAYER ACTUALLY SAW.
	--
	-- Every trace so far has recorded only position 1, so three separate reports of the
	-- bar behaving badly -- "it switches the entire list a lot", "it just goes empty",
	-- "single combat shows one button" -- were all unanswerable from the data, and each
	-- one had to be chased by reproducing it offline and guessing at the live cause. The
	-- depth of the published sequence is the single most useful number the recorder was
	-- not capturing.
	--
	-- Read off the plan rather than the queue: Engine.Evaluate returns resultQueue itself
	-- and wipes it in place on the next tick, so holding a reference here would observe a
	-- table that mutates underneath us.
	local E = Tuono.Engine
	local planLen, cursor, visible = nil, nil, nil
	if E and E.plan and E.cursor then
		planLen = #E.plan
		cursor = E.cursor
		visible = math.max(0, planLen - cursor + 1)
	end

	-- ERRORS ARE SWALLOWED BY DESIGN, SO THEY MUST BE COUNTED.
	--
	-- Every stage of the tick runs inside Tuono.safe, which prints an error ONCE and then
	-- suppresses it. That is right for stability -- one bad call must not take the frame
	-- down -- but it means a rule throwing on every tick is invisible after the first
	-- chat line, and a thrown Predict returns nil, which reaches the player as an empty
	-- bar with no explanation. A live trace showed the sequence empty on 51 of 198 ticks
	-- and there was no way to tell a throw from a genuine "nothing matched".
	local errCount = Tuono.errorCount or 0
	local firstErr = nil
	if errCount > 0 then
		for msg in pairs(Tuono.errorsSeen or {}) do firstErr = msg break end
	end

	push({
		k = "tick",
		-- Sequence depth as rendered, plus why it might be short.
		vis = visible, planLen = planLen, cur = cursor,
		-- Icons actually on screen after run-collapsing, which is NOT the engine depth: a
		-- sequence of 8 can render as 1 icon. Three live reports turned on that gap.
		shown = Tuono.Display and Tuono.Display.shownCount or nil,
		err = (errCount > 0) and errCount or nil,
		errMsg = firstErr,
		-- Rules that THREW during the priority walk. These are pcall'd per rule and
		-- skipped, which is right -- one bad rule must not take the rotation down -- but
		-- skipping was invisible, so a rule throwing every tick looked exactly like one
		-- that never matches.
		ruleErr = (Tuono.Rotation and Tuono.Rotation.ruleErrors) or nil,
		ruleErrName = Tuono.Rotation and Tuono.Rotation.lastRuleError or nil,
		fb = E and E.usedFallback or nil,
		replan = E and E.lastReplanReason or nil,
		cp = S.comboPoints, cpK = S.comboPointsKnown,
		eLo = lo, eHi = hi, eSrc = S.energySource,
		rtb = S.buffs.rtb.stage, rtbK = S.buffs.rtb.stageKnown,
		deg = S.buffs.degraded,
		enemies = S.enemyCount,
		assist = Tuono.Assist and Tuono.Assist.nextSpellID,
		wait = Tuono.Assist and Tuono.Assist.waitingForResource,
		mode = Tuono.Rotation and Tuono.Rotation.mode,
		regen = Tuono.Energy and Tuono.Energy.measuredRegen,
		stall = Tuono.Engine and Tuono.Engine.stallCount,
		gcd = Tuono.CooldownModel and Tuono.CooldownModel.GCDRemaining
			and math.floor(Tuono.CooldownModel.GCDRemaining() * 100) / 100,
		rec1 = Tuono.Engine and Tuono.Engine.lastPos1,
	})
end

function R.Start()
	buf, cursor, wrapped = {}, 1, false
	recording = true
	lastSnapshot = 0
	local d = db()
	d.probeAtStart = R.Probe()
	d.aurasAtStart = R.CaptureAuras()
	d.startedAt = date and date("%Y-%m-%d %H:%M:%S") or nil
	Tuono.print("Recording. Play normally, then |cffffcc00/reload|r to flush the trace to disk.")
end

function R.Stop()
	recording = false
	local d = db()
	d.samples = buf or {}
	d.wrapped = wrapped
	d.cursor = cursor
	d.probeAtStop = R.Probe()
	d.aurasAtStop = R.CaptureAuras()
	local n = 0
	for _ in pairs(d.samples) do n = n + 1 end
	Tuono.print("Recorded " .. n .. " samples. /reload to write them to SavedVariables.")
end

function R.IsRecording() return recording end

-- Flush on logout AND on reload, so a trace is never lost to forgetting to stop.
Tuono.RegisterEvent("PLAYER_LOGOUT", function()
	if recording then R.Stop() end
end)

-- Discrete events. These are the high-value rows: they capture what the client said at
-- the moment it said it, including secrecy, which no amount of offline reasoning can
-- recover.
Tuono.RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player", function(event, unit, castGUID, spellID)
	push({ k = "cast", id = obs(spellID) })
end)

Tuono.RegisterUnitEvent("UNIT_SPELLCAST_FAILED", "player", function(event, unit, castGUID, spellID)
	push({ k = "castfail", id = obs(spellID) })
end)

Tuono.RegisterEvent("UI_ERROR_MESSAGE", function(event, errorType, message)
	-- Record the STABLE error name alongside the localized message: errorType indices
	-- shift between patches and messages differ per locale, so neither alone is a
	-- durable key for analysis.
	push({
		k = "uierr", errorType = obs(errorType), msg = obs(message),
		name = Tuono.Observers and Tuono.Observers.ErrorName and Tuono.Observers.ErrorName(errorType),
		-- What we were recommending when it failed. This is the pairing that turns a
		-- pile of errors into an actionable defect: 31 "not ready" against a Sinister
		-- Strike recommendation is the GCD bug, stated outright.
		rec = Tuono.Engine and Tuono.Engine.lastPos1,
		gcd = Tuono.CooldownModel and Tuono.CooldownModel.GCDRemaining
			and math.floor(Tuono.CooldownModel.GCDRemaining() * 100) / 100,
	})
end)

-- The one that found the last bug. Record the SHAPE of the payload, not its contents:
-- whether each field was present, and whether it was secret.
Tuono.RegisterUnitEvent("UNIT_AURA", "player", function(event, unit, updateInfo)
	if updateInfo == nil then push({ k = "aura", info = "nil" }) return end
	if Tuono.isSecret(updateInfo) then push({ k = "aura", info = "SECRET_TABLE" }) return end
	local okF, full = pcall(function() return updateInfo.isFullUpdate end)
	local rec = { k = "aura", full = okF and obs(full) or "INDEX_THREW" }
	for _, f in ipairs({ "addedAuras", "removedAuraInstanceIDs", "updatedAuraInstanceIDs" }) do
		local ok, v = pcall(function() return updateInfo[f] end)
		if not ok then rec[f] = "INDEX_THREW"
		elseif v == nil then rec[f] = nil
		elseif Tuono.isSecret(v) then rec[f] = "SECRET"
		else
			local okLen, n = pcall(function() return #v end)
			rec[f] = okLen and n or "LEN_THREW"
		end
	end
	push(rec)
end)

Tuono.RegisterEvent("PLAYER_REGEN_DISABLED", function()
	push({ k = "combat", v = true })
	-- Auto-start on first combat so a trace exists even if the user forgets.
	if not recording and TuonoDiagDB and TuonoDiagDB.autoRecord then R.Start() end

	-- RE-PROBE THE CHANNELS IN COMBAT. This is the only question that matters about them.
	--
	-- The start/stop probes both run out of combat, where GetHaste, UnitSpellHaste,
	-- UnitAttackSpeed and GetPowerRegenForPowerType all return plain numbers -- which
	-- proves nothing, because the whole family carries SecretWhenUnitStatsRestricted and
	-- the restriction is exactly what combat turns on. A value that is readable at the
	-- target dummy and secret in the pull is worse than one that is always secret, because
	-- it invites a model built on a reading that evaporates when it is needed.
	--
	-- Same for the widget read-back: an out-of-combat cooldown is 0/0 and genuinely not
	-- secret, so feeding it to a Cooldown frame tests nothing at all.
	if recording then
		local ok, unused = pcall(tryUnusedReads)
		local okR, readBack = pcall(tryReadBack)
		local okS, secrecy = pcall(trySecrecyPredicates)
		push({
			k = "probe", where = "combat-start",
			unusedReads = ok and unused or "PROBE_RAISED",
			readBack = okR and readBack or "PROBE_RAISED",
			secrecyPredicates = okS and secrecy or "PROBE_RAISED",
			keybinds = select(2, pcall(tryKeybinds)),
		})
	end
end)
Tuono.RegisterEvent("PLAYER_REGEN_ENABLED", function() push({ k = "combat", v = false }) end)

Tuono.RegisterSlash("record", function(arg)
	arg = (arg or ""):lower()
	if arg == "stop" then R.Stop()
	elseif arg == "auto" then
		db().autoRecord = not db().autoRecord
		Tuono.print("Auto-record on combat: " .. tostring(db().autoRecord))
	elseif arg == "auras" then
		db().aurasManual = R.CaptureAuras()
		Tuono.print("Captured " .. #db().aurasManual .. " buffs. /reload to write to disk.")
	elseif arg == "status" then
		Tuono.print("recording=" .. tostring(recording) ..
			" samples=" .. tostring(cursor - 1) .. " wrapped=" .. tostring(wrapped))
	else R.Start() end
end, "Flight recorder: record | stop | auras | auto | status")
