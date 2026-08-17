-- ============================================================================
-- DISPLAY: COOLDOWN SWEEP ARMING AND VISIBILITY
-- ============================================================================
-- A Cooldown frame animates from an absolute (start, duration). Calling SetCooldown
-- again restarts that animation from full, so re-arming on a timer rather than on a
-- change is indistinguishable from strobing.
--
-- These tests drive Tuono.Display.Render directly and advance stub.state.time by hand,
-- rather than going through stub.Tick -- a real tick would run RefreshFast and Evaluate
-- and overwrite the cooldown state each test is trying to hold still.
-- ============================================================================

local harness = require("harness")

local ADRENALINE_RUSH = 13750
local SINISTER_STRIKE = 193315

local function advance(stub, dt)
  stub.state.time = stub.state.time + dt
end

-- Mirror what StateTracker does: `remaining` is recomputed from a fixed end instant on
-- every refresh, so it counts down while the cooldown itself stays put. A test that held
-- `remaining` constant across ticks would be modelling a cooldown that never progresses.
local function cooldownEndingAt(Tuono, stub, key, endsAt, known)
  Tuono.State.cooldowns[key] = {
    known = true,
    ready = false,
    remaining = math.max(0, endsAt - stub.state.time),
    remainingKnown = known ~= false,
  }
end

local function render(Tuono, queue)
  Tuono.Display.Render({ queue = queue, advisories = {} })
end

-- A queue with a plain rotation entry first and the cooldown entry second, so the
-- cooldown lands on an icon the GCD does not own.
local function queueWithCooldownAt2(spellID)
  return {
    { spellID = SINISTER_STRIKE, kind = "rotation", confidence = "certain", step = 1, isSequence = true },
    { spellID = spellID, kind = "cooldown", source = "test" },
  }
end

local function icon(Tuono, i)
  return Tuono.Display.anchor.icons[i]
end

describe("display: the cooldown sweep is armed once per cooldown", function()
  it("does not re-arm while the same cooldown is still running", function()
    local Tuono, stub = harness.boot()
    local endsAt = stub.state.time + 45
    local q = queueWithCooldownAt2(ADRENALINE_RUSH)

    for _ = 1, 20 do
      cooldownEndingAt(Tuono, stub, "adrenalineRush", endsAt)
      render(Tuono, q)
      advance(stub, 0.15)
    end

    expect.equal(icon(Tuono, 2).cooldownWidget.setCooldownCalls, 1,
      "the old guard re-fired on `sinceLast > 0.1`, restarting the sweep animation from " ..
      "full ~10x/sec. An absolute end instant is idempotent; a counting-down `remaining` " ..
      "is not.")
  end)

  it("arms with the real remaining time on the first render", function()
    local Tuono, stub = harness.boot()
    local endsAt = stub.state.time + 30
    cooldownEndingAt(Tuono, stub, "adrenalineRush", endsAt)
    render(Tuono, queueWithCooldownAt2(ADRENALINE_RUSH))

    local w = icon(Tuono, 2).cooldownWidget
    expect.equal(w.cdStart, stub.state.time)
    expect.equal(w.cdDuration, 30)
    expect.truthy(w.visible, "an active cooldown must show its sweep")
  end)

  it("re-arms when the cooldown genuinely changes", function()
    local Tuono, stub = harness.boot()
    local q = queueWithCooldownAt2(ADRENALINE_RUSH)

    cooldownEndingAt(Tuono, stub, "adrenalineRush", stub.state.time + 45)
    render(Tuono, q)
    advance(stub, 0.2)
    cooldownEndingAt(Tuono, stub, "adrenalineRush", stub.state.time + 44.8)
    render(Tuono, q)
    expect.equal(icon(Tuono, 2).cooldownWidget.setCooldownCalls, 1,
      "same cooldown, one tick later -- not a change")

    -- A recast pushes the end instant far out. That IS a different cooldown.
    advance(stub, 0.2)
    cooldownEndingAt(Tuono, stub, "adrenalineRush", stub.state.time + 180)
    render(Tuono, q)
    expect.equal(icon(Tuono, 2).cooldownWidget.setCooldownCalls, 2,
      "a recast must re-arm the sweep")
  end)

  it("re-arms when Restless Blades cuts the cooldown short", function()
    local Tuono, stub = harness.boot()
    local q = queueWithCooldownAt2(ADRENALINE_RUSH)

    cooldownEndingAt(Tuono, stub, "adrenalineRush", stub.state.time + 45)
    render(Tuono, q)
    -- A finisher at 6 combo points takes 6s off every running cooldown.
    advance(stub, 0.1)
    cooldownEndingAt(Tuono, stub, "adrenalineRush", stub.state.time + 38.9)
    render(Tuono, q)
    expect.equal(icon(Tuono, 2).cooldownWidget.setCooldownCalls, 2,
      "CDR moves the end instant by seconds; the sweep must follow")
  end)
end)

describe("display: the cooldown widget hides when there is nothing to sweep", function()
  it("does not show a sweep for a ready ability", function()
    local Tuono, stub = harness.boot()
    Tuono.State.cooldowns["adrenalineRush"] =
      { known = true, ready = true, remaining = 0, remainingKnown = true }
    render(Tuono, queueWithCooldownAt2(ADRENALINE_RUSH))

    local w = icon(Tuono, 2).cooldownWidget
    expect.falsy(w.visible,
      "Show() was called unconditionally inside `if icon.cooldownText then`, whose else " ..
      "branch is unreachable because CreateIcon always creates cooldownText")
    expect.falsy(w.setCooldownCalls, "nothing to arm")
  end)

  it("hides the sweep once a running cooldown expires", function()
    local Tuono, stub = harness.boot()
    local q = queueWithCooldownAt2(ADRENALINE_RUSH)

    cooldownEndingAt(Tuono, stub, "adrenalineRush", stub.state.time + 2)
    render(Tuono, q)
    expect.truthy(icon(Tuono, 2).cooldownWidget.visible)

    advance(stub, 3)
    Tuono.State.cooldowns["adrenalineRush"] =
      { known = true, ready = true, remaining = 0, remainingKnown = true }
    render(Tuono, q)
    expect.falsy(icon(Tuono, 2).cooldownWidget.visible,
      "a finished sweep must not linger")
  end)

  it("draws no sweep when the remaining time is not actually known", function()
    local Tuono, stub = harness.boot()
    -- CooldownModel.Reconcile re-arms an unobserved cooldown with a 1s placeholder and
    -- marks it inferred. Sweeping that would restart every tick AND claim a duration we
    -- never measured.
    local q = queueWithCooldownAt2(ADRENALINE_RUSH)
    for _ = 1, 5 do
      Tuono.State.cooldowns["adrenalineRush"] =
        { known = true, ready = false, remaining = 1, remainingKnown = false }
      render(Tuono, q)
      advance(stub, 0.15)
    end

    local w = icon(Tuono, 2).cooldownWidget
    expect.falsy(w.setCooldownCalls, "an inferred remainder is not a measurement")
    expect.falsy(w.visible)
    expect.falsy(icon(Tuono, 2).cooldownText.visible,
      "and no number either")
  end)

  it("still prints the countdown when the remaining time IS known", function()
    local Tuono, stub = harness.boot()
    cooldownEndingAt(Tuono, stub, "adrenalineRush", stub.state.time + 12)
    render(Tuono, queueWithCooldownAt2(ADRENALINE_RUSH))
    local text = icon(Tuono, 2).cooldownText
    expect.truthy(text.visible)
    expect.equal(text.text, "12")
  end)
end)

describe("display: trinket sweeps follow the same rule", function()
  it("arms a trinket sweep once", function()
    local Tuono, stub = harness.boot()
    local endsAt = stub.state.time + 90
    local q = {
      { spellID = SINISTER_STRIKE, kind = "rotation", confidence = "certain", step = 1, isSequence = true },
      { spellID = nil, kind = "trinket", itemSlot = 13, source = "test" },
    }
    for _ = 1, 10 do
      Tuono.State.trinkets[13] = { remaining = math.max(0, endsAt - stub.state.time), ready = false }
      render(Tuono, q)
      advance(stub, 0.15)
    end
    expect.equal(icon(Tuono, 2).cooldownWidget.setCooldownCalls, 1)
  end)
end)

describe("display: the GCD owns position 1's sweep", function()
  local function startGCD(Tuono)
    Tuono.CooldownModel.NoteGCDFromCast(SINISTER_STRIKE)
  end

  it("arms the GCD sweep once, not once per tick", function()
    local Tuono, stub = harness.boot()
    startGCD(Tuono)
    local q = { { spellID = SINISTER_STRIKE, kind = "rotation", confidence = "certain",
                  step = 1, isSequence = true } }

    for _ = 1, 5 do
      render(Tuono, q)
      advance(stub, 0.1)
    end

    local w = icon(Tuono, 1).cooldownWidget
    expect.equal(w.setCooldownCalls, 1)
    expect.truthy(w.visible)
  end)

  it("a cooldown entry at position 1 does not fight the GCD sweep", function()
    local Tuono, stub = harness.boot()
    startGCD(Tuono)
    local gcdStart = Tuono.CooldownModel.GCDStart()
    -- The adversarial case: position 1 is itself a cooldown with time left, so both the
    -- cooldown block and the GCD block want the same widget.
    local q = { { spellID = ADRENALINE_RUSH, kind = "cooldown", source = "test" } }

    for _ = 1, 6 do
      cooldownEndingAt(Tuono, stub, "adrenalineRush", stub.state.time + 40)
      render(Tuono, q)
      advance(stub, 0.1)
    end

    local w = icon(Tuono, 1).cooldownWidget
    expect.equal(w.setCooldownCalls, 1,
      "two writers on one Cooldown frame re-arm over each other every tick")
    expect.equal(w.cdStart, gcdStart,
      "the GCD is the shorter, more urgent signal and must win at position 1")
  end)

  it("clears the sweep when the GCD ends", function()
    local Tuono, stub = harness.boot()
    startGCD(Tuono)
    local q = { { spellID = SINISTER_STRIKE, kind = "rotation", confidence = "certain",
                  step = 1, isSequence = true } }
    render(Tuono, q)
    expect.truthy(icon(Tuono, 1).cooldownWidget.visible)

    advance(stub, 2)
    render(Tuono, q)
    expect.falsy(icon(Tuono, 1).cooldownWidget.visible,
      "a stale GCD sweep must not linger on an icon that has since been replaced")
  end)

  it("does not sweep position 1 when no GCD is running", function()
    local Tuono, stub = harness.boot()
    local q = { { spellID = SINISTER_STRIKE, kind = "rotation", confidence = "certain",
                  step = 1, isSequence = true } }
    render(Tuono, q)
    expect.falsy(icon(Tuono, 1).cooldownWidget.visible)
  end)
end)
