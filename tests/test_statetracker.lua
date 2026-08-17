-- ============================================================================
-- STATE TRACKER: what "degraded" is allowed to mean
-- ============================================================================
-- `buffs.degraded` drives a visible "~ degraded data" banner and, via
-- inputConfidence, the confidence of every buff-gated prediction step. A live trace had
-- it true on 100% of ticks, which makes it useless in both roles: a warning that is
-- always on conveys nothing, and a confidence input that is always "unknown" is not an
-- input at all.
--
-- The distinction the flag has to hold is the one this codebase keeps losing, in the
-- less obvious direction: NOT "unknown is not no", but "no is not unknown". A query that
-- ran fine and returned nil is a definitive answer -- the player does not have that buff.
-- Only a query that could not run, or a payload we could not read, is degradation.
-- ============================================================================

local harness = require("harness")

local ADRENALINE_RUSH = 13750
local OPPORTUNITY = 195627

describe("statetracker: degraded means unreadable, not absent", function()
  it("is not degraded when the player simply has no buffs up", function()
    local Tuono, stub = harness.boot({
      world = function(s)
        s.state.secret.auras = false
        s.clearAuras()          -- nothing up at all: the common case in combat
      end,
    })
    harness.evaluate(Tuono)
    expect.falsy(Tuono.State.buffs.degraded,
      "an aura query that ran and found nothing is a definitive 'no buff', not a "
        .. "failure to read. Reporting it as degraded pins the flag on for most of "
        .. "every fight and makes the banner meaningless.")
  end)

  it("is not degraded when the player has buffs and they read fine", function()
    local Tuono, stub = harness.boot({
      world = function(s)
        s.state.secret.auras = false
        s.clearAuras()
        s.addAura(ADRENALINE_RUSH, "Adrenaline Rush", 1, 15)
      end,
    })
    harness.evaluate(Tuono)
    expect.falsy(Tuono.State.buffs.degraded, "a clean read must not report degradation")
  end)

  it("IS degraded when the aura query itself cannot run", function()
    local Tuono, stub = harness.boot({
      world = function(s)
        s.state.secret.auras = false
        -- No aura API at all: this is a genuine inability to read, and the one case the
        -- flag exists for.
        _G.C_UnitAuras = nil
      end,
    })
    harness.evaluate(Tuono)
    expect.truthy(Tuono.State.buffs.degraded,
      "losing the aura API entirely is real degradation and must still be reported")
  end)

  it("is not degraded when the combat aura delta payload is secret", function()
    -- This is the case that produced 'degraded on 100% of ticks'. The UNIT_AURA payload
    -- is secret for the whole of combat, so it fires on every aura event of every fight.
    -- We do not depend on that channel any more, so it must not read as degradation.
    local Tuono, stub = harness.boot({ inCombat = true })
    local secretPayload = stub.makeSecret({})
    stub.FireEvent("UNIT_AURA", "player", secretPayload)
    expect.falsy(Tuono.State.buffs.degraded,
      "a replaced channel going dark is not degradation of what we know")
    expect.truthy(Tuono.State.buffs.deltaBlind,
      "it should still be recorded as blind, because that is true and diagnostic")
  end)

  it("does not let absence of buffs suppress the whole lookahead", function()
    local Tuono, stub = harness.boot({
      inCombat = true,
      world = function(s)
        s.state.secret.auras = false
        s.clearAuras()
        s.state.energy = 100
        s.state.comboPoints = 3
      end,
    })
    local result = harness.evaluate(Tuono)
    local ids = harness.queueIDs(result)
    expect.truthy(#ids >= 2,
      "with no buffs up and everything readable, the sequence should be at full depth; "
        .. "got " .. #ids)
    for i, entry in ipairs(result.queue) do
      if entry.isSequence then
        expect.truthy(entry.confidence ~= "unknown",
          "step " .. i .. " rated unknown purely because no buffs were up")
      end
    end
  end)
end)
