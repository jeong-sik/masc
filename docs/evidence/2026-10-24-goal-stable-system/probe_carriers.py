"""Run actual pure carrier/request-assembly source; no Keeper/SDK/network claim."""
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[3]
OUT = Path(__file__).resolve().parent
modules = ["lib/types/prompt_block_id", "lib/keeper/keeper_context_layers", "lib/keeper/keeper_context_assembly"]
source = (ROOT / "lib/keeper/keeper_run_prompt.ml").read_text()
fragment = source[source.index("let assemble_extra_system_context ="):source.index("(* See the mli: a position question")]
safe = (ROOT / "lib/core/safe_ops.ml").read_text()
sanitizer = safe[safe.index("let[@inline] is_disallowed_control_char"):safe.index("let rec sanitize_json_utf8")]
probe = r'''module P = Prompt_block_id
module L = Keeper_context_layers
module A = Keeper_context_assembly
module R = Bounded_request_context
let checks = ref 0
let check label result = if not result then failwith label else (incr checks; Printf.printf "PASS %s\n" label)
let contains needle text = Astring.String.is_infix ~affix:needle text
let world = L.singleton L.Active_goals "GOAL-ID CURRENT-REV MEASUREMENT-ID"
  |> fun goals -> L.append_unattributed goals L.Direct_turn "\nGATE TASK LANE OWNER"
let blocks = [P.Dynamic_context,L.text world;P.Temporal_summary,"CLOCK"]
let request ?previous ?partition ?(post=false) ?(base="PRIOR_OVERRIDE") blocks =
  R.assemble_request_context ~base_system_prompt:base ~post_tool_round:post
    ~previous_assembly:previous ~dynamic_context_partition:partition
    ~existing_extra_system_context:None ~blocks
let issued request = match request.A.system_prompt with Some value -> value | None -> failwith "system not issued"
let () =
  let first = request ~partition:world blocks in
  let system = issued first in
  check "system keeps the previous override before the Goal" (system.text = "PRIOR_OVERRIDE\n\nGOAL-ID CURRENT-REV MEASUREMENT-ID");
  check "extra context contains the other world only" (match first.extra_system_context with Some text -> contains "GATE TASK LANE OWNER" text && not (contains "GOAL-ID" text) | None -> false);
  check "extra receipt never claims a Goal span" (not (List.mem_assoc P.Active_goals first.blocks));
  check "logical Goal block is counted once" (List.filter (fun (id,_) -> P.equal id P.Active_goals) (A.logical_blocks first) = [P.Active_goals,"GOAL-ID CURRENT-REV MEASUREMENT-ID"]);
  check "physical system receipt has exact bytes" (system.partition.bytes = String.length system.text);
  check "physical system receipt has exact digest" (system.partition.sha256 = Digestif.SHA256.(digest_string system.text |> to_hex));
  let position = ref 0 in
  List.iter (fun (span : A.span) ->
    check "physical spans are contiguous" (span.offset = !position);
    check "physical span digest matches its exact bytes" (span.sha256 = Digestif.SHA256.(digest_string (String.sub system.text span.offset span.bytes) |> to_hex));
    position := span.offset + span.bytes) system.partition.spans;
  check "physical spans cover the complete system carrier" (!position = String.length system.text);
  check "system receipt names its own carrier" (Yojson.Safe.Util.member "carrier" (A.system_prompt_receipt_to_json system) = `String "system_prompt");
  let second = request ~previous:first ~post:true
      ~partition:(L.unattributed L.Unprojected_input "FOREIGN-REV") blocks in
  check "second system keeps exactly the issued Goal" ((issued second).text = system.text);
  check "post-tool round has no extra User carrier" (second.extra_system_context = None);
  List.iter (fun marker -> check ("stable system omits "^marker)
    (not (contains marker (issued second).text))) ["GATE";"TASK";"LANE";"OWNER";"CLOCK";"FOREIGN-REV"];
  let third = request ~previous:second ~post:true [] in
  check "third request does not accumulate the suffix" ((issued third).text = system.text);
  let another = request ~post:true blocks in
  check "another turn borrows no Goal" ((issued another).goal_text = None);
  let unknown = request ~partition:world [P.Dynamic_context,"UNATTRIBUTED"] in
  check "mismatched source never promotes a Goal" ((issued unknown).goal_text = None);
  List.iter (fun previous ->
    let base = Option.value ~default:"BASE" previous in
    let empty = request ~base [] in
    check "no-Goal effective base is byte-identical" ((issued empty).text = base);
    check "no-Goal override preserves None or exact Some" (A.system_prompt_override ~previous empty = previous))
    [None;Some "";Some "PRIOR_OVERRIDE"];
  let empty_base = request ~base:"" ~partition:world blocks in
  check "an empty prior override is not replaced by default instructions"
    ((issued empty_base).base_text = "" && (issued empty_base).text = "\n\nGOAL-ID CURRENT-REV MEASUREMENT-ID");
  Printf.printf "%d exact-source carrier checks passed\n" !checks
'''
with tempfile.TemporaryDirectory(prefix="masc-goal-carriers-source-") as temporary:
    directory = Path(temporary)
    sources, records = [], []
    for module in modules:
        for extension in (".mli", ".ml"):
            path = ROOT / (module + extension)
            data = path.read_bytes()
            (directory / path.name).write_bytes(data)
            sources.append(path.name)
            records.append({"path": str(path.relative_to(ROOT)), "sha256": hashlib.sha256(data).hexdigest()})
    # Inference_utils.sanitize_text_utf8 aliases this exact Safe_ops producer.
    (directory / "inference_utils.ml").write_text(sanitizer)
    (directory / "bounded_request_context.ml").write_text(fragment)
    (directory / "probe.ml").write_text(probe)
    built = subprocess.run(["ocamlfind", "ocamlc", "-package", "yojson,digestif.ocaml,astring", "-linkpkg",
        *sources, "inference_utils.ml", "bounded_request_context.ml", "probe.ml", "-o", "probe"],
        cwd=directory, capture_output=True, text=True)
    if built.returncode:
        print(built.stdout + built.stderr)
        raise SystemExit(built.returncode)
    ran = subprocess.run([str(directory / "probe")], cwd=directory, capture_output=True, text=True)
    (OUT / "carrier-check.txt").write_text(ran.stdout + ran.stderr)
    (OUT / "carrier-check.json").write_text(json.dumps({"scope": "actual pure source only; no producer hook, SDK HTTP, native suite, or live Keeper execution",
        "modules": records, "request_fragment_sha256": hashlib.sha256(fragment.encode()).hexdigest(),
        "actual_safe_ops_sanitizer_sha256": hashlib.sha256(sanitizer.encode()).hexdigest(),
        "compile_exit": built.returncode, "run_exit": ran.returncode}, indent=2) + "\n")
    print(ran.stdout + ran.stderr)
    raise SystemExit(ran.returncode)
