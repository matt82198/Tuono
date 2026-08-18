-- ============================================================================
-- ACTION BAR HIGHLIGHT
-- ============================================================================
-- The overlay is the surface most players will actually look at, and it is the surface
-- where Blizzard already ships something (Assisted Highlight, native since 11.1.7). A
-- Tuono glow that merely marks position 1 is a worse copy of a built-in feature; the
-- only thing that justifies occupying the bar is carrying what Blizzard's cannot --
-- lead time and uncertainty. See docs/UI.md.
-- ============================================================================

local harness = require("harness")

local SINISTER_STRIKE = 193315
local DISPATCH = 2098
local BETWEEN_THE_EYES = 315341

-- Create the glow pool in isolation so the test can inspect exactly the frames Highlight
-- made, and nothing Display made. PLAYER_LOGIN would init both; ADDON_LOADED alone gives
-- us Tuono.db without any frames.
local function poolFrames()
  local Tuono, stub = harness.load()
  stub.FireEvent("ADDON_LOADED", "Tuono")
  local before = #stub.frames
  Tuono.Highlight.Init()
  local frames = {}
  for i = before + 1, #stub.frames do
    table.insert(frames, stub.frames[i])
  end
  return frames, Tuono, stub
end

-- Every texture created on the pool frames, flattened.
local function poolTextures(frames)
  local out = {}
  for _, f in ipairs(frames) do
    for _, r in ipairs(f.regions or {}) do
      table.insert(out, r)
    end
  end
  return out
end

describe("highlight: the glow must not hide the ability it recommends", function()
  it("creates a pool of overlay frames at init", function()
    local frames = poolFrames()
    expect.truthy(#frames > 0, "no overlay frames were pre-created")
  end)

  it("gives every overlay colour an explicit alpha", function()
    local frames = poolFrames()
    local textures = poolTextures(frames)
    expect.truthy(#textures > 0, "no textures on the overlay frames")
    for i, tex in ipairs(textures) do
      if tex.color then
        -- SetColorTexture(r, g, b) with no fourth argument DEFAULTS ALPHA TO 1.0. On a
        -- texture that covers the whole button at HIGH strata, that is a solid rectangle
        -- over the spell art: the player is told "press the green square" and cannot see
        -- which spell it is.
        expect.truthy(tex.color[4] ~= nil,
          "overlay texture " .. i .. " set a colour with no alpha, so it paints opaque")
        expect.truthy((tex.color[4] or 1) < 1.0,
          "overlay texture " .. i .. " is fully opaque (alpha "
            .. tostring(tex.color[4]) .. ")")
      end
    end
  end)

  it("draws a ring rather than one full-coverage fill", function()
    local frames = poolFrames()
    -- The stub cannot model geometry (SetAllPoints and SetPoint are no-ops), so the
    -- structure is what is asserted: a ring is several edge pieces, a fill is one
    -- texture stretched over the button. Anything that occludes the icon is a fill.
    for _, f in ipairs(frames) do
      expect.falsy(f.tex,
        "the overlay still carries a single full-coverage fill texture; a ring keeps "
          .. "the ability art readable, a fill hides it")
      expect.truthy(f.ring and #f.ring >= 4,
        "expected a ring built from at least four edge textures")
    end
  end)

  it("does not use pure green, the worst colourblind choice", function()
    local frames = poolFrames()
    for _, tex in ipairs(poolTextures(frames)) do
      local c = tex.color
      if c then
        local pureGreen = (c[1] or 0) < 0.2 and (c[2] or 0) > 0.8 and (c[3] or 0) < 0.5
        expect.falsy(pureGreen,
          "green/red is the most common colourblind failure (deuteranopia, ~6% of men). "
            .. "Authority should be carried by luminance, which works for every form of "
            .. "colour vision.")
      end
    end
  end)
end)

describe("highlight: the sweep and the slot map must agree", function()
  it("publishes a maximum action slot", function()
    local Tuono = harness.boot()
    expect.truthy(type(Tuono.Highlight.MAX_ACTION_SLOT) == "number",
      "no published bound, so the index sweep and the frame mapping can drift apart "
        .. "silently -- which they did (sweep 1..120, mapping <=108)")
  end)

  it("resolves a frame name for every slot it is willing to index", function()
    local Tuono = harness.boot()
    local maxSlot = Tuono.Highlight.MAX_ACTION_SLOT
    local unresolvable = {}
    for slot = 1, maxSlot do
      if not Tuono.Highlight.FrameNameForSlot(slot) then
        table.insert(unresolvable, slot)
      end
    end
    expect.listEqual(unresolvable, {},
      "these slots get indexed but resolve to no button frame, so the glow silently "
        .. "never appears and there is no diagnostic")
  end)

  it("refuses to resolve a frame beyond that bound", function()
    local Tuono = harness.boot()
    local maxSlot = Tuono.Highlight.MAX_ACTION_SLOT
    expect.falsy(Tuono.Highlight.FrameNameForSlot(maxSlot + 1),
      "claimed a frame for a slot that has none")
  end)

  it("glows a spell sitting on the last real action bar", function()
    local Tuono, stub = harness.boot({
      inCombat = true,
      world = function(s)
        -- 97..108 is MultiBar7, the highest bar with named button frames.
        s.placeOnBar(108, SINISTER_STRIKE)
        s.state.assist.nextSpell = SINISTER_STRIKE
      end,
    })
    _G.MultiBar7Button12 = _G.MultiBar7Button12 or CreateFrame("Frame", "MultiBar7Button12")
    Tuono.Highlight.Update({ queue = { { spellID = SINISTER_STRIKE, isSequence = true } } })
    expect.truthy(Tuono.Highlight.LastButtonName() ~= nil,
      "a spell on bar 8 resolved to no button")
  end)
end)

describe("highlight: secret action data must not blind the sweep", function()
  it("keeps indexing later slots when an earlier one returns a secret", function()
    local Tuono, stub = harness.boot({
      inCombat = true,
      world = function(s)
        s.state.actionSlots[5] = { type = "spell", id = s.makeSecret(999999) }
        s.placeOnBar(6, SINISTER_STRIKE)
        s.state.assist.nextSpell = SINISTER_STRIKE
      end,
    })
    _G.ActionButton6 = _G.ActionButton6 or CreateFrame("Frame", "ActionButton6")
    -- One unreadable slot must cost at most that slot. Display already learned this the
    -- hard way: a secret actionID mid-loop took out the entire icon strip.
    expect.noThrow(function()
      Tuono.Highlight.Update({ queue = { { spellID = SINISTER_STRIKE, isSequence = true } } })
    end, "a secret action slot took the highlight module down")
    expect.truthy(Tuono.Highlight.LastButtonName() ~= nil,
      "the spell after the secret slot was never indexed")
  end)
end)

describe("highlight: lead time on the bar", function()
  local function bootWithBar()
    local Tuono, stub = harness.boot({
      inCombat = true,
      world = function(s)
        s.placeOnBar(1, SINISTER_STRIKE)
        s.placeOnBar(2, DISPATCH)
        s.placeOnBar(3, BETWEEN_THE_EYES)
      end,
    })
    for i = 1, 3 do
      _G["ActionButton" .. i] = _G["ActionButton" .. i]
        or CreateFrame("Frame", "ActionButton" .. i)
    end
    return Tuono, stub
  end

  it("marks more than just the immediate recommendation", function()
    local Tuono = bootWithBar()
    Tuono.Highlight.Update({ queue = {
      { spellID = SINISTER_STRIKE, isSequence = true, confidence = "certain" },
      { spellID = DISPATCH, isSequence = true, confidence = "certain" },
      { spellID = BETWEEN_THE_EYES, isSequence = true, confidence = "certain" },
    } })
    local marks = Tuono.Highlight.ActiveMarks()
    expect.truthy(#marks >= 2,
      "only position 1 was marked. Blizzard already ships a native position-1 "
        .. "highlight, so a helper that does only that is a worse copy of a built-in.")
  end)

  it("gives each marked button its position in the sequence", function()
    local Tuono = bootWithBar()
    Tuono.Highlight.Update({ queue = {
      { spellID = SINISTER_STRIKE, isSequence = true, confidence = "certain" },
      { spellID = DISPATCH, isSequence = true, confidence = "certain" },
    } })
    local marks = Tuono.Highlight.ActiveMarks()
    local byOrdinal = {}
    for _, m in ipairs(marks) do byOrdinal[m.ordinal] = m.spellID end
    expect.equal(byOrdinal[1], SINISTER_STRIKE)
    expect.equal(byOrdinal[2], DISPATCH)
  end)

  it("marks a repeated ability once, carrying the repeat count", function()
    local Tuono = bootWithBar()
    Tuono.Highlight.Update({ queue = {
      { spellID = SINISTER_STRIKE, isSequence = true, confidence = "certain" },
      { spellID = SINISTER_STRIKE, isSequence = true, confidence = "certain" },
      { spellID = SINISTER_STRIKE, isSequence = true, confidence = "certain" },
    } })
    local marks = Tuono.Highlight.ActiveMarks()
    expect.equal(#marks, 1,
      "the same button cannot carry three different ordinals; one mark with a count is "
        .. "the honest rendering of 'Sinister Strike x3'")
    expect.equal(marks[1].repeatCount, 3)
    expect.equal(marks[1].ordinal, 1)
  end)

  it("does not mark a lookahead step it cannot stand behind", function()
    local Tuono = bootWithBar()
    Tuono.Highlight.Update({ queue = {
      { spellID = SINISTER_STRIKE, isSequence = true, confidence = "certain" },
      { spellID = DISPATCH, isSequence = true, confidence = "unknown" },
    } })
    local marks = Tuono.Highlight.ActiveMarks()
    expect.equal(#marks, 1,
      "an uncertain step must not get a pip; length is the certainty signal")
  end)

  it("still marks position 1 even when it is uncertain", function()
    local Tuono = bootWithBar()
    Tuono.Highlight.Update({ queue = {
      { spellID = SINISTER_STRIKE, isSequence = true, confidence = "unknown" },
    } })
    expect.equal(#Tuono.Highlight.ActiveMarks(), 1,
      "refusing to answer 'what do I press now' is strictly worse than answering it "
        .. "with a visible uncertainty cue")
  end)

  it("does not mark the cooldown and trinket reminders appended after the sequence", function()
    local Tuono = bootWithBar()
    Tuono.Highlight.Update({ queue = {
      { spellID = SINISTER_STRIKE, isSequence = true, confidence = "certain" },
      { spellID = DISPATCH, kind = "cooldown" },
    } })
    local marks = Tuono.Highlight.ActiveMarks()
    expect.equal(#marks, 1,
      "advisories are not sequence steps and must not be given an ordinal")
  end)

  it("clears every mark when the feature is switched off", function()
    local Tuono = bootWithBar()
    Tuono.Highlight.Update({ queue = {
      { spellID = SINISTER_STRIKE, isSequence = true, confidence = "certain" },
      { spellID = DISPATCH, isSequence = true, confidence = "certain" },
    } })
    expect.truthy(#Tuono.Highlight.ActiveMarks() > 0, "nothing was marked to begin with")
    Tuono.db.highlight.enabled = false
    Tuono.Highlight.Update({ queue = {} })
    expect.equal(#Tuono.Highlight.ActiveMarks(), 0, "marks survived being disabled")
  end)

  it("releases overlays back to the pool as the sequence shortens", function()
    local Tuono = bootWithBar()
    Tuono.Highlight.Update({ queue = {
      { spellID = SINISTER_STRIKE, isSequence = true, confidence = "certain" },
      { spellID = DISPATCH, isSequence = true, confidence = "certain" },
      { spellID = BETWEEN_THE_EYES, isSequence = true, confidence = "certain" },
    } })
    expect.equal(#Tuono.Highlight.ActiveMarks(), 3)
    Tuono.Highlight.Update({ queue = {
      { spellID = SINISTER_STRIKE, isSequence = true, confidence = "certain" },
    } })
    expect.equal(#Tuono.Highlight.ActiveMarks(), 1,
      "stale overlays left floating over buttons that are no longer recommended")
  end)
end)
