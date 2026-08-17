-- ============================================================================
-- SECRET-VALUE MISUSE LINT
-- ============================================================================
-- tests/wow_stub.lua states the hole this closes: Lua has no __tobool metamethod, so a
-- stub secret is a table and `if secretValue then` tests TRUTHY offline. The same line
-- THROWS in the real client. Equality against a secret has the same shape -- Lua's `==`
-- only invokes __eq table-to-table, so `secretID == 12345` quietly returns false here
-- and raises in game.
--
-- Those two are unreachable at runtime by any stub, so they need static analysis or they
-- need nothing. This is the static analysis.
--
-- SCOPE, deliberately narrow. Full dataflow is out of scope, and a lint that cries wolf
-- gets disabled -- which is identical to not having one. Two checks only, both chosen
-- because they are zero-false-positive on this codebase today:
--
--   1. A secret-bearing call whose result is operated on in the same expression,
--      e.g. `if UnitPower("player", 3) > 0 then`.
--   2. ONE HOP: a local assigned straight from a secret-bearing call with no guard,
--      then used dangerously inside the same block.
--
-- The safe pattern everywhere in this addon is to route through Tuono.readNum /
-- Tuono.readBool / Tuono.num / Tuono.bool / Tuono.isSecret, or to pcall the call. Those
-- are recognised and never flagged.
--
-- Categories deliberately NOT implemented, because they could not be made
-- low-false-positive without real dataflow: values that cross a function boundary
-- (parameters, returns, table fields). Display.lua's safeActionInfo launders through
-- readNum before returning, so its callers are safe -- but this lint cannot prove that,
-- and guessing would produce noise.
-- ============================================================================

local harness = require("harness")

local function readFile(path)
  local fh = io.open(path, "rb")
  if not fh then return nil end
  local s = fh:read("*a")
  fh:close()
  return s
end

-- Blank comments and string literals, preserving byte offsets and newlines, so a
-- mention of UnitPower in a comment cannot trigger a finding. Duplicated from
-- lint_lua51.lua on purpose: each gate stays self-contained and independently runnable.
local function strip(src)
  local out = {}
  local i, n = 1, #src
  while i <= n do
    local c = src:sub(i, i)
    if c == "-" and src:sub(i + 1, i + 1) == "-" then
      local eq = src:match("^%-%-%[(=*)%[", i)
      if eq then
        local close = "]" .. eq .. "]"
        local _, e = src:find(close, i, true)
        local stop = e or n
        for k = i, stop do out[#out + 1] = (src:sub(k, k) == "\n") and "\n" or " " end
        i = stop + 1
      else
        while i <= n and src:sub(i, i) ~= "\n" do out[#out + 1] = " " i = i + 1 end
      end
    elseif c == '"' or c == "'" then
      local quote = c
      out[#out + 1] = " "
      i = i + 1
      while i <= n do
        local d = src:sub(i, i)
        if d == "\\" then
          out[#out + 1] = " " out[#out + 1] = " " i = i + 2
        elseif d == quote then
          out[#out + 1] = " " i = i + 1 break
        elseif d == "\n" then
          break
        else
          out[#out + 1] = " " i = i + 1
        end
      end
    else
      local eq = src:match("^%[(=*)%[", i)
      if eq then
        local close = "]" .. eq .. "]"
        local _, e = src:find(close, i, true)
        local stop = e or n
        for k = i, stop do out[#out + 1] = (src:sub(k, k) == "\n") and "\n" or " " end
        i = stop + 1
      else
        out[#out + 1] = c
        i = i + 1
      end
    end
  end
  return table.concat(out)
end

local function splitLines(s)
  local out = {}
  for line in (s .. "\n"):gmatch("([^\n]*)\n") do out[#out + 1] = line end
  return out
end

-- --- what can hand back a secret --------------------------------------------

-- Matched on the FINAL name component, so `GetActionInfo(`, `_G.GetActionInfo(` and
-- `C_Spell.GetSpellCooldown(` all resolve.
--
-- These are calls whose RETURN VALUE can itself be secret.
local SECRET_CALLS = {
  UnitPower = true, UnitPowerMax = true,
  GetHaste = true, UnitSpellHaste = true, GetMeleeHaste = true, UnitAttackSpeed = true,
  GetActionInfo = true, GetBindingKey = true,
  GetSpellCooldown = true,
  GetPowerRegenForPowerType = true, GetPowerRegen = true,
  GetNextCastSpell = true,
}

-- DELIBERATELY ABSENT: C_UnitAuras.GetAuraDataByIndex, GetPlayerAuraBySpellID, UnitBuff.
--
-- What Midnight hides on these is the aura PAYLOAD -- applications, expirationTime,
-- duration -- not the container. The table comes back normal and `nil` still terminates
-- an index walk, so `if not aura then break end` is correct and is the idiom in both
-- StateTracker and Recorder. Listing them here flagged that idiom everywhere and taught
-- nobody anything.
--
-- The field-level danger is real but needs dataflow this lint does not have. The
-- ordering check below catches the one shape of it that is decidable from a single line.

-- Reading through any of these is the safe pattern and is never a finding.
local SAFE_WRAPPERS = {
  pcall = true, xpcall = true,
  readNum = true, readBool = true, num = true, bool = true, isSecret = true,
  obs = true,
}

-- ALLOWLIST -- individually justified, keyed "file.lua:line:check".
--
-- Every entry here is a KNOWN DEFECT that is out of scope to fix right now, not a safe
-- pattern. An entry is visible and reviewable; weakening the lint to make a finding
-- disappear would not be, which is why nothing above this line was softened to suit it.
local ALLOW = {
  -- FIXED, entries removed. Kept as a note because the fix found something worse than
  -- what was filed: the allowlist comment below used to assert that the INDEXED path
  -- "pcalls correctly". It did not. rebuildSlotIndex pcall'd the GetActionInfo CALL but
  -- passed its secret return value straight into Tuono.ResolveBaseSpell, which raised --
  -- emptying the whole slot index, so no spell resolved to any button. The cold path
  -- named here was real; the confident claim about the hot path next to it was not.
  --
  -- Both now route through a local safeActionInfo mirroring Display's.
  --
  -- Original entry, for the record:
  -- GetActionSlotForSpell_Scan calls _G.GetActionInfo un-pcall'd and then compares the
  -- result (`actionType == "spell"`, `actionID == spellID`). A secret actionID makes
  -- both comparisons raise in the live client.
  --
  -- Deferred, not dismissed: the function is documented off the hot path ("not on any
  -- hot path any more") and is reachable only from /tuono debug. The indexed path that
  -- replaced it, rebuildSlotIndex at Highlight.lua:122, pcalls correctly.
  --
  -- Display.lua hit this exact bug inside the render loop and it cost the entire icon
  -- strip; see its safeActionInfo comment. Same defect, colder path.

  -- `if aura.spellId and not isSecret(aura.spellId) then` -- the boolean test runs
  -- BEFORE the secrecy check it depends on, so a secret spellId raises on the very line
  -- written to defend against it. Correct form is `local id = Tuono.readNum(aura.spellId)`
  -- then `if id then`. Deferred: StateTracker.lua is outside this change's scope, and
  -- the reachable path is the TIER 3 fallback that only runs when delta tracking found
  -- nothing.
  -- `src` PINS THE SOURCE TEXT, not just the line number. A line-number-only check is
  -- not a staleness check: Highlight.lua grew by 244 lines while its four entries were
  -- being made obsolete by the very fix that obsoleted them, and every one still
  -- "resolved" to some line, so the gate stayed green over four dead entries. An
  -- allowlist that outlives the code it excused is worse than no allowlist, because it
  -- reads as a reviewed decision.
  ["StateTracker.lua:488:order"] = {
    why = "known defect: value boolean-tested before its own isSecret guard",
    src = "if aura.spellId and not isSecret(aura.spellId) then",
  },
}

-- --- expression helpers -----------------------------------------------------

-- Index of the ')' closing the '(' at openIdx, or nil when the call spans lines.
local function matchParen(line, openIdx)
  local depth = 0
  for i = openIdx, #line do
    local c = line:sub(i, i)
    if c == "(" then depth = depth + 1
    elseif c == ")" then
      depth = depth - 1
      if depth == 0 then return i end
    end
  end
  return nil
end

local ARITH = "[%+%-%*/%%%^]"

-- Why the text at [s,e] is being used unsafely, or nil.
local function dangerAt(line, s, e)
  local before = line:sub(1, s - 1)
  local after = line:sub(e + 1)

  if after:match("^%s*%.%.") or before:match("%.%.%s*$") then
    return "concatenated"
  end
  if after:match("^%s*[<>]=?") or after:match("^%s*[=~]=") then
    return "compared"
  end
  if before:match("[<>]=?%s*$") or before:match("[=~]=%s*$") then
    return "compared"
  end
  if after:match("^%s*" .. ARITH) then
    return "used in arithmetic"
  end
  -- A leading '-' is only arithmetic if something precedes it; `= -x` is negation of a
  -- secret, which raises just the same.
  if before:match(ARITH .. "%s*$") then
    return "used in arithmetic"
  end
  if before:match("#%s*$") then
    return "measured with #"
  end
  if before:match("%f[%w_]if%s*$") or before:match("%f[%w_]elseif%s*$")
    or before:match("%f[%w_]while%s*$") or before:match("%f[%w_]not%s*$")
    or before:match("%f[%w_]and%s*$") or before:match("%f[%w_]or%s*$")
    or before:match("%f[%w_]until%s*$") then
    return "tested as a boolean"
  end
  if after:match("^%s*then%f[^%w_]") or after:match("^%s*and%f[^%w_]")
    or after:match("^%s*or%f[^%w_]") then
    return "tested as a boolean"
  end
  if before:match("%[%s*$") and after:match("^%s*%]") then
    return "used as a table key"
  end
  return nil
end

local function dangerousUse(line, v)
  local pat = "%f[%w_]" .. v .. "%f[^%w_]"
  local init = 1
  while true do
    local s, e = line:find(pat, init)
    if not s then return nil end
    -- Assignment TO the variable is not a use of its value.
    local isAssign = line:sub(e + 1):match("^%s*=[^=]") ~= nil
    if not isAssign then
      local why = dangerAt(line, s, e)
      if why then return why end
    end
    init = e + 1
  end
end

-- Leading-whitespace width; tabs count as one level, which is what this codebase uses.
local function indentOf(line)
  local ws = line:match("^([ \t]*)")
  return #ws
end

local function isBlank(line) return line:match("^%s*$") ~= nil end

-- Last line of the block opened at `from`: the first later non-blank line that dedents
-- past it. Capped, because a runaway window would start inventing findings.
local function blockEnd(lines, from)
  local base = indentOf(lines[from])
  local cap = math.min(#lines, from + 30)
  for j = from + 1, cap do
    if not isBlank(lines[j]) and indentOf(lines[j]) < base then return j - 1 end
  end
  return cap
end

-- Final component of a dotted call head: `_G.GetActionInfo` -> `GetActionInfo`.
local function lastComponent(head)
  return head:match("([%w_]+)$") or head
end

-- Lines inside a `pcall(function() ... end)` body. Wrapping in pcall IS the documented
-- safe pattern, and ApiTest wraps whole probe blocks that way rather than each call --
-- so an expression-level check alone reads those as unguarded when they are not.
local function pcallProtected(lines)
  local marked = {}
  for i, line in ipairs(lines) do
    if line:match("%f[%w_]x?pcall%s*%(%s*function") then
      local base = indentOf(line)
      local stop = math.min(#lines, i + 60)
      for j = i + 1, stop do
        if not isBlank(lines[j]) and indentOf(lines[j]) <= base
          and lines[j]:match("^%s*end%s*%)") then
          stop = j
          break
        end
      end
      for j = i, stop do marked[j] = true end
    end
  end
  return marked
end

-- --- the scan ---------------------------------------------------------------

local function analyze(rel, src, wanted)
  local code = splitLines(strip(src))
  local raw = splitLines(src)
  local guarded = pcallProtected(code)
  local findings = {}

  local function record(lineNo, tag, why)
    if tag ~= wanted then return end
    if guarded[lineNo] then return end
    if ALLOW[rel .. ":" .. lineNo .. ":" .. tag] then return end
    findings[#findings + 1] = string.format("%s:%d  %s  |  %s",
      rel, lineNo, why, (raw[lineNo] or ""):gsub("^%s+", ""):gsub("%s+$", ""))
  end

  -- 0. A value boolean-tested in the same conditional that then asks whether it is
  -- secret. The guard runs too late to protect the test that precedes it, so the line
  -- raises on exactly the input it was written to survive. Decidable from one line, and
  -- the back-reference makes it exact.
  for i, line in ipairs(code) do
    local subject = line:match("%f[%w_]if%s+([%w_][%w_%.]*)%s+and%s+.-isSecret%s*%(%s*%1%s*%)")
      or line:match("%f[%w_]if%s+not%s+([%w_][%w_%.]*)%s+or%s+.-isSecret%s*%(%s*%1%s*%)")
    if subject then
      record(i, "order", "'" .. subject .. "' is boolean-tested before its own isSecret() guard")
    end
  end

  -- 1. operated on in the same expression as the call
  for i, line in ipairs(code) do
    local init = 1
    while true do
      local s, e, head = line:find("([%w_%.]+)%s*%(", init)
      if not s then break end
      if SECRET_CALLS[lastComponent(head)] then
        local close = matchParen(line, line:find("%(", s + #head - 1) or e)
        if close then
          local why = dangerAt(line, s, close)
          if why then
            record(i, "op", lastComponent(head) .. "() result is " .. why .. " without a guarded read")
          end
        end
      end
      init = e
    end
  end

  -- 2. one hop: unguarded local, then a dangerous use inside the same block
  for i, line in ipairs(code) do
    if not line:match("^%s*local%s+function%f[^%w_]") then
      local names, rhs = line:match("^%s*local%s+([%a_][%w_]*[%w_%s,]*)%s*=%s*(.+)$")
      if names and rhs and not rhs:match("^=") then
        local head = rhs:match("^([%w_%.]+)%s*%(")
        if head then
          local base = lastComponent(head)
          if SECRET_CALLS[base] and not SAFE_WRAPPERS[base] and not SAFE_WRAPPERS[lastComponent(head)] then
            local vars = {}
            for v in names:gmatch("[%a_][%w_]*") do vars[#vars + 1] = v end
            local stop = blockEnd(code, i)
            for j = i + 1, stop do
              for _, v in ipairs(vars) do
                local why = dangerousUse(code[j], v)
                if why then
                  record(j, "op", string.format("'%s' came unguarded from %s() at line %d and is %s",
                    v, base, i, why))
                end
              end
            end
          end
        end
      end
    end
  end

  return findings
end

local function sweep(tag)
  local all = {}
  for _, rel in ipairs(harness.tocFiles()) do
    local src = readFile(harness.root .. "/" .. rel)
    if src then
      for _, f in ipairs(analyze(rel, src, tag)) do all[#all + 1] = f end
    end
  end
  table.sort(all)
  return all
end

local function detail(list)
  if #list == 0 then return "" end
  return "\n         " .. table.concat(list, "\n         ")
end

describe("secret-value handling", function()
  it("never operates on a secret-bearing return without a guarded read", function()
    local all = sweep("op")
    expect.listEqual(all, {},
      "these throw in the live client and pass in the stub, because Lua has no " ..
      "__tobool and __eq never fires table-to-number" .. detail(all))
  end)

  it("never boolean-tests a value before its own isSecret guard", function()
    local all = sweep("order")
    expect.listEqual(all, {},
      "the guard runs after the test it was meant to protect" .. detail(all))
  end)

  it("keeps every allowlist entry pointed at the code it excused", function()
    -- A stale allowlist silently re-opens the hole it was documenting -- and reads as a
    -- reviewed decision while doing it, which is the dangerous part.
    local stale = {}
    local cache = {}
    for key, entry in pairs(ALLOW) do
      local rel, lineNo = key:match("^(.+):(%d+):[%w_]+$")
      local src = cache[rel]
      if src == nil then
        src = readFile(harness.root .. "/" .. rel) or false
        cache[rel] = src
      end
      if not src then
        stale[#stale + 1] = key .. " (file missing)"
      else
        local lines = splitLines(src)
        local actual = lines[tonumber(lineNo)]
        if not actual then
          stale[#stale + 1] = key .. " (line missing)"
        else
          -- Compare on the source text, whitespace-normalised. If the excused code moved
          -- or was fixed, the entry is dead and must be removed by hand -- deliberately,
          -- so someone re-reads the justification rather than inheriting it.
          local want = type(entry) == "table" and entry.src or nil
          if want then
            local got = actual:gsub("^%s+", ""):gsub("%s+$", ""):gsub("%s+", " ")
            want = want:gsub("^%s+", ""):gsub("%s+$", ""):gsub("%s+", " ")
            if got ~= want then
              stale[#stale + 1] = string.format(
                "%s (source changed)\n           expected: %s\n           found:    %s",
                key, want, got)
            end
          else
            stale[#stale + 1] = key .. " (no src pin -- add one, a line number is not a pin)"
          end
        end
      end
    end
    table.sort(stale)
    expect.listEqual(stale, {}, "allowlist entries no longer describe the code they excused")
  end)

  it("actually scanned the addon (a lint over zero files is not a pass)", function()
    expect.truthy(#harness.tocFiles() >= 15, "expected the full .toc")
  end)
end)
