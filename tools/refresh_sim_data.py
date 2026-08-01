#!/usr/bin/env python3
"""
Refresh Simulation Data from SimulationCraft Profiles

Fetches the latest Outlaw Rogue APL from SimulationCraft Midnight branch
and diffs against the rule names in OutlawAssist/data/rules.lua.

Outputs a markdown report comparing APL actions vs. defined rules.
No auto-editing of rules.lua — human-in-the-loop by design.

Exit codes:
  0 = report generated successfully
  2 = network unavailable (fatal)
  1 = other errors
"""

import argparse
import json
import re
import sys
import urllib.request
import urllib.error
from pathlib import Path
from typing import Optional, Dict, List, Tuple


# Embedded sample APL for --selftest mode
SAMPLE_APL = """
# SimulationCraft sample APL snippet
actions=auto_attack
actions+=/adrenaline_rush,if=combo_points<=2
actions+=/between_the_eyes,if=combo_points>=6
actions+=/blade_rush,if=cooldown.ready
actions+=/roll_the_bones,if=buff.duration<5
actions+=/pistol_shot,if=buff.opportunity.up
actions+=/sinister_strike,if=combo_points<=5
"""


def parse_apl_actions(apl_content: str) -> Dict[str, Optional[str]]:
    """
    Parse APL actions from SimulationCraft profile.

    Returns dict mapping action name to if= condition (if present).
    Example: {"adrenaline_rush": "combo_points<=2", "sinister_strike": None}
    """
    actions = {}

    for line in apl_content.split('\n'):
        line = line.strip()

        # Skip comments and empty lines
        if not line or line.startswith('#'):
            continue

        # Parse actions+=/xxx,if=yyy or actions=xxx
        match = re.match(r'actions\+?=/([a-z_0-9]+)(?:,if=(.+))?', line)
        if match:
            action_name = match.group(1)
            condition = match.group(2)
            actions[action_name] = condition

    return actions


def extract_rule_names(rules_lua_path: Path) -> Dict[str, Tuple[str, str]]:
    """
    Extract rule names and descriptions from rules.lua.

    Returns dict mapping rule name to (description, spellID).
    Parses Lua table syntax looking for 'name = "xxx"' entries.
    """
    rules = {}

    try:
        with open(rules_lua_path, 'r', encoding='utf-8') as f:
            content = f.read()

        # Look for name = "xxx" patterns in the Lua file
        name_pattern = r'name\s*=\s*"([^"]+)"'
        for match in re.finditer(name_pattern, content):
            rule_name = match.group(1)
            rules[rule_name] = rule_name
    except Exception as e:
        print(f"Warning: Could not parse rules.lua: {e}", file=sys.stderr)

    return rules


def fetch_simc_profile(branch: str = 'midnight', timeout: int = 10) -> Optional[str]:
    """
    Fetch Outlaw Rogue profile from SimulationCraft GitHub.

    Tries the specified branch first, then falls back to master.
    Returns profile content on success, None on failure.
    """
    branches = [branch, 'master']
    profile_paths = [
        'profiles/MID1/MID1_Rogue_Outlaw.simc',
        'profiles/MID1/MID1_Rogue_Outlaw_Trickster.simc',
        'profiles/Rogue_Outlaw.simc',
    ]

    for try_branch in branches:
        for profile_path in profile_paths:
            url = f'https://raw.githubusercontent.com/simulationcraft/simc/{try_branch}/{profile_path}'

            try:
                req = urllib.request.Request(url)
                with urllib.request.urlopen(req, timeout=timeout) as response:
                    content = response.read().decode('utf-8')
                    return content
            except urllib.error.HTTPError as e:
                if e.code != 404:
                    raise
            except urllib.error.URLError as e:
                # Network error
                raise

    return None


def generate_report(
    apl_actions: Dict[str, Optional[str]],
    rule_names: Dict[str, str],
) -> str:
    """
    Generate markdown diff report comparing APL actions vs. defined rules.
    """
    report = []
    report.append("# Sim-Data Diff Report\n")
    report.append(f"**Generated:** {__name__}")
    report.append("")

    # Actions in APL but not in rules
    apl_set = set(apl_actions.keys())
    rule_set = set(rule_names.keys())

    missing_rules = apl_set - rule_set
    orphaned_rules = rule_set - apl_set

    report.append("## APL Actions Without Rules")
    if missing_rules:
        report.append(f"**Count:** {len(missing_rules)}\n")
        for action in sorted(missing_rules):
            condition = apl_actions[action]
            cond_str = f" (if={condition})" if condition else ""
            report.append(f"- `{action}`{cond_str}")
    else:
        report.append("✓ All APL actions have corresponding rules.")
    report.append("")

    report.append("## Rules Without APL Actions")
    if orphaned_rules:
        report.append(f"**Count:** {len(orphaned_rules)}\n")
        for rule in sorted(orphaned_rules):
            report.append(f"- `{rule}`")
    else:
        report.append("✓ All rules cite APL actions.")
    report.append("")

    report.append("## Summary")
    report.append(f"- APL actions: {len(apl_set)}")
    report.append(f"- Defined rules: {len(rule_set)}")
    report.append(f"- Coverage: {len(apl_set & rule_set)}/{len(apl_set)}")
    report.append("")

    return "\n".join(report)


def selftest() -> int:
    """Run self-test with embedded APL sample."""
    print("Running self-test with embedded APL sample...")

    actions = parse_apl_actions(SAMPLE_APL)
    print(f"✓ Parsed {len(actions)} actions from sample APL")

    # Verify expected actions are present
    expected = {'adrenaline_rush', 'between_the_eyes', 'blade_rush', 'roll_the_bones'}
    parsed = set(actions.keys())

    if expected.issubset(parsed):
        print(f"✓ All expected actions found: {expected}")
        return 0
    else:
        missing = expected - parsed
        print(f"✗ Missing actions: {missing}", file=sys.stderr)
        return 1


def main():
    parser = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        '--out',
        type=Path,
        default=None,
        help='Write report to file (default: stdout only)',
    )
    parser.add_argument(
        '--selftest',
        action='store_true',
        help='Run self-test with embedded sample APL',
    )
    parser.add_argument(
        '--branch',
        default='midnight',
        help='SimulationCraft branch to fetch (default: midnight)',
    )
    parser.add_argument(
        '--timeout',
        type=int,
        default=10,
        help='Network timeout in seconds (default: 10)',
    )

    args = parser.parse_args()

    if args.selftest:
        return selftest()

    # Determine paths
    script_dir = Path(__file__).parent
    repo_root = script_dir.parent
    rules_lua = repo_root / 'OutlawAssist' / 'data' / 'rules.lua'

    if not rules_lua.exists():
        print(f"Error: rules.lua not found at {rules_lua}", file=sys.stderr)
        return 1

    # Fetch SimulationCraft profile
    try:
        profile_content = fetch_simc_profile(branch=args.branch, timeout=args.timeout)
    except urllib.error.URLError as e:
        print(f"Network error: {e}", file=sys.stderr)
        return 2
    except Exception as e:
        print(f"Error fetching profile: {e}", file=sys.stderr)
        return 1

    if profile_content is None:
        print("Error: Could not fetch SimulationCraft profile from any branch/path", file=sys.stderr)
        return 2

    # Parse APL and extract rules
    apl_actions = parse_apl_actions(profile_content)
    rule_names = extract_rule_names(rules_lua)

    # Generate report
    report = generate_report(apl_actions, rule_names)

    # Write to stdout
    print(report)

    # Write to file if requested
    if args.out:
        with open(args.out, 'w', encoding='utf-8') as f:
            f.write(report)
        print(f"\nReport written to {args.out}", file=sys.stderr)

    return 0


if __name__ == '__main__':
    sys.exit(main())
