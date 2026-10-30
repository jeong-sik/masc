#!/usr/bin/env bash
# Every dependency masc.opam declares must be pinned in masc.opam.locked, and
# every first-party SHA the pin script carries must be the one the lock pins.
#
# CI installs with --locked, so a package the lock does not name is a package
# CI does not install: markup was declared, used by lib/markup_document, and
# absent from the lock (#28543). The pin script and the lock also each carry
# the first-party commit SHAs, and nothing checked that they agreed — bumping
# one would have built CI and the keeper sandbox from different code.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

opam_file="masc.opam"
lock_file="masc.opam.locked"
pin_script="scripts/opam-pin-external-deps.sh"

for f in "$opam_file" "$lock_file" "$pin_script"; do
  [ -f "$f" ] || { echo "[opam-lock] FAIL - missing $f"; exit 2; }
done

python3 - "$opam_file" "$lock_file" "$pin_script" <<'PY'
import re, sys

opam_path, lock_path, pin_path = sys.argv[1:4]
opam = open(opam_path, encoding="utf-8").read()
lock = open(lock_path, encoding="utf-8").read()
pin = open(pin_path, encoding="utf-8").read()


def declared(text):
    block = re.search(r"^depends:\s*\[(.*?)^\]", text, re.S | re.M)
    if not block:
        return set()
    names = set()
    for line in block.group(1).split("\n"):
        m = re.match(r'\s*"([A-Za-z][A-Za-z0-9_+\-.]*)"', line)
        if m:
            names.add(m.group(1))
    return names


failures = []

missing = sorted(declared(opam) - declared(lock))
if missing:
    failures.append(
        "these are declared in %s and absent from %s, so --locked would not "
        "install them:\n  %s" % (opam_path, lock_path, "\n  ".join(missing))
    )

# repo -> sha, from the pin script's readonly constants and the URLs using them.
script_pins = {}
for name, sha in re.findall(r'^readonly\s+([A-Z0-9_]+_SHA)="([0-9a-f]{40})"', pin, re.M):
    for repo in re.findall(
        r'https://github\.com/[^/]+/([A-Za-z0-9_.\-]+)\.git#\$\{%s\}' % name, pin
    ):
        script_pins.setdefault(repo, set()).add(sha)

lock_pins = {}
for repo, sha in re.findall(
    r'"git\+https://github\.com/[^/]+/([A-Za-z0-9_.\-]+)\.git#([0-9a-f]{40})"', lock
):
    lock_pins.setdefault(repo, set()).add(sha)

for repo, shas in sorted(script_pins.items()):
    if repo not in lock_pins:
        # The lock only carries repos something depends on. A pin nobody
        # depends on is a separate question, not a disagreement.
        continue
    if shas != lock_pins[repo]:
        failures.append(
            "%s: pin script says %s, lock says %s"
            % (repo, sorted(shas), sorted(lock_pins[repo]))
        )

if failures:
    print("[opam-lock] FAIL")
    for f in failures:
        print("  - %s" % f)
    sys.exit(2)

print(
    "[opam-lock] OK - %d declared deps all pinned; %d shared first-party repo "
    "pin(s) agree" % (len(declared(opam)), len(set(script_pins) & set(lock_pins)))
)
PY
