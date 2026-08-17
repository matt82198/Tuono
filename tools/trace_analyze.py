#!/usr/bin/env python3
"""Parse a Tuono SavedVariables trace and report what actually happened.

WoW serialises SavedVariables as a plain Lua source file, so a recorded flight is
readable off disk with no game running. This turns one into numbers.

Usage:
    python3 tools/trace_analyze.py <path to Tuono.lua>

The parser handles the subset of Lua that WoW's serialiser emits: nested tables,
["key"] = value entries, positional entries, strings, numbers, booleans, nil.
Nothing else appears in a SavedVariables file, so a general Lua parser is overkill.
"""

from __future__ import annotations

import re
import sys
from collections import Counter, defaultdict
from pathlib import Path

# --- Lua value scanner -------------------------------------------------------

TOKEN = re.compile(
    r"""
      (?P<ws>\s+)
    | (?P<comment>--[^\n]*)
    | (?P<string>"(?:\\.|[^"\\])*")
    | (?P<number>-?(?:\d+\.\d+|\.\d+|\d+)(?:[eE][-+]?\d+)?)
    | (?P<name>[A-Za-z_]\w*)
    | (?P<punct>[\{\}\[\]=,;])
    """,
    re.VERBOSE,
)

ESCAPES = {"n": "\n", "t": "\t", "r": "\r", '"': '"', "\\": "\\", "'": "'"}


def _unescape(raw: str) -> str:
    body, out, i = raw[1:-1], [], 0
    while i < len(body):
        ch = body[i]
        if ch == "\\" and i + 1 < len(body):
            nxt = body[i + 1]
            if nxt in ESCAPES:
                out.append(ESCAPES[nxt])
                i += 2
                continue
            if nxt.isdigit():  # \ddd decimal escape
                j = i + 1
                digits = ""
                while j < len(body) and body[j].isdigit() and len(digits) < 3:
                    digits += body[j]
                    j += 1
                out.append(chr(int(digits)))
                i = j
                continue
        out.append(ch)
        i += 1
    return "".join(out)


def tokenize(src: str):
    pos, end = 0, len(src)
    while pos < end:
        m = TOKEN.match(src, pos)
        if not m:
            raise SyntaxError(f"cannot tokenize at offset {pos}: {src[pos:pos + 40]!r}")
        pos = m.end()
        kind = m.lastgroup
        if kind in ("ws", "comment"):
            continue
        yield kind, m.group()
    yield "eof", ""


class Parser:
    def __init__(self, src: str):
        self.toks = list(tokenize(src))
        self.i = 0

    def peek(self):
        return self.toks[self.i]

    def next(self):
        t = self.toks[self.i]
        self.i += 1
        return t

    def expect(self, text: str):
        kind, val = self.next()
        if val != text:
            raise SyntaxError(f"expected {text!r}, got {val!r} at token {self.i}")

    def parse_value(self):
        kind, val = self.next()
        if kind == "string":
            return _unescape(val)
        if kind == "number":
            return float(val) if ("." in val or "e" in val.lower()) else int(val)
        if kind == "name":
            if val == "true":
                return True
            if val == "false":
                return False
            if val == "nil":
                return None
            return val  # bare identifier; shouldn't occur but don't lose it
        if val == "{":
            return self.parse_table()
        raise SyntaxError(f"unexpected value token {val!r}")

    def parse_table(self):
        """Returns a dict for keyed tables, a list for purely positional ones."""
        keyed, positional = {}, []
        while True:
            kind, val = self.peek()
            if val == "}":
                self.next()
                break
            if val == "[":
                self.next()
                key = self.parse_value()
                self.expect("]")
                self.expect("=")
                keyed[key] = self.parse_value()
            else:
                positional.append(self.parse_value())
            kind, val = self.peek()
            if val in (",", ";"):
                self.next()
        if keyed and not positional:
            return keyed
        if positional and not keyed:
            return positional
        if not keyed and not positional:
            return {}
        keyed.update({i + 1: v for i, v in enumerate(positional)})
        return keyed


def parse_savedvariables(text: str) -> dict:
    """Top level is a sequence of `Name = <value>` assignments."""
    out = {}
    for m in re.finditer(r"^([A-Za-z_]\w*)\s*=\s*", text, re.MULTILINE):
        p = Parser(text[m.end():])
        out[m.group(1)] = p.parse_value()
    return out


# --- Reporting ---------------------------------------------------------------

def ordered_samples(diag: dict) -> list:
    """Undo the ring buffer so records come back in the order they happened."""
    samples = diag.get("samples") or []
    if isinstance(samples, dict):  # sparse ring -> dense, index order
        samples = [samples[k] for k in sorted(samples)]
    if not diag.get("wrapped"):
        return samples
    cursor = int(diag.get("cursor", 1))
    return samples[cursor - 1:] + samples[:cursor - 1]


def spell_name(spell_id, names: dict) -> str:
    return names.get(spell_id, str(spell_id))


def report(path: Path) -> int:
    data = parse_savedvariables(path.read_text(encoding="utf-8", errors="replace"))
    diag = data.get("TuonoDiagDB")
    if not diag:
        print("No TuonoDiagDB in this file — was /tuono record ever run?")
        return 1

    samples = ordered_samples(diag)
    by_kind = Counter(s.get("k") for s in samples if isinstance(s, dict))

    print(f"=== {path.name} ===")
    print(f"started: {diag.get('startedAt')}   samples: {len(samples)}"
          f"   wrapped: {bool(diag.get('wrapped'))}")
    if samples:
        times = [s["t"] for s in samples if isinstance(s, dict) and "t" in s]
        if times:
            print(f"span:    {max(times) - min(times):.1f}s")
    print("kinds:  ", dict(by_kind))

    # Build a spellID -> name map from any auras captured alongside the trace.
    names = {}
    for key in ("aurasAtStart", "aurasAtStop", "aurasManual"):
        for a in diag.get(key) or []:
            if isinstance(a, dict) and isinstance(a.get("spellId"), int):
                names[a["spellId"]] = a.get("name", "?")

    # --- casts vs failures --------------------------------------------------
    casts = Counter()
    fails = Counter()
    for s in samples:
        if not isinstance(s, dict):
            continue
        if s.get("k") == "cast":
            casts[s.get("id")] += 1
        elif s.get("k") == "castfail":
            fails[s.get("id")] += 1

    print("\n--- casts that SUCCEEDED ---")
    for sid, n in casts.most_common():
        print(f"  {n:5d}  {spell_name(sid, names)}")
    print(f"  {sum(casts.values()):5d}  TOTAL")

    print("\n--- casts that FAILED ---")
    for sid, n in fails.most_common(15):
        print(f"  {n:5d}  {spell_name(sid, names)}")
    print(f"  {sum(fails.values()):5d}  TOTAL")

    # --- UI errors, paired with what we were recommending --------------------
    errs = Counter()
    err_vs_rec = defaultdict(Counter)
    gcd_at_err = []
    for s in samples:
        if not isinstance(s, dict) or s.get("k") != "uierr":
            continue
        label = s.get("name") or s.get("msg") or f"errorType={s.get('errorType')}"
        errs[label] += 1
        err_vs_rec[label][s.get("rec")] += 1
        if isinstance(s.get("gcd"), (int, float)):
            gcd_at_err.append(s["gcd"])

    print("\n--- UI errors (what the client complained about) ---")
    for label, n in errs.most_common(10):
        print(f"  {n:5d}  {label}")
        for rec, rn in err_vs_rec[label].most_common(3):
            print(f"           while recommending {spell_name(rec, names)} x{rn}")
    if gcd_at_err:
        blocked = sum(1 for g in gcd_at_err if g > 0)
        print(f"\n  GCD was ACTIVE for {blocked}/{len(gcd_at_err)} errors "
              f"({100.0 * blocked / len(gcd_at_err):.0f}%)")

    # --- tick state ----------------------------------------------------------
    ticks = [s for s in samples if isinstance(s, dict) and s.get("k") == "tick"]
    if ticks:
        print(f"\n--- state over {len(ticks)} ticks ---")

        def frac(pred):
            return 100.0 * sum(1 for t in ticks if pred(t)) / len(ticks)

        # Sequence depth as the player actually saw it. Absent in traces recorded before
        # the recorder learned to capture it.
        vis = [t["vis"] for t in ticks if isinstance(t.get("vis"), int)]
        if vis:
            hist = Counter(vis)
            spread = "  ".join(f"{n}:{hist[n]}" for n in sorted(hist))
            print(f"  icons shown           : median {sorted(vis)[len(vis) // 2]}, "
                  f"min {min(vis)}, max {max(vis)}   [{spread}]")
            one_or_less = sum(1 for v in vis if v <= 1)
            print(f"  collapsed to <=1 icon : {100.0 * one_or_less / len(vis):.0f}% of ticks")
            fb = sum(1 for t in ticks if t.get("fb") is True)
            if fb:
                print(f"  fell back to filler   : {fb} ticks")
            reasons = Counter(t.get("replan") for t in ticks if t.get("replan"))
            if reasons:
                print(f"  re-plan reasons       : {dict(reasons)}")
        else:
            print("  icons shown           : not recorded (trace predates queue capture)")

        print(f"  combo points readable : {frac(lambda t: t.get('cpK') is not False):.0f}%")
        print(f"  RtB stage readable    : {frac(lambda t: t.get('rtbK') is True):.0f}%")
        print(f"  aura data degraded    : {frac(lambda t: t.get('deg') is True):.0f}%")
        widths = [t["eHi"] - t["eLo"] for t in ticks
                  if isinstance(t.get("eLo"), (int, float))
                  and isinstance(t.get("eHi"), (int, float))]
        if widths:
            widths_sorted = sorted(widths)
            med = widths_sorted[len(widths_sorted) // 2]
            print(f"  energy interval width : median {med:.1f}, "
                  f"min {min(widths):.1f}, max {max(widths):.1f}  (n={len(widths)})")
        else:
            print("  energy interval width : never seeded")

        regens = [t["regen"] for t in ticks if isinstance(t.get("regen"), (int, float))]
        if regens:
            print(f"  measured regen        : {sum(regens) / len(regens):.2f}/s "
                  f"(n={len(regens)})")
        else:
            print("  measured regen        : never solved")

        # Position-1 churn: how often the top recommendation changed between ticks.
        flips = sum(1 for a, b in zip(ticks, ticks[1:]) if a.get("rec1") != b.get("rec1"))
        span = (ticks[-1].get("t", 0) - ticks[0].get("t", 0)) or 1
        print(f"  position-1 changes    : {flips} over {span:.0f}s "
              f"({flips / span:.2f}/s)")

        modes = Counter(t.get("mode") for t in ticks)
        print(f"  rotation mode         : {dict(modes)}")

        # Agreement with Blizzard's own pick, where both are present.
        both = [t for t in ticks if t.get("assist") and t.get("rec1")]
        if both:
            agree = sum(1 for t in both if t["assist"] == t["rec1"])
            print(f"  agrees with Blizzard  : {agree}/{len(both)} "
                  f"({100.0 * agree / len(both):.0f}%)")

    # --- what the client said was secret ------------------------------------
    probe = diag.get("probeAtStop") or diag.get("probeAtStart")
    if isinstance(probe, dict):
        print("\n--- secrecy at probe time ---")
        print(f"  in combat: {probe.get('inCombat')}")
        for section in ("power", "unusedReads", "secrecyPredicates", "readBack"):
            val = probe.get(section)
            if isinstance(val, dict):
                print(f"  {section}:")
                for k, v in sorted(val.items(), key=lambda kv: str(kv[0])):
                    print(f"      {k:32s} {v}")
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print(__doc__)
        sys.exit(2)
    sys.exit(report(Path(sys.argv[1])))
