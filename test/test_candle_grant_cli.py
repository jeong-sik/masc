#!/usr/bin/env python3
"""Black-box test for the masc_candle_grant operator CLI.

Drives the built binary against a scratch base path: a grant appends one
row and prints its receipt, a same-(keeper, reason) retype is refused,
and invalid arguments exit 1 without touching the ledger.
"""

import os
import subprocess
import sys
import tempfile

CANDLE_TOML = """half_life = "off"
[payout]
weight_max = 1
deduction_rate = 0
deduction_floor = 1000
share_rounding = "largest_remainder"
remainder_tie_break = "name_ascending"
deduction_rounding = "down"
[payout.grade_criteria]
trivial = "Minor adjustment"
small = "Bounded change"
medium = "Connected feature"
large = "Cross-feature work"
epic = "System outcome"
[payout.grades_milli]
trivial = 100
small = 700
medium = 1000
large = 1000
epic = 1000
"""


def run(exe, base, *args):
    return subprocess.run(
        [exe, "--base", base, *args],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        timeout=60,
    )


def ledger_rows(base):
    path = os.path.join(base, ".masc", "candle-ledger.jsonl")
    if not os.path.exists(path):
        return []
    with open(path, encoding="utf-8") as handle:
        return [line for line in handle.read().splitlines() if line.strip()]


def main(exe):
    if not (os.path.isfile(exe) and os.access(exe, os.X_OK)):
        raise SystemExit(f"no executable CLI at {exe}")
    with tempfile.TemporaryDirectory(prefix="candle-grant-cli-") as base:
        config_dir = os.path.join(base, ".masc", "config")
        os.makedirs(config_dir)
        with open(os.path.join(config_dir, "candle.toml"), "w", encoding="utf-8") as handle:
            handle.write(CANDLE_TOML)

        first = run(exe, base, "--keeper", "alpha", "--amount-milli", "10",
                     "--reason", "welcome gift")
        if first.returncode != 0:
            raise AssertionError(f"grant failed: {first.stderr!r}")
        if "granted 10 milli-Candle to alpha (welcome gift); balance 10" not in first.stdout:
            raise AssertionError(f"receipt missing: {first.stdout!r}")
        rows = ledger_rows(base)
        if len(rows) != 2 or '"kind":"granted"' not in rows[1]:
            raise AssertionError(f"expected policy + granted rows: {rows!r}")

        dup = run(exe, base, "--keeper", "alpha", "--amount-milli", "10",
                   "--reason", "welcome gift")
        if dup.returncode != 1 or "already granted" not in dup.stderr:
            raise AssertionError(f"duplicate must refuse: {dup.returncode} {dup.stderr!r}")
        if len(ledger_rows(base)) != 2:
            raise AssertionError("refused duplicate appended a row")

        second = run(exe, base, "--keeper", "alpha", "--amount-milli", "5",
                       "--reason", "second gift")
        if second.returncode != 0 or "balance 15" not in second.stdout:
            raise AssertionError(f"second reason must accumulate: {second.stdout!r}")

        bad_amounts = ["0", "-5", "0x10", "1_0", "ten"]
        for raw in bad_amounts:
            bad = run(exe, base, "--keeper", "alpha", "--amount-milli", raw,
                       "--reason", "welcome gift")
            if bad.returncode != 1 or "--amount-milli" not in bad.stderr:
                raise AssertionError(f"amount {raw!r} must refuse: {bad.stderr!r}")

        blank = run(exe, base, "--keeper", "alpha", "--amount-milli", "10",
                      "--reason", "   ")
        if blank.returncode != 1 or "blank" not in blank.stderr:
            raise AssertionError(f"blank reason must refuse: {blank.stderr!r}")

        bad_keeper = run(exe, base, "--keeper", "has space!", "--amount-milli", "10",
                           "--reason", "welcome gift")
        if bad_keeper.returncode != 1 or "--keeper" not in bad_keeper.stderr:
            raise AssertionError(f"bad keeper must refuse: {bad_keeper.stderr!r}")

        trailing = subprocess.run(
            [exe, "--base", base, "--keeper"],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=60)
        if trailing.returncode != 1 or "needs a value" not in trailing.stderr:
            raise AssertionError(f"trailing flag must name the miss: {trailing.stderr!r}")

        unknown = run(exe, base, "--frobnicate")
        if unknown.returncode != 1 or "unknown argument" not in unknown.stderr:
            raise AssertionError(f"unknown flag must refuse: {unknown.stderr!r}")

        missing = run(exe, base, "--keeper", "alpha")
        if missing.returncode != 1 or "--amount-milli is required" not in missing.stderr:
            raise AssertionError(f"missing amount must refuse: {missing.stderr!r}")

        if len(ledger_rows(base)) != 3:
            raise AssertionError(f"refusals must not append: {ledger_rows(base)!r}")

        help_text = subprocess.run(
            [exe, "--help"], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, timeout=60)
        if help_text.returncode != 0 or "Usage: masc_candle_grant" not in help_text.stdout:
            raise AssertionError("--help must print usage")
    print("candle grant cli: PASS")


if __name__ == "__main__":
    main(os.path.abspath(sys.argv[1]))
