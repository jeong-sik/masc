"""Run the original exact-source PPTX unittest once; skipped is never PASS."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import unittest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-root", type=Path, required=True)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--presentation-base", type=Path, required=True)
    parser.add_argument("--receipt", type=Path, required=True)
    parser.add_argument("--expected-source", required=True)
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    root = args.source_root.resolve()
    binary = args.binary.resolve(strict=True)
    base = args.presentation_base.resolve(strict=True)
    source_sha = subprocess.check_output(
        ["git", "-C", str(root), "rev-parse", "HEAD"], text=True
    ).strip()
    if source_sha != args.expected_source:
        parser.error(f"source mismatch: {source_sha} != {args.expected_source}")
    fixture = base / "inputs/presentation.pptx"
    expected_file = base / "inputs/expected.json"
    expected = json.loads(expected_file.read_text())
    fixture_sha = hashlib.sha256(fixture.read_bytes()).hexdigest()
    if fixture_sha != expected["sha256"]:
        parser.error("prepared fixture hash differs from expected.json")
    test_file = root / "test/test_operator_media_inspection.py"
    spec = importlib.util.spec_from_file_location("exact_operator_media", test_file)
    if spec is None or spec.loader is None:
        parser.error("cannot load the exact test file")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    module.BINARY = str(binary)
    module.PRESENTATION_BASE = str(base)
    # The original skipUnless was evaluated before these CLI inputs existed.
    # Match its __main__ behavior now that both prepared inputs are confirmed.
    case_class = module.OperatorInspection
    case_class.__unittest_skip__ = False
    suite = unittest.TestSuite([
        case_class("test_pptx_uses_managed_parser_and_returns_every_slide")
    ])
    receipt = {
        "source_sha": source_sha,
        "binary_sha256": hashlib.sha256(binary.read_bytes()).hexdigest(),
        "fixture_sha256": fixture_sha,
        "test_source_sha256": hashlib.sha256(test_file.read_bytes()).hexdigest(),
        "selected_cases": suite.countTestCases(),
        "result": "not_run",
    }
    if args.dry_run:
        print(json.dumps(receipt))
        return 0
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    passed = result.wasSuccessful() and result.testsRun == 1 and not result.skipped
    receipt.update(
        result="PASS" if passed else "FAIL",
        tests_run=result.testsRun,
        skipped=len(result.skipped),
        failures=len(result.failures),
        errors=len(result.errors),
    )
    args.receipt.parent.mkdir(parents=True, exist_ok=True)
    args.receipt.write_text(json.dumps(receipt, indent=2) + "\n")
    print(json.dumps(receipt))
    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
