"""Run real validate-stores binaries against the same queue fixtures.

The test-only counterpart is compiled from bin/deployment_preflight_helper.ml.
Its sole mutation omits Keeper_event_queue from validate_stores enumeration.
No command response is stubbed, and no production bypass is introduced.
"""

import argparse
import difflib
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def generate(source_path, output_path, evidence_path):
    original = source_path.read_text()
    start_marker = "let validate_stores base_path =\n"
    end_marker = "let validate_stores_cmd =\n"
    assert original.count(start_marker) == original.count(end_marker) == 1
    start = original.index(start_marker)
    end = original.index(end_marker, start)
    body = original[start:end]
    anchor = "      D.Id.all\n  in\n"
    assert body.count(anchor) == 1, "expected exactly one validate_stores enumeration"
    replacement = (
        "      (List.filter (fun id -> id <> D.Id.Keeper_event_queue) D.Id.all)\n"
        "  in\n"
    )
    mutated = original[:start] + body.replace(anchor, replacement, 1) + original[end:]
    assert mutated.count(replacement) == 1
    assert mutated.replace(replacement, anchor, 1) == original
    difference = "".join(difflib.unified_diff(
        original.splitlines(keepends=True), mutated.splitlines(keepends=True),
        fromfile="bin/deployment_preflight_helper.ml",
        tofile="test/deployment_preflight_queue_omitted.ml"))
    output_path.write_text(mutated)
    evidence_path.write_text(json.dumps({
        "mutation": "omit only Keeper_event_queue from validate_stores",
        "source_sha256": sha256(original.encode()),
        "mutant_sha256": sha256(mutated.encode()),
        "diff": difference,
    }, indent=2) + "\n")


def invoke(executable, *arguments):
    # Queue paths in these fixtures use the default cluster. Do not inherit a
    # developer's named-cluster setting into a fixture-only subprocess.
    environment = dict(os.environ)
    environment.pop("MASC_CLUSTER_NAME", None)
    result = subprocess.run([str(executable), *arguments], env=environment,
                            text=True, capture_output=True, check=False)
    print(json.dumps({"executable": str(executable), "arguments": arguments,
                      "returncode": result.returncode,
                      "stdout": result.stdout, "stderr": result.stderr}), flush=True)
    return result


def require_queue_refusal(result, case_name):
    assert result.returncode > 0, f"{case_name}: expected queue refusal, got {result.returncode}"
    assert "keeper event queue rows=1 refused=1" in result.stdout, (
        f"{case_name}: failure did not come from the queue decoder")


def run(normal, mutant, evidence_path, source_path, mutant_source_path):
    evidence = json.loads(evidence_path.read_text())
    assert evidence["source_sha256"] == sha256(source_path.read_bytes())
    assert evidence["mutant_sha256"] == sha256(mutant_source_path.read_bytes())
    print(json.dumps(evidence), flush=True)
    for executable in (normal, mutant):
        identity = invoke(executable, "build-commit")
        assert identity.returncode == 0 and identity.stdout.strip()
    names_result = invoke(normal, "durable-filenames")
    assert names_result.returncode == 0
    names = dict(line.split("=", 1) for line in names_result.stdout.splitlines())
    assert set(names) == {"snapshot", "wal"}
    assert all(name == Path(name).name for name in names.values())
    with tempfile.TemporaryDirectory(prefix="queue-preflight-mutation-") as temporary:
        root = Path(temporary).resolve()
        for case_name, filename, contents, refused in (
            ("absent_queue", None, None, False),
            ("empty_wal", names["wal"], b"", False),
            ("malformed_current_queue", names["snapshot"], b"{not-json\n", True),
            ("malformed_wal_without_snapshot", names["wal"], b"{not-json\n", True),
        ):
            base = root / case_name
            keeper = base / ".masc" / "keepers" / "fixture"
            keeper.mkdir(parents=True)
            path = keeper / filename if filename else None
            if path is not None:
                path.write_bytes(contents)
            for label, executable in (("normal", normal), ("queue_omitted", mutant)):
                result = invoke(executable, "validate-stores", "--base-path", str(base))
                if path is not None:
                    assert path.read_bytes() == contents, f"{case_name}: {label} changed queue bytes"
                    print(json.dumps({"case": case_name, "variant": label,
                                      "fixture_sha256": sha256(contents),
                                      "after_sha256": sha256(path.read_bytes())}), flush=True)
                if not refused:
                    assert result.returncode == 0, f"{case_name}: {label} rejected the positive control"
                    print(f"POSITIVE CONTROL: {case_name} {label} accepted", flush=True)
                elif label == "normal":
                    require_queue_refusal(result, case_name)
                    print(f"NORMAL: {case_name} rejected by queue decoder", flush=True)
                else:
                    # A compiler failure, crash or another store refusal is
                    # not evidence that this omission was caught.
                    assert result.returncode == 0, f"{case_name}: mutant did not admit corrupt queue"
                    assert "keeper event queue " not in result.stdout
                    try:
                        require_queue_refusal(result, case_name)
                    except AssertionError as failure:
                        print(f"MUTATION DETECTED: {failure}", flush=True)
                    else:
                        raise AssertionError(f"{case_name}: omission survived the refusal assertion")
    print("queue preflight mutation control: PASS", flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--generate", action="store_true")
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--mutant-source", type=Path, required=True)
    parser.add_argument("--evidence", type=Path, required=True)
    parser.add_argument("--normal", type=Path)
    parser.add_argument("--mutant", type=Path)
    args = parser.parse_args()
    if args.generate:
        generate(args.source, args.mutant_source, args.evidence)
    else:
        assert args.normal is not None and args.mutant is not None
        run(args.normal.resolve(), args.mutant.resolve(), args.evidence,
            args.source, args.mutant_source)
