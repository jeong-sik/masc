#!/usr/bin/env python3
"""Run offline controls, retaining only typed outcomes and setup categories publicly."""
import argparse
from enum import Enum
import json
from pathlib import Path
import subprocess
import tempfile


class Outcome(Enum):
    """The probe's --control-result outcome (control_outcome in the probe)."""
    PASSED = "passed"
    SETUP_REFUSED = "setup_refused"
    INTERNAL_ERROR = "internal_error"


# The exit status the probe pairs with each outcome.
OUTCOME_EXIT = {Outcome.PASSED: 0, Outcome.SETUP_REFUSED: 2, Outcome.INTERNAL_ERROR: 3}


def setup_reasons(binary: Path) -> "frozenset[str] | None":
    """The setup categories the probe itself lists, or None when it cannot say."""
    try:
        listed = subprocess.run([str(binary.resolve()), "--list-setup-reasons"],
                                capture_output=True, check=False)
    except OSError:
        return None
    if listed.returncode != 0:
        return None
    # The list is the probe's last line; anything a library printed first is ignored.
    lines = [line for line in listed.stdout.splitlines() if line.strip()]
    if not lines:
        return None
    try:
        reasons = json.loads(lines[-1])
    except ValueError:
        return None
    if not isinstance(reasons, list) or not all(isinstance(reason, str) for reason in reasons):
        return None
    return frozenset(reasons)


def reading_of(result_path: Path, code: int, reasons: "frozenset[str] | None") -> "tuple[bool, str]":
    """(passed, category) from one control's result file. Library output is never consulted."""
    try:
        result = json.loads(result_path.read_text())
    except (OSError, ValueError):
        return False, "control_result_missing"
    if not isinstance(result, dict):
        return False, "control_result_invalid"
    try:
        outcome = Outcome(result.get("outcome"))
    except ValueError:
        return False, "control_result_invalid"
    if OUTCOME_EXIT[outcome] != code:
        return False, "control_result_contradicts_exit"
    if outcome is Outcome.PASSED:
        return True, "passed"
    if outcome is Outcome.INTERNAL_ERROR:
        return False, "internal_error"
    if reasons is None:
        return False, "setup_reasons_unavailable"
    reason = result.get("reason")
    if isinstance(reason, str) and reason in reasons:
        return False, reason
    return False, "control_result_invalid"


def run_controls(binary: Path, fixtures: Path, config: Path, output: Path) -> int:
    controls = [
        ("fixture_validators", ["--self-test", "--fixtures", str(fixtures)]),
        ("configuration_publication", ["--config-publication-self-test", "--config", str(config)]),
    ]
    reasons = setup_reasons(binary)
    readings = []
    # Library output can contain configuration details. Never copy it into the
    # artifact or console; the receipt admits the typed result file only.
    with tempfile.TemporaryDirectory(prefix="stagehand-private-controls-") as private:
        for name, args in controls:
            stdout = Path(private) / (name + ".stdout")
            stderr = Path(private) / (name + ".stderr")
            result_path = Path(private) / (name + ".result.json")
            try:
                with stdout.open("wb") as out, stderr.open("wb") as err:
                    result = subprocess.run(
                        [str(binary.resolve()), *args, "--control-result", str(result_path)],
                        stdout=out, stderr=err, check=False)
                code = result.returncode
                passed, category = reading_of(result_path, code, reasons)
            except OSError:
                code, passed, category = None, False, "control_execution_unavailable"
            readings.append({"name": name, "status": "passed" if passed else "failed",
                             "exit_code": code, "category": category})
    receipt = {"schema_version": 1, "provider_execution": "not_run_in_ci", "controls": readings}
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(receipt, indent=2) + "\n")
    for reading in readings:
        print(f"{reading['name']}: {reading['status']} ({reading['category']}, exit={reading['exit_code']})")
    return 0 if all(row["status"] == "passed" for row in readings) else 1


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--fixtures", type=Path, required=True)
    parser.add_argument("--config", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    raise SystemExit(run_controls(args.binary, args.fixtures, args.config, args.output))
