-- ============================================================================
-- AOE / SINGLE-TARGET MODE SELECTION
-- ============================================================================
-- Recorded from a live 69-second trace (2026-08-12): `rotation mode: {'aoe': 127}` --
-- every single tick, with no exception. Tuono ran the AoE priority list for the whole
-- fight. These tests pin why, and pin it shut.
-- ============================================================================

local harness = require("harness")

local BLADE_FLURRY = 13877
local SINISTER_STRIKE = 193315

local function bootWithRotationSpells(spells)
  return harness.boot({
    world = function(stub)
      stub.state.assist.rotationSpells = spells
      stub.state.assist.nextSpell = SINISTER_STRIKE
      stub.state.inCombat = true
    end,
  })
end

describe("mode: Blizzard's capability set is not a target count", function()
  it("does not report AoE just because Blade Flurry is in the spec's rotation", function()
    local Tuono = bootWithRotationSpells({ SINISTER_STRIKE, BLADE_FLURRY })
    Tuono.Assist.Update()
    expect.falsy(Tuono.Assist.aoeDetected,
      "GetRotationSpells is a CAPABILITY SET (AssistReader.lua:165 says so itself). " ..
      "Blade Flurry is always in an Outlaw's rotation, so keying AoE off its presence " ..
      "pins the addon in AoE mode forever.")
  end)

  it("stays in single-target mode against one enemy", function()
    local Tuono = bootWithRotationSpells({ SINISTER_STRIKE, BLADE_FLURRY })
    Tuono.Assist.Update()
    Tuono.Rotation.ResetMode()
    local S = harness.fakeState({ enemyCount = 1 })
    expect.equal(Tuono.Rotation.ResolveMode(S), "single",
      "one enemy must select the single-target list; reason was: "
        .. tostring(Tuono.Rotation.modeReason))
  end)

  it("still enters AoE on a real enemy count", function()
    local Tuono = bootWithRotationSpells({ SINISTER_STRIKE })
    Tuono.Assist.Update()
    Tuono.Rotation.ResetMode()
    local S = harness.fakeState({ enemyCount = 3 })
    expect.equal(Tuono.Rotation.ResolveMode(S), "aoe")
  end)

  it("holds AoE briefly after the count drops (hysteresis, not strobe)", function()
    local Tuono, stub = bootWithRotationSpells({ SINISTER_STRIKE })
    Tuono.Assist.Update()
    Tuono.Rotation.ResetMode()
    expect.equal(Tuono.Rotation.ResolveMode(harness.fakeState({ enemyCount = 3 })), "aoe")
    stub.Tick(0.5)
    expect.equal(Tuono.Rotation.ResolveMode(harness.fakeState({ enemyCount = 1 })), "aoe",
      "must dwell rather than snap back")
    stub.Tick(3.0)
    expect.equal(Tuono.Rotation.ResolveMode(harness.fakeState({ enemyCount = 1 })), "single",
      "must fall back once the dwell expires")
  end)

  it("holds the current mode when the count is unreadable", function()
    local Tuono = bootWithRotationSpells({ SINISTER_STRIKE })
    Tuono.Assist.Update()
    Tuono.Rotation.ResetMode()
    Tuono.Rotation.ResolveMode(harness.fakeState({ enemyCount = 3 }))
    expect.equal(Tuono.Rotation.ResolveMode(harness.fakeState({ enemyCount = nil })), "aoe",
      "'cannot tell' must not be read as 'one enemy'")
  end)

  it("honours an explicit pin in both directions", function()
    local Tuono = bootWithRotationSpells({ SINISTER_STRIKE })
    Tuono.Assist.Update()
    Tuono.db.aoeMode = "on"
    expect.equal(Tuono.Rotation.ResolveMode(harness.fakeState({ enemyCount = 1 })), "aoe")
    Tuono.db.aoeMode = "off"
    expect.equal(Tuono.Rotation.ResolveMode(harness.fakeState({ enemyCount = 9 })), "single")
    Tuono.db.aoeMode = "auto"
  end)
end)
