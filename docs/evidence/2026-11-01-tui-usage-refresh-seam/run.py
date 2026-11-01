#!/usr/bin/env python3
"""Copy exact Usage key arm and complete scoped launch; execute request decisions."""
import hashlib
import json
import argparse
from datetime import datetime, timezone
from pathlib import Path
import subprocess

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
BASELINE_COMMIT = "61b4d5531d44cb780dff64158fdbf7d641f1658f"
PRODUCTION_SOURCE_COMMIT = "ea7f321488112e20f09edec5a229d817b320dd98"
COMPARISON_COMMIT = "74756f56e61a92d8d64250e9ed7552ad165645c4"
checkout_commit = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=REPO).decode().strip()
captured_at_utc = datetime.now(timezone.utc).isoformat()
parser = argparse.ArgumentParser()
parser.add_argument("--output", type=Path, default=Path("artifacts/p3-feature-detail-20261101/usage-seam") /
    datetime.now(timezone.utc).strftime("run-%Y%m%dT%H%M%S.%fZ"))
output = parser.parse_args().output
OUT = output if output.is_absolute() else REPO / output
OUT.mkdir(parents=True, exist_ok=False)
manifest = []

def source(commit, path):
    return subprocess.check_output(["git", "show", commit + ":" + path], cwd=REPO).decode()

def sha(body):
    return hashlib.sha256(body.encode()).hexdigest()

def extract(commit, path, start, stop):
    original = source(commit, path)
    first = original.index(start)
    last = original.index(stop, first)
    body = original[first:last]
    entry = dict(commit=commit, path=path, lines=[original[:first].count("\n")+1,
        original[:last].count("\n")], sha256=sha(body), start=start, stop=stop)
    if commit == PRODUCTION_SOURCE_COMMIT:
        for role, revision in [("comparison_commit", COMPARISON_COMMIT), ("checkout_commit", checkout_commit)]:
            compared = source(revision, path)
            begin = compared.index(start)
            end = compared.index(stop, begin)
            assert body == compared[begin:end], role + " changed the copied source span: " + start
            entry["identical_at_" + role] = revision
    manifest.append(entry)
    return body

app = "bin/masc_tui.ml"
types = "bin/masc_tui_types.ml"
function_start = "let start_http_scoped_refresh state"
function_stop = "\nlet start_scoped_refresh_followup"
arm_start = '        | Some ("w" | "W")\n'
arm_stop = "       (* In chat, printable keys"
results = {}
for variant in ["baseline", "candidate", "miswired-needs"]:
    commit = BASELINE_COMMIT if variant == "baseline" else PRODUCTION_SOURCE_COMMIT
    directory = OUT / variant
    directory.mkdir(exist_ok=True)
    foundation = (HERE / "types-prefix.ml").read_text()
    for start, stop in [
        ("module Surface_read_source = struct", "\n(** Logical full-refresh readers"),
        ("type surface_needs = {", "\n(* Each datum is read"),
        ("let surface_needs_any needs", "\n(* Full and navigation reads"),
        ("module Surface_read_order : sig", "\n(* Dispatch is intent"),
        ("module Http_refresh_order = struct", "\n(** Display-only result"),
        ("let server_is_booting\n", "\ntype workspace_authority"),
        ("let server_workspace_matches ~expected", "\n(* What the paths alone say")]:
        foundation += "\n" + extract(commit, types, start, stop)
    foundation += "\n" + (HERE / "state-adapter.ml").read_text()
    if variant != "baseline":
        foundation += "\n" + extract(commit, types, "let cycle_usage_history_window", "\nlet usage_history_reading")
    (directory / "masc_tui_types.ml").write_text(foundation)
    launch = extract(commit, app, function_start, function_stop)
    arm = extract(commit, app, arm_start, arm_stop)
    if variant == "miswired-needs":
        original = arm
        arm = arm.replace("~mailbox:async_messages ~needs", "~mailbox:async_messages ~needs:nothing", 1)
        assert arm != original, "mutation did not reach the actual arm"
        manifest.append(dict(variant=variant, derivative="actual arm passes no read needs",
                             original_sha256=sha(original), sha256=sha(arm)))
    wrapper = """let handle_key state ~server_peer_host ~http_scoped_refresh_inflight
    ~http_refresh_inflight ~scoped_refresh_followup ~async_messages key =
  match key with
""" + arm + "\n  | None | Some _ -> ()\n"
    (directory / "seam.ml").write_text((HERE / "seam-adapters.ml").read_text() + "\n" + launch + "\n" + wrapper)
    (directory / "checks.ml").write_text((HERE / "checks.ml").read_text())
    build = subprocess.run(["ocamlc", "-o", "seam-check", "masc_tui_types.ml", "seam.ml", "checks.ml"],
        cwd=directory, text=True, capture_output=True)
    (directory / "compile.txt").write_text(build.stdout + build.stderr)
    if build.returncode:
        raise SystemExit(variant + " compile failed:\n" + build.stdout + build.stderr)
    argv = ["./seam-check"] + ([] if variant == "candidate" else ["--core"])
    ran = subprocess.run(argv, cwd=directory, text=True, capture_output=True)
    (directory / "result.txt").write_text(ran.stdout + ran.stderr)
    results[variant] = ran.returncode
    print(variant, "exit", ran.returncode, "\n" + ran.stdout + ran.stderr)
    manifest.append(dict(variant=variant, generated_sha256={name:sha((directory/name).read_text())
        for name in ["masc_tui_types.ml", "seam.ml", "checks.ml"]}))

(OUT / "source-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
(OUT / "result.json").write_text(json.dumps(dict(baseline_commit=BASELINE_COMMIT,
    production_source_commit=PRODUCTION_SOURCE_COMMIT, comparison_commit=COMPARISON_COMMIT,
    checkout_commit=checkout_commit, captured_at_utc=captured_at_utc,
    checkout_source_span_count=len({(entry["path"], entry["start"], entry["stop"])
        for entry in manifest if entry.get("identical_at_checkout_commit") == checkout_commit}),
    helper_sha256={name:sha((HERE/name).read_text()) for name in
        ["run.py", "types-prefix.ml", "state-adapter.ml", "seam-adapters.ml", "checks.ml"]},
    exit_codes=results,
    expected={"baseline":1,"candidate":0,"miswired-needs":1}), indent=2) + "\n")
print("Output:", OUT)
raise SystemExit(0 if results == {"baseline":1,"candidate":0,"miswired-needs":1} else 1)
