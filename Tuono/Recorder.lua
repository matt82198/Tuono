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

	push({
		k = "tick",
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
	push({ k = "uierr", errorType = obs(errorType), msg = obs(message) })
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
