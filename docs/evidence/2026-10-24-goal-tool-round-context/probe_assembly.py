"""Compile exact pure request-assembly sources; no Dune or SDK/network claim."""
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[3]
OUT = Path(__file__).resolve().parent
modules = ["lib/types/prompt_block_id", "lib/keeper/keeper_context_layers", "lib/keeper/keeper_context_assembly"]
source = (ROOT / "lib/keeper/keeper_run_prompt.ml").read_text()
start = source.index("let assemble_extra_system_context =")
end = source.index("(* See the mli: a position question", start)
fragment = "type extra_system_context_assembly = Keeper_context_assembly.t\n" + source[start:end]
probe = r'''module P = Prompt_block_id
module L = Keeper_context_layers
module A = Keeper_context_assembly
module R = Bounded_request_context
let checks = ref 0
let check label result = if not result then failwith label else (incr checks; Printf.printf "PASS %s\n" label)
let contains needle text = Astring.String.is_infix ~affix:needle text
let text value = Option.value ~default:"" value.A.extra_system_context
let world = L.singleton L.Active_goals "GOAL-ID CURRENT-REV MEASUREMENT-ID"
  |> fun goals -> L.append_unattributed goals L.Direct_turn "\nGATE TASK LANE OWNER"
let blocks = [P.Dynamic_context,L.text world;P.Temporal_summary,"CLOCK"]
let first = R.assemble_request_context ~post_tool_round:false ~previous_assembly:None
  ~dynamic_context_partition:(Some world) ~existing_extra_system_context:None ~blocks
let () =
  check "first request retains Goal" (contains "CURRENT-REV" (text first));
  check "first request retains other world" (contains "GATE TASK LANE OWNER" (text first));
  check "Goal has exactly one issued block" (List.filter (fun (id,_) -> P.equal id P.Active_goals) first.blocks = [P.Active_goals,"GOAL-ID CURRENT-REV MEASUREMENT-ID"]);
  check "Goal is absent from remaining Dynamic block" (not (contains "GOAL-ID" (List.assoc P.Dynamic_context first.blocks)));
  let second = R.assemble_request_context ~post_tool_round:true ~previous_assembly:(Some first)
      ~dynamic_context_partition:(Some (L.unattributed L.Unprojected_input "FOREIGN-REV"))
      ~existing_extra_system_context:None ~blocks in
  List.iter (fun marker -> check ("second request retains "^marker) (contains marker (text second)))
    ["GOAL-ID";"CURRENT-REV";"MEASUREMENT-ID"];
  List.iter (fun marker -> check ("second request omits "^marker) (not (contains marker (text second))))
    ["GATE";"TASK";"LANE";"OWNER";"CLOCK";"FOREIGN-REV"];
  let third = R.assemble_request_context ~post_tool_round:true ~previous_assembly:(Some second)
      ~dynamic_context_partition:None ~existing_extra_system_context:None ~blocks:[] in
  check "later request keeps exact issued Goal" (text third = "GOAL-ID CURRENT-REV MEASUREMENT-ID");
  let empty = R.assemble_request_context ~post_tool_round:true ~previous_assembly:None
      ~dynamic_context_partition:None ~existing_extra_system_context:None ~blocks in
  check "another turn borrows no Goal snapshot" (empty.extra_system_context = None);
  let mismatch = R.assemble_request_context ~post_tool_round:false ~previous_assembly:None
      ~dynamic_context_partition:(Some world) ~existing_extra_system_context:None
      ~blocks:[P.Dynamic_context,"UNATTRIBUTED"] in
  check "mismatched renderer evidence never promotes a Goal block"
    (not (List.mem_assoc P.Active_goals mismatch.blocks));
  check "unmatched source bytes remain intact" (text mismatch = "UNATTRIBUTED");
  Printf.printf "%d exact-source assembly checks passed\n" !checks
'''
with tempfile.TemporaryDirectory(prefix="masc-goal-assembly-source-") as temporary:
    directory = Path(temporary)
    sources = []
    records = []
    for module in modules:
        for extension in (".mli", ".ml"):
            path = ROOT / (module + extension)
            data = path.read_bytes()
            destination = directory / path.name
            destination.write_bytes(data)
            sources.append(destination.name)
            records.append({"path":str(path.relative_to(ROOT)),"sha256":hashlib.sha256(data).hexdigest()})
    (directory / "bounded_request_context.ml").write_text(fragment)
    (directory / "probe.ml").write_text(probe)
    command = ["ocamlfind", "ocamlc", "-package", "yojson,digestif.ocaml,astring", "-linkpkg", *sources,
               "bounded_request_context.ml", "probe.ml", "-o", "probe"]
    built = subprocess.run(command,cwd=directory,text=True,capture_output=True)
    if built.returncode:
        print(built.stdout+built.stderr)
        raise SystemExit(built.returncode)
    ran = subprocess.run([str(directory / "probe")],cwd=directory,text=True,capture_output=True)
    (OUT / "assembly-check.txt").write_text(ran.stdout+ran.stderr)
    (OUT / "assembly-check.json").write_text(json.dumps({"scope":"whole pure Prompt_block_id/Context_layers/Context_assembly plus exact request-assembly function slice; no producer hook, SDK HTTP dispatch, native receiver suite or live Keeper run", "source_modules":records,"request_function_fragment_sha256":hashlib.sha256(fragment.encode()).hexdigest(),"compile_exit":built.returncode,"run_exit":ran.returncode},indent=2)+"\n")
    print(ran.stdout+ran.stderr)
    raise SystemExit(ran.returncode)
