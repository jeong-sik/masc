#!/usr/bin/env python3
"""Direct env reads stay where the config loader cannot reach.

`Env_config_core` parses the environment once at boot. A caller that reads
`Sys.getenv` itself gets a second answer: the boot-time TOML overrides do not
apply, and two sites can disagree about the same key (#29353).

Some sites cannot use the loader. `masc.config` depends on `masc_core`,
`masc_log`, `fs_compat` and `string_util`, so those reading it back would be
a dependency cycle. That set is not written down here — it is read from
`dune describe`, so it follows the build rather than a hand-maintained list.

Everything above that floor is a site the loader could serve, and the count
is held at its current level.
"""

from __future__ import annotations

import json
import pathlib
import re
import subprocess
import sys

REPO = pathlib.Path(__file__).resolve().parents[2]
BASELINE = REPO / "scripts" / "env-read-baseline.json"
CONFIG_LIB = "masc.config"
NEEDLE = "Sys.getenv"


def describe() -> str:
    result = subprocess.run(
        ["dune", "describe", "--root", "."],
        cwd=REPO,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        sys.exit(f"FAIL: dune describe failed:\n{result.stderr[:2000]}")
    return result.stdout


def library_graph(text: str):
    """(name -> requires) and (name -> source_dir) for local libraries."""
    uid_to_name: dict[str, str] = {}
    requires: dict[str, list[str]] = {}
    source_dir: dict[str, str] = {}
    local: dict[str, bool] = {}
    pattern = re.compile(
        r"\(name ([a-zA-Z0-9_.]+)\)\s*\n?\s*\(uid (\w+)\)\s*\n?\s*"
        r"\(local (\w+)\)\s*\n?\s*\(requires\s*\(([^)]*)\)\s*\)\s*\n?\s*"
        r"\(source_dir ([^)]*)\)"
    )
    for match in pattern.finditer(text):
        name, uid, is_local, reqs, src = match.groups()
        uid_to_name[uid] = name
        requires[name] = reqs.split()
        source_dir[name] = src.strip()
        local[name] = is_local == "true"
    return uid_to_name, requires, source_dir, local


def config_floor(uid_to_name, requires, local) -> set[str]:
    """Every local library the config loader itself depends on."""
    if CONFIG_LIB not in requires:
        sys.exit(f"FAIL: {CONFIG_LIB} not found in dune describe output")
    seen: set[str] = set()
    stack = [CONFIG_LIB]
    while stack:
        for uid in requires.get(stack.pop(), []):
            name = uid_to_name.get(uid, uid)
            if name in requires and name not in seen and name != CONFIG_LIB:
                seen.add(name)
                stack.append(name)
    return {name for name in seen if local.get(name)}


# dune describe reports source_dir under the build context. The build tree
# holds a copy, so counting there reads whatever was last built rather than
# what is in the checkout — a newly added read did not register at all.
BUILD_PREFIX = "_build/default/"


def repo_dir(source_dir: str) -> pathlib.Path:
    if source_dir.startswith(BUILD_PREFIX):
        source_dir = source_dir[len(BUILD_PREFIX) :]
    return REPO / source_dir


def count_reads(source_dir: dict[str, str], names) -> int:
    seen_dirs: set[str] = set()
    total = 0
    for name in names:
        directory = repo_dir(source_dir[name])
        if not directory.is_dir() or str(directory) in seen_dirs:
            continue
        seen_dirs.add(str(directory))
        for path in directory.glob("*.ml"):
            total += path.read_text(encoding="utf-8", errors="replace").count(NEEDLE)
    return total


def main() -> int:
    print("=== direct env reads above the config floor ===")
    text = describe()
    uid_to_name, requires, source_dir, local = library_graph(text)
    floor = config_floor(uid_to_name, requires, local)
    above = {n for n, is_local in local.items() if is_local and n not in floor}

    below_count = count_reads(source_dir, floor)
    above_count = count_reads(source_dir, above)

    print(f"  config floor: {len(floor)} local librar(ies), {below_count} read(s)")
    print(f"  above:        {len(above)} local librar(ies), {above_count} read(s)")

    if not BASELINE.exists():
        sys.exit(f"FAIL: {BASELINE.relative_to(REPO)} is missing")
    baseline = json.loads(BASELINE.read_text(encoding="utf-8"))
    ceiling = baseline["direct_env_reads_above_config_floor"]

    if above_count > ceiling:
        print()
        print(f"FAIL: {above_count} direct env read(s) above the config floor, "
              f"baseline {ceiling}.")
        print("      A library that can depend on masc.config should read the")
        print("      parsed value from Env_config_core, so a boot-time TOML")
        print("      override applies and two sites cannot disagree.")
        return 1

    if above_count < ceiling:
        print()
        print(f"IMPROVED: {above_count} vs baseline {ceiling} — lower the ceiling "
              f"in {BASELINE.relative_to(REPO)}.")

    print()
    print(f"PASS: {above_count} read(s) above the floor, ceiling {ceiling}.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
