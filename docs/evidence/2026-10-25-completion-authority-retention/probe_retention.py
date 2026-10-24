"""Run exact pure request-assembly sources before/after; no Dune or network."""
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[3]
OUT = Path(__file__).resolve().parent
BASE = "cc5104805e3963a9ef1a4fcb0013145514466a91"
MODULES = ["lib/types/prompt_block_id", "lib/keeper/keeper_context_layers", "lib/keeper/keeper_context_assembly"]
PROBE = r'''
module P = Prompt_block_id
module L = Keeper_context_layers
module A = Keeper_context_assembly
module R = Bounded_request_context
let checks = ref 0
let check label okay = if not okay then failwith label else incr checks
let has marker text = Astring.String.is_infix ~affix:marker text
let system a = match a.A.system_prompt with Some issued -> issued | None -> failwith "missing System"
let request ?previous ?partition ?(post=false) ?(base="BASE") blocks =
  R.assemble_request_context ~base_system_prompt:base ~post_tool_round:post
    ~previous_assembly:previous ~dynamic_context_partition:partition
    ~existing_extra_system_context:None ~blocks
let world goal authority = L.assemble ~content_of:(function
  | L.Active_goals -> if goal then Some "GOAL CURRENT-REV MEASUREMENT-ID" else None
  | L.Completion_authority -> if authority then Some "APPROVED task-1 vrf-1 human_operator fixture-operator" else None
  | L.Current_task -> Some "TASK GATE LANE"
  | Approval_authority | Connected_surfaces | Namespace_state | Workspace_memory
  | Wiki | Lane_updates | Repository_freshness | Autonomous_trigger | Scheduled_automation
  | Task_cancellations | Pending_mentions | Scope_messages | Own_board_posts | Board_activity
  | Own_recent_actions | Recent_work | Fleet_messages -> None)
let () =
  let observed = ref [] in
  List.iter (fun (goal,authority) ->
    let partition = world goal authority in
    let blocks = [P.Dynamic_context,L.text partition;P.Temporal_summary,"CLOCK"] in
    let first = request ~partition blocks in
    let second = request ~previous:first ~post:true ~partition blocks in
    let third = request ~previous:second ~post:true [] in
    let first_extra_authority = Option.fold ~none:false ~some:(has "vrf-1") first.extra_system_context in
    check "the first carrier includes the authority exactly once"
      ((has "vrf-1" (system first).text <> first_extra_authority) = authority);
    check "the existing source sends the first approval through extra context"
      (first_extra_authority = (authority && not expected_retention));
    check "Goal stays optional and exact" (has "CURRENT-REV" (system second).text = goal);
    check "authority retention follows this exact source version"
      (has "vrf-1" (system second).text = (authority && expected_retention));
    check "no other-world carrier returns after tools" (second.extra_system_context = None);
    List.iter (fun marker -> check "other world omitted" (not (has marker (system second).text)))
      ["TASK";"GATE";"LANE";"CLOCK"];
    check "later requests do not accumulate observations" ((system second).text = (system third).text);
    let reset = request ~post:true blocks in
    check "new turn cannot borrow the previous observation" ((system reset).text = "BASE");
    let unknown = request ~partition [P.Dynamic_context,"MISMATCH"] in
    check "mismatched renderer bytes stay unknown" ((system unknown).text = "BASE");
    let absent = request [P.Dynamic_context,L.text partition] in
    check "missing partition stays unknown" ((system absent).text = "BASE");
    let duplicate = request ~partition (blocks @ [P.Dynamic_context,L.text partition]) in
    check "duplicate Dynamic IDs do not acquire System provenance" ((system duplicate).text = "BASE");
    let physical = system second in
    List.iter (fun (span : A.span) ->
      let raw = String.sub physical.text span.offset span.bytes in
      check "physical System span hash matches its exact bytes"
        (span.sha256 = Digestif.SHA256.(digest_string raw |> to_hex))) physical.partition.spans;
    observed := `Assoc ["goal",`Bool goal;"authority",`Bool authority;
      "first_authority_in_system",`Bool (has "vrf-1" (system first).text);
      "first_authority_in_extra",`Bool first_extra_authority;
      "post_tool_authority_in_system",`Bool (has "vrf-1" physical.text)] :: !observed)
    [false,false;true,false;false,true;true,true];
  List.iter (fun previous ->
    let base = Option.value ~default:"BASE" previous in
    let none = request ~base [] in
    check "empty observation preserves exact base" ((system none).text = base);
    check "None and Some empty override stay distinct" (A.system_prompt_override ~previous none = previous))
    [None;Some "";Some "OVERRIDE"];
  Printf.printf "%s\n" (Yojson.Safe.to_string (`Assoc ["checks",`Int !checks;
    "matrix",`List (List.rev !observed)]))
'''


def read(path, baseline):
    if baseline:
        return subprocess.check_output(["git", "show", BASE + ":" + path], cwd=ROOT, text=True)
    return (ROOT / path).read_text()


observed = {}
manifest = {"base": BASE, "scope": "whole pure block/layer/assembly modules, actual Safe_ops sanitizer and exact request function; no producer hook, filesystem authority, native HTTP, CI or live model claim", "snapshots": {}}
for label, baseline in [("before", True), ("after", False)]:
    with tempfile.TemporaryDirectory(prefix="masc-authority-retention-") as temporary:
        directory = Path(temporary)
        sources, hashes = [], {}
        for module in MODULES:
            for extension in (".mli", ".ml"):
                path = module + extension
                text = read(path, baseline)
                (directory / Path(path).name).write_text(text)
                sources.append(Path(path).name)
                hashes[path] = hashlib.sha256(text.encode()).hexdigest()
        source = read("lib/keeper/keeper_run_prompt.ml", baseline)
        fragment = source[source.index("let assemble_extra_system_context ="):source.index("(* See the mli: a position question")]
        safe = read("lib/core/safe_ops.ml", baseline)
        sanitizer = safe[safe.index("let[@inline] is_disallowed_control_char"):safe.index("let rec sanitize_json_utf8")]
        (directory / "inference_utils.ml").write_text(sanitizer)
        (directory / "bounded_request_context.ml").write_text(fragment)
        (directory / "probe.ml").write_text("let expected_retention = " + str(not baseline).lower() + "\n" + PROBE)
        command = ["ocamlfind", "ocamlc", "-package", "yojson,digestif.ocaml,astring", "-w", "+4+32+69", "-warn-error", "+a", "-linkpkg", *sources, "inference_utils.ml", "bounded_request_context.ml", "probe.ml", "-o", "probe"]
        built = subprocess.run(command, cwd=directory, capture_output=True, text=True)
        if built.returncode:
            raise RuntimeError(built.stdout + built.stderr)
        result = subprocess.run([str(directory / "probe")], cwd=directory, capture_output=True, text=True)
        if result.returncode:
            raise RuntimeError(result.stdout + result.stderr)
        observed[label] = json.loads(result.stdout)
        manifest["snapshots"][label] = {"sources": hashes, "request_fragment_sha256": hashlib.sha256(fragment.encode()).hexdigest(), "actual_sanitizer_sha256": hashlib.sha256(sanitizer.encode()).hexdigest(), "compile_exit": built.returncode, "run_exit": result.returncode}
(OUT / "retention-check.json").write_text(json.dumps(observed, indent=2) + "\n")
(OUT / "retention-source.json").write_text(json.dumps(manifest, indent=2) + "\n")
print(json.dumps(observed, indent=2))
