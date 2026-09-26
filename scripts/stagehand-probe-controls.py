#!/usr/bin/env python3
"""Run offline controls, retaining only fixed diagnostic categories publicly."""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile


SETUP_CATEGORIES = frozenset({
    "fixture_count_invalid", "fixture_protocol_invalid", "validation_self_test_failed",
    "runtime_config_rejected", "runtime_catalog_models_missing",
    "registry_publication_rejected", "registry_unavailable",
    "lane_requires_exactly_two_http_slots_no_cli", "lane_model_capability_refused",
    "lane_declared_slots_not_both_admitted", "publication_test_slots_not_distinct",
    "probe_input_or_output_unavailable",
})


def run_controls(binary: Path, fixtures: Path, config: Path, output: Path) -> int:
    controls = [
        ("fixture_validators", ["--self-test", "--fixtures", str(fixtures)],
         b"fixture validators: passed"),
        ("configuration_publication", ["--config-publication-self-test", "--config", str(config)],
         b"runtime configuration and Exact lane publication: passed (no model callbacks)"),
    ]
    readings = []
    # Library output can contain configuration details. Never copy it into the
    # artifact or console; the receipt admits exact fixed lines only.
    with tempfile.TemporaryDirectory(prefix="stagehand-private-controls-") as private:
        for name, args, expected in controls:
            stdout = Path(private) / (name + ".stdout")
            stderr = Path(private) / (name + ".stderr")
            try:
                with stdout.open("wb") as out, stderr.open("wb") as err:
                    result = subprocess.run([str(binary.resolve()), *args], stdout=out, stderr=err,
                                            check=False)
                code = result.returncode
                if code == 0:
                    category = "passed" if expected in stdout.read_bytes().splitlines() else "success_marker_missing"
                else:
                    lines = stderr.read_bytes().splitlines()
                    last = lines[-1].decode("ascii", "replace") if lines else ""
                    category = last if code == 2 and last in SETUP_CATEGORIES else "unclassified_control_failure"
            except OSError:
                code, category = None, "control_execution_unavailable"
            readings.append({"name": name, "status": "passed" if category == "passed" else "failed",
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
