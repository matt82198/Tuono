-- ============================================================================
-- FLIGHT RECORDER
-- ============================================================================
-- A recording attempt on 2026-08-17 produced nothing: the SavedVariables file was
-- rewritten but `startedAt` still read "2026-08-12", so R.Start() never ran and the
-- previous trace was simply re-serialized. The failure was SILENT -- the player believed
-- they had a trace and did not.
--
-- The recorder is the only instrument this project has for observing live behaviour, so
-- a recorder that quietly does not record is worse than not having one. These pin the
-- whole path: the slash command exists, starting sets the marker that proves it started,
-- samples accumulate, and a reload flushes them.
-- ============================================================================

local harness = require("harness")

local function slash(Tuono, sub, args)
  local entry = Tuono.slashCommands and Tuono.slashCommands[sub]
  if not entry then return nil end
  entry.fn(args or "")
  return true
end

describe("recorder", function()
  it("registers the /tuono record command", function()
    local Tuono = harness.boot()
    expect.truthy(Tuono.slashCommands, "no slash commands registered at all")
    expect.truthy(Tuono.slashCommands["record"],
      "/tuono record is missing, so a player typing it gets 'Unknown command'")
  end)

  it("starting a recording stamps the marker that proves it started", function()
    local Tuono, stub = harness.boot()
    expect.truthy(slash(Tuono, "record"), "/tuono record did not dispatch")
    expect.truthy(Tuono.Recorder.IsRecording(), "Start() did not set the recording flag")
    -- startedAt is exactly the field whose staleness revealed the silent failure.
    expect.truthy(_G.TuonoDiagDB and _G.TuonoDiagDB.startedAt,
      "no startedAt written; a trace from this session would be indistinguishable "
        .. "from a stale one left over from a previous session")
  end)

  it("tells the player it is recording", function()
    local Tuono, stub = harness.boot()
    slash(Tuono, "record")
    local said = table.concat(stub.printed, "\n")
    expect.truthy(said:find("Recording", 1, true),
      "silence is why the last attempt was believed to have worked; got: " .. said)
  end)

  it("accumulates samples while recording and none before", function()
    local Tuono, stub = harness.boot({ inCombat = true })
    -- Nothing should be captured before Start.
    stub.FireEvent("UNIT_SPELLCAST_SUCCEEDED", "player", "c0", 193315)
    slash(Tuono, "record")
    for i = 1, 5 do
      stub.state.time = stub.state.time + 0.6
      stub.FireEvent("UNIT_SPELLCAST_SUCCEEDED", "player", "c" .. i, 193315)
      Tuono.Recorder.Snapshot()
    end
    slash(Tuono, "record", "stop")
    local n = 0
    for _ in pairs(_G.TuonoDiagDB.samples or {}) do n = n + 1 end
    expect.truthy(n >= 5, "expected casts and ticks to be recorded; got " .. n)
  end)

  it("flushes on logout, so a /reload cannot lose the trace", function()
    local Tuono, stub = harness.boot({ inCombat = true })
    slash(Tuono, "record")
    stub.state.time = stub.state.time + 0.6
    Tuono.Recorder.Snapshot()
    -- The player is told to /reload, which fires PLAYER_LOGOUT.
    stub.FireEvent("PLAYER_LOGOUT")
    expect.falsy(Tuono.Recorder.IsRecording(), "logout did not stop the recording")
    expect.truthy(_G.TuonoDiagDB.samples, "samples were never written to SavedVariables")
  end)

  it("auto-record arms on entering combat once enabled", function()
    local Tuono, stub = harness.boot()
    slash(Tuono, "record", "auto")
    expect.truthy(_G.TuonoDiagDB.autoRecord, "/tuono record auto did not set the flag")
    harness.enterCombat(stub)
    expect.truthy(Tuono.Recorder.IsRecording(),
      "auto-record is the safety net for forgetting to type the command; it must arm "
        .. "on PLAYER_REGEN_DISABLED")
  end)
end)
