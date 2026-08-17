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

describe("display: runs collapse so the shape fits on the bar", function()
  local function render(Tuono, ids)
    local queue = {}
    for i, id in ipairs(ids) do
      queue[i] = { spellID = id, kind = "rotation", confidence = "certain",
                   step = i, isSequence = true }
    end
    Tuono.Display.Render({ queue = queue, advisories = {} })
    return Tuono.Display.anchor.icons
  end

  it("shows a repeated builder once, with a count", function()
    -- Reported as "the whole bar is sinister strike". The engine simulates 8 steps but
    -- the bar shows 4, and an Outlaw at a 5-point cap needs up to 5 builders before a
    -- finisher -- so the finisher fell off the end and the interesting part of the
    -- sequence was never visible.
    local Tuono = harness.boot({ inCombat = true })
    local SS, BTE = 193315, 315341
    local icons = render(Tuono, { SS, SS, SS, SS, BTE, SS, SS, SS })
    expect.truthy(icons[1].countText.visible, "no multiplier shown on a run of four")
    expect.equal(icons[1].countText.text, "x4")
    expect.truthy(icons[2].visible, "the finisher should now be on the bar")
  end)

  it("does not label a single step with a multiplier", function()
    local Tuono = harness.boot({ inCombat = true })
    local icons = render(Tuono, { 193315, 315341, 2098, 13750 })
    expect.falsy(icons[1].countText.visible, "'x1' is noise")
  end)

  it("never merges two different abilities", function()
    local Tuono = harness.boot({ inCombat = true })
    local icons = render(Tuono, { 193315, 315341, 193315, 2098 })
    expect.falsy(icons[1].countText.visible,
      "a run must be consecutive AND identical")
  end)
end)

-- ============================================================================
-- CERTAINTY, TIMING AND SCALE
-- ============================================================================
-- Three defects proven in docs/UI.md and docs/ACCESSIBILITY.md:
--
--   * alpha carried three unrelated meanings (epistemic / timing / social) on one
--     channel that can only say "less", and two of them collided outright;
--   * a recommendation whose time is in the FUTURE rendered identically to one you
--     should press right now, so the forward model's best output was invisible;
--   * one scale control scaled icons and text together, so a low-vision player could
--     only enlarge the keybind by enlarging the icons.
-- ============================================================================

local function seqQueue(entries)
  local q = {}
  for i, e in ipairs(entries) do
    q[i] = {
      spellID = e.spellID or SINISTER_STRIKE,
      kind = e.kind or "rotation",
      confidence = e.confidence,
      at = e.at,
      step = i,
      isSequence = true,
    }
  end
  return q
end

describe("display: certainty is on the ring, not on alpha", function()
  it("draws a solid ring when the step is certain", function()
    local Tuono = harness.boot({ inCombat = true })
    render(Tuono, seqQueue({ { confidence = "certain" } }))
    expect.equal(Tuono.Display.anchor.icons[1].ringPattern, "solid")
  end)

  it("draws an incomplete ring when the step is only bounded", function()
    local Tuono = harness.boot({ inCombat = true })
    render(Tuono, seqQueue({ { confidence = "bounded" } }))
    expect.equal(Tuono.Display.anchor.icons[1].ringPattern, "dashed",
      "the dash IS the suppressed resolution -- an outline that is literally incomplete")
  end)

  it("adds a hazard wash on top of the dashed ring when unknown", function()
    local Tuono = harness.boot({ inCombat = true })
    render(Tuono, seqQueue({ { confidence = "unknown" } }))
    local icon = Tuono.Display.anchor.icons[1]
    expect.equal(icon.ringPattern, "dashed")
    expect.truthy(icon.hazard.visible,
      "unknown needs two independent cues, not just a dimmer icon")
  end)

  it("rates pooling as MORE confident than unknown, not less", function()
    -- The inversion. Pooling is a high-confidence claim -- "I am certain you cannot press
    -- this yet" -- and it used to render at 0.35 against unknown's 0.40, drawing the more
    -- certain state as the less certain one.
    local Tuono = harness.boot({ inCombat = true })
    render(Tuono, seqQueue({ { confidence = "pooling" } }))
    local pooling = Tuono.Display.anchor.icons[1]:GetAlpha()
    render(Tuono, seqQueue({ { confidence = "unknown" } }))
    local unknown = Tuono.Display.anchor.icons[1]:GetAlpha()
    expect.truthy(pooling > unknown,
      "pooling " .. pooling .. " must be more opaque than unknown " .. unknown)
  end)

  it("keeps the ring solid while pooling, because we are sure", function()
    local Tuono = harness.boot({ inCombat = true })
    render(Tuono, seqQueue({ { confidence = "pooling" } }))
    expect.equal(Tuono.Display.anchor.icons[1].ringPattern, "solid")
  end)
end)

describe("display: stalling recedes instead of dimming", function()
  local function stall(Tuono)
    Tuono.Engine.stallCount = 5   -- STALL_THRESHOLD is 3
  end

  it("drops the ring when the player keeps ignoring us", function()
    local Tuono = harness.boot({ inCombat = true })
    stall(Tuono)
    render(Tuono, seqQueue({ { confidence = "certain" } }))
    local icon = Tuono.Display.anchor.icons[1]
    expect.equal(icon.ringPattern, "none",
      "physical retreat reads as deference; transparency reads as unimportance")
    expect.truthy(icon.stalled)
  end)

  it("is distinguishable from a merely uncertain recommendation", function()
    -- The defect: `math.min(baseAlpha, 0.45)` against an unknown alpha of 0.40 meant
    -- min(0.40, 0.45) = 0.40, so stalled-and-uncertain looked exactly like uncertain.
    local Tuono = harness.boot({ inCombat = true })
    render(Tuono, seqQueue({ { confidence = "unknown" } }))
    local plainPattern = Tuono.Display.anchor.icons[1].ringPattern
    local plainStalled = Tuono.Display.anchor.icons[1].stalled

    stall(Tuono)
    render(Tuono, seqQueue({ { confidence = "unknown" } }))
    local icon = Tuono.Display.anchor.icons[1]
    expect.truthy(icon.ringPattern ~= plainPattern or icon.stalled ~= plainStalled,
      "a stalled recommendation on uncertain data must not be pixel-identical to a "
        .. "merely uncertain one")
  end)
end)

describe("display: a step in the future says when", function()
  it("shows the wait in seconds", function()
    local Tuono = harness.boot({ inCombat = true })
    render(Tuono, seqQueue({ { confidence = "pooling", at = 1.4 } }))
    local d = Tuono.Display.anchor.icons[1].delayText
    expect.truthy(d.visible, "'wait 1.4s then press this' rendered identically to 'press this now'")
    expect.equal(d.text, "1.4")
  end)

  it("says nothing when the step carries no time", function()
    -- Rotation.Predict may not supply `at`. Inventing a number would be worse than
    -- silence, so the display degrades to its ordinal behaviour.
    local Tuono = harness.boot({ inCombat = true })
    render(Tuono, seqQueue({ { confidence = "certain" } }))
    expect.falsy(Tuono.Display.anchor.icons[1].delayText.visible)
  end)

  it("does not report a delay for a step that is castable now", function()
    local Tuono = harness.boot({ inCombat = true })
    render(Tuono, seqQueue({ { confidence = "certain", at = 0 } }))
    expect.falsy(Tuono.Display.anchor.icons[1].delayText.visible)
  end)

  it("does not count the GCD as a wait worth reporting", function()
    -- Hekili UI.lua:1524 subtracts the earliest possible time before showing a delay.
    -- Waiting out the GCD is not news -- the sweep already shows it. Waiting BEYOND it,
    -- to pool energy, is the thing our simulation knows and Blizzard's highlighter does
    -- not.
    local Tuono, stub = harness.boot({ inCombat = true })
    harness.cast(Tuono, stub, SINISTER_STRIKE)   -- starts a GCD of ~0.85s
    render(Tuono, seqQueue({ { confidence = "certain", at = 0.3 } }))
    expect.falsy(Tuono.Display.anchor.icons[1].delayText.visible,
      "0.3s is inside the running GCD, so it is not a wait the player can act on")
  end)
end)

describe("display: text scales independently of icons", function()
  it("defaults to the base size", function()
    local Tuono = harness.boot({ inCombat = true })
    Tuono.db.display.fontScale = nil
    expect.equal(Tuono.Display.FontSize(11), 11)
  end)

  it("enlarges text without touching display.scale", function()
    local Tuono = harness.boot({ inCombat = true })
    local before = Tuono.db.display.scale
    Tuono.db.display.fontScale = 2
    expect.equal(Tuono.Display.FontSize(11), 22)
    expect.equal(Tuono.db.display.scale, before,
      "font scale must not move icon scale; the coupling is the defect")
  end)

  it("never renders text too small to read", function()
    local Tuono = harness.boot({ inCombat = true })
    Tuono.db.display.fontScale = 0.1
    expect.truthy(Tuono.Display.FontSize(11) >= 8,
      "a floor, or the accessibility control becomes an accessibility hazard")
  end)

  it("ignores a nonsense multiplier rather than vanishing", function()
    local Tuono = harness.boot({ inCombat = true })
    Tuono.db.display.fontScale = -3
    expect.equal(Tuono.Display.FontSize(11), 11)
  end)
end)

describe("display: an unidentifiable entry never reaches the bar", function()
  -- Reported live as "some dude's face with a blue icon". Entries whose art would not
  -- resolve rendered a hardcoded FileDataID (134400 -- the old question-mark ID). Blizzard
  -- no longer names new icons, so that number is not a stable reference to the art it was
  -- chosen for; it draws whatever now occupies the ID.
  --
  -- The distinction that matters is IDENTITY, not art. An entry with a spellID is
  -- identifiable by its keybind and position even if the texture failed to load, and
  -- dropping it would delete a real recommendation. An entry with neither a spellID nor
  -- item art cannot be identified by any channel we have.
  local function renderQueue(Tuono, queue)
    Tuono.Display.Init()
    Tuono.Display.Render({ queue = queue, advisories = {} })
    return Tuono.Display.anchor.icons
  end

  it("drops a trinket advisory with nothing equipped", function()
    local Tuono, stub = harness.boot({ inCombat = true })
    stub.state.trinkets = {}   -- nothing in slot 13
    local icons = renderQueue(Tuono, {
      { spellID = 193315, kind = "rotation", confidence = "certain", isSequence = true },
      { spellID = nil, itemSlot = 13, kind = "trinket", confidence = "certain" },
    })
    expect.truthy(icons[1].visible, "the real recommendation still renders")
    expect.falsy(icons[2].visible,
      "an entry with no spellID and no item art cannot be identified and must not occupy "
        .. "a slot; drawing a placeholder there is what produced the stranger's face")
  end)

  it("KEEPS a real spell whose art merely failed to load", function()
    -- The over-correction to guard against: C_Spell.GetSpellTexture can answer nil
    -- transiently before the client caches a spell, and silently deleting a genuine
    -- recommendation is worse than the placeholder it was meant to prevent.
    local Tuono, stub = harness.boot({ inCombat = true })
    local realGet = _G.C_Spell.GetSpellTexture
    _G.C_Spell.GetSpellTexture = function() return nil end
    local ok = pcall(function()
      local icons = renderQueue(Tuono, {
        { spellID = 193315, kind = "rotation", confidence = "certain", isSequence = true },
      })
      expect.truthy(icons[1].visible,
        "a spell we can name must still be shown; the keybind identifies it even with no art")
    end)
    _G.C_Spell.GetSpellTexture = realGet
    if not ok then error("assertions failed", 0) end
  end)

  it("never falls back to a hardcoded icon id", function()
    -- There is no stable numeric icon to fall back to, so the code must not pretend there
    -- is. A flat colour block is honest; a FileDataID is a guess that ages badly.
    local src = io.open("Tuono/Display.lua"):read("*a")
    local stripped = src:gsub("%-%-[^\n]*", "")
    expect.falsy(stripped:find("134400", 1, true),
      "a hardcoded FileDataID reappeared in Display.lua")
  end)
end)
