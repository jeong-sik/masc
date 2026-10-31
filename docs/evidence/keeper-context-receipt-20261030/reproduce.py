#!/usr/bin/env python3
"""Compile a fresh isolated receipt probe, without changing retained samples."""
import hashlib
from pathlib import Path
import subprocess
import sys

if len(sys.argv) != 3:
    raise SystemExit("usage: reproduce.py NEW_OUTPUT_DIRECTORY SOURCE_COMMIT")

root = Path(subprocess.check_output(["git", "rev-parse", "--show-toplevel"], text=True).strip())
out = Path(sys.argv[1])
if not out.is_absolute():
    out = root / out
if out.exists():
    raise SystemExit("output directory already exists")
out.mkdir(parents=True)
commit = sys.argv[2]
record = root / "docs/evidence/keeper-context-receipt-20261030"

sources = [
    "packages/agent_core/lib/digest/agent_core_digest_slices.ml",
    "packages/agent_core/lib/digest/agent_core_sha256.mli",
    "packages/agent_core/lib/digest/agent_core_sha256.ml",
    "lib/keeper/keeper_context_layers.mli",
    "lib/keeper/keeper_context_layers.ml",
    "lib/keeper/keeper_context_assembly.mli",
    "lib/keeper/keeper_context_assembly.ml",
    "lib/keeper/keeper_run_tools_hook_accumulator.mli",
    "lib/keeper/keeper_run_tools_hook_accumulator.ml",
]
expected = {
    "lib/keeper/keeper_context_assembly.ml": "3999e935958d599e93ea928ecd8ccb426200528de4a4188cbf49ff1f75e80198",
    "lib/keeper/keeper_run_tools_hook_accumulator.ml": "39f5329360cf1036781178b7af991bb3a0f1924d4481b1f81216bd30f6672529",
}
for path in sources:
    raw = subprocess.check_output(["git", "-C", str(root), "show", f"{commit}:{path}"])
    if path in expected and hashlib.sha256(raw).hexdigest() != expected[path]:
        raise SystemExit(f"unexpected source bytes: {path}")
    (out / Path(path).name).write_bytes(raw)

stubs = {
    "prompt_block_id.ml": """type t = Keeper_instructions | Dynamic_context | Active_goals | Completion_authority | Admitted_scheduled_input | Temporal_summary | Memory_os_recall | Librarian_working_context | Recalled_memory | Recalled_memory_status | Operator_note | Skill_compositions
let equal = (=)
let to_string _ = "stub"
""",
    "keeper_types.ml": "",
    "keeper_meta_contract.ml": "type keeper_meta = unit\n",
    "keeper_types_profile.ml": "",
    "keeper_agent_tool_surface.ml": """type turn_lane = Lane_text_only
type tool_surface_metrics = { turn_lane : turn_lane; config_root : string; runtime_config_path : string option }
""",
    "keeper_agent_result.ml": """type tool_call_detail = unit
type wire_prompt_tokens = { cache_n : int; prompt_n : int }
""",
    "keeper_execution_receipt.ml": "type completion_contract_result = Completion_observation_unknown\n",
    "keeper_contract_classifier.ml": "type actionable_signal = unit\n",
    "turn_record.ml": "type prompt_block = unit\n",
    "agent_core.ml": """module Types = struct
 type timings = { cache_n : int option; prompt_n : int option }
 type telemetry = { timings : timings option }
 type api_response = { telemetry : telemetry option }
end
""",
    "masc_test_deps.ml": "let meta_of_json_fixture _ = Ok ()\n",
}
for name, text in stubs.items():
    (out / name).write_text(text)

test = subprocess.check_output(
    ["git", "-C", str(root), "show", f"{commit}:test/test_keeper_turn_outcome.ml"], text=True
)
start = test.index("let test_extra_context_receipt_follows_latest_assembly () =")
end = test.index("\n;;", start) + len("\n;;")
test = test[start:end].replace("Masc.Keeper_", "Keeper_")
(out / "focused_test.ml").write_text(
    'open Alcotest\n' + test + '\nlet () = test_extra_context_receipt_follows_latest_assembly (); print_endline "keeper receipt test PASS"\n'
)
(out / "receipt_bench.ml").write_bytes((record / "receipt_bench.ml.txt").read_bytes())

common = [
    "agent_core_digest_slices.ml", "agent_core_sha256.mli", "agent_core_sha256.ml",
    "prompt_block_id.ml", "keeper_context_layers.mli", "keeper_context_layers.ml",
    "keeper_context_assembly.mli", "keeper_context_assembly.ml",
]
focused = [
    "keeper_types.ml", "keeper_meta_contract.ml", "keeper_types_profile.ml",
    "keeper_agent_tool_surface.ml", "keeper_agent_result.ml", "keeper_execution_receipt.ml",
    "keeper_contract_classifier.ml", "turn_record.ml", "agent_core.ml", "masc_test_deps.ml",
    "keeper_run_tools_hook_accumulator.mli", "keeper_run_tools_hook_accumulator.ml", "focused_test.ml",
]
subprocess.run(["ocamlfind", "ocamlopt", "-package", "digestif.c,yojson,alcotest", "-linkpkg",
                *common, *focused, "-o", "focused_test"], cwd=out, check=True)
with (out / "focused.txt").open("w") as target:
    subprocess.run([str(out / "focused_test")], stdout=target, cwd=out, check=True)
subprocess.run(["ocamlfind", "ocamlopt", "-package", "digestif.c,yojson,unix", "-linkpkg",
                *common, "receipt_bench.ml", "-o", "receipt_bench"], cwd=out, check=True)
with (out / "bench.csv").open("w") as target:
    subprocess.run([str(out / "receipt_bench")], stdout=target, cwd=out, check=True)
print(f"Fresh results: {out}")
