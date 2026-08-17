-- The load canary. If this suite is red, nothing below it means anything.

local harness = require("harness")

describe("load", function()
  it("every .toc file compiles and runs", function()
    expect.noThrow(function() harness.load() end)
  end)

  it("publishes the modules Core's own canary checks for", function()
    local Tuono = harness.load()
    for _, mod in ipairs({ "State", "Assist", "Engine", "Rules", "Display", "defaults" }) do
      expect.truthy(Tuono[mod], "Tuono." .. mod .. " missing after load")
    end
  end)

  it("reaches a logged-in state without error", function()
    expect.noThrow(function() harness.boot() end)
  end)

  it("activates the Outlaw profile and rebuilds the ability tables", function()
    local Tuono = harness.boot()
    local profile = Tuono.Profiles.Active()
    expect.truthy(profile, "no active profile")
    expect.equal(profile.id, "outlaw-rogue")
    expect.truthy(next(Tuono.Rotation.ABILITIES), "ABILITIES never rebuilt from the profile")
    expect.truthy(Tuono.Rotation.SPELL_TO_CDKEY[193315] == nil
      or type(Tuono.Rotation.SPELL_TO_CDKEY[193315]) == "string")
  end)

  it("logs no addon errors during boot", function()
    local Tuono = harness.boot()
    expect.equal(Tuono.errorCount or 0, 0,
      "Tuono.safe swallowed errors during boot: " .. table.concat(
        (function()
          local out = {}
          for k in pairs(Tuono.errorsSeen or {}) do table.insert(out, k) end
          return out
        end)(), " | "))
  end)
end)
