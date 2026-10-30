"""Compile actual frozen-original and retained-result codecs with explicit pure ports.

This does not execute the owner store, worker dispatch, prompts, native Host,
provider/SDK, or filesystem locks. --baseline uses main's exact result codec
against the Goal review-result type to expose the missing consumer field.
"""
from pathlib import Path
import argparse
import hashlib
import json
import subprocess
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument("--repo", type=Path, required=True)
parser.add_argument("--baseline", action="store_true")
args = parser.parse_args()
root = args.repo.resolve()
out = Path(__file__).resolve().parent
inputs = []


def source(name):
    text = (root / name).read_text()
    inputs.append({"path": name, "sha256": hashlib.sha256(text.encode()).hexdigest()})
    return text


def part(text, first, last):
    start = text.index(first)
    return text[start:text.index(last, start)]


ar = source("lib/task/anti_rationalization.ml")
ar_types = (part(ar, "type evidence_image =", "let outcome_observer_fn")
            + part(ar, "let valid_verdict_strings", "(* ================================================================ *)\n(* LLM verification prompt")
            + part(ar, "type evidence_posture =", "let contract_section"))
original_ml = source("lib/keeper/verifier_review_original.ml")
original_mli = source("lib/keeper/verifier_review_original.mli")
owner = source("lib/keeper/verifier_review_owner.ml")
if args.baseline:
    owner = subprocess.check_output(["git", "show", "98a1508e6ecbda1d38d33aa7d0eb7f366b420ddf:lib/keeper/verifier_review_owner.ml"], cwd=root, text=True)
    inputs.append({"path": "main98a:lib/keeper/verifier_review_owner.ml", "sha256": hashlib.sha256(owner.encode()).hexdigest()})
codec = "module AR = Task.Anti_rationalization\nlet ( let* ) = Result.bind\n" + part(owner, "let result_to_json", "let judgment_to_json")
driver = r'''
module V = Verifier_review_original
module O = Result_codec
module AR = Task.Anti_rationalization
let checks = ref 0
let check label yes = if not yes then failwith label else
  (incr checks; Printf.printf "PASS %s\n" label)
let get = function Ok x -> x | Error e -> failwith e
let error = function Error _ -> true | Ok _ -> false
let map key value = function `Assoc fs -> `Assoc (List.map (fun (k,v) -> k,if k=key then value else v) fs) | _ -> assert false
let remove key = function `Assoc fs -> `Assoc (List.filter (fun (k,_) -> k<>key) fs) | _ -> assert false
let duplicate key = function `Assoc fs -> `Assoc ((key,List.assoc key fs)::fs) | _ -> assert false
let request : AR.review_request = {task_title="T";task_description="D";completion_notes="";
  agent_name="producer";task_id="task";evidence_refs=[];evidence_images=[]}
let question : AR.verdict_question = {completion_contract=None;required_evidence=[];
  evidence_posture=AR.Note_only;few_shot_block=""}
let prepare generator_runtime = V.prepare ~generator_runtime ~verification_id:"vrf"
  ~attempt:0 ~question ~lookup_root:(AR.Producer_tree ["source"])
  ~lookup_schemas:["read"] ~lookup_binding:(String.make 64 'a') request
let () =
  let original = get (prepare (Some "actual-producer")) in
  let encoded = V.to_json original in
  let restored = get (V.of_json encoded) in
  check "producer runtime survives exact original codec" (V.generator_runtime restored=Some "actual-producer");
  check "original round trip is byte-equivalent canonical data" (V.to_json restored=encoded);
  let next = get (V.successor restored) in
  check "successor preserves producer evidence and prompt" (V.generator_runtime next=Some "actual-producer" && V.system_prompt_text next=V.system_prompt_text original && V.attempt next=1);
  check "unobserved producer remains explicit None" (V.generator_runtime (get (V.of_json (V.to_json (get (prepare None)))))=None);
  check "blank producer cannot be captured" (error (prepare (Some " ")));
  check "missing producer field is refused" (error (V.of_json (remove "generator_runtime" encoded)));
  check "blank producer field is refused" (error (V.of_json (map "generator_runtime" (`String " ") encoded)));
  check "nontext producer field is refused" (error (V.of_json (map "generator_runtime" (`Int 0) encoded)));
  check "duplicate producer field is refused" (error (V.of_json (duplicate "generator_runtime" encoded)));
  check "previous original schema is explicitly refused" (error (V.of_json (map "schema" (`String "verifier_review_original/v2") encoded)));
  let identity = get (Runtime_response_identity.make ~execution_id:"execution" ~actor:"reviewer"
    ~runtime_id:"actual-winner" ~response_id:"response" ~provider_id:"provider"
    ~model_id:"reported-model" ~tool_use_id:"accepted-verdict" ~provider_turn:3 ~source_tool_use_ordinal:1) in
  let result : AR.review_result = {verdict=Some (AR.Approve "checked");evaluator_runtime="actual-winner";
    generator_runtime=Some "actual-producer";evaluator_execution=Some identity;gate=AR.Structured_tool;
    fallback_reason=None;retryable_runtimes=[];model_absent_runtimes=[]} in
  let wire = O.result_to_json result in
  let recovered = get (O.result_of_json wire) in
  check "retained result restores exact accepted provider identity" (recovered.evaluator_execution=Some identity);
  check "retained result restores producer and complete verdict" (recovered=result);
  let unknown = {result with evaluator_execution=None} in
  check "unobserved evaluator remains None" ((get (O.result_of_json (O.result_to_json unknown))).evaluator_execution=None);
  check "missing evaluator identity field is refused" (error (O.result_of_json (remove "evaluator_execution" wire)));
  check "duplicate evaluator identity field is refused" (error (O.result_of_json (duplicate "evaluator_execution" wire)));
  check "previous retained-result schema is refused" (error (O.result_of_json (map "schema" (`String "verifier_review_result/v1") wire)));
  check "malformed accepted response identity is refused" (error (O.result_of_json (map "evaluator_execution" (`Assoc []) wire)));
  let bad_identity = duplicate "response_id" (Runtime_response_identity.to_yojson identity) in
  check "duplicate nested identity key is refused" (error (O.result_of_json (map "evaluator_execution" bad_identity wire)));
  let invalid_gate = {result with verdict=None} in
  check "existing decision/gate refusal is preserved" (error (O.result_of_json (O.result_to_json invalid_gate)));
  Printf.printf "%d actual-source codec checks passed\n" !checks
'''
with tempfile.TemporaryDirectory(prefix="masc-goal-conflict-codecs-") as temp:
    directory = Path(temp)
    files = []
    def put(name, text):
        (directory / name).write_text(text)
        files.append(name)
    for ext in ["mli", "ml"]:
        put("runtime_response_identity." + ext, source("lib/types/runtime_response_identity." + ext))
    ports = {
        "types_core.ml": "type tool_schema = {name:string;description:string;input_schema:Yojson.Safe.t}\n",
        "tool_result.ml": "type result = unit\ntype failure_class = Policy_rejection\nlet error ~failure_class:_ ~tool_name:_ ~start_time:_ _ = ()\n",
        "tool_timing.ml": "let start () = ()\n",
        "prompt_names.ml": "let verification_system = \"verification-system\"\n",
        "prompt_registry.ml": "let render_prompt_template _ _ = Ok \"captured system instructions\"\n",
        "json_util.ml": "let string_opt_to_json = function None -> `Null | Some s -> `String s\n",
        "string_util.ml": "let is_lowercase_sha256_hex s = String.length s=64 && String.for_all (function '0'..'9'|'a'..'f' -> true | _ -> false) s\n",
        "lane_addon_action.ml": "let canonical x = Ok x\n",
        "lane_addon_store.ml": "let digest s = Digest.to_hex (Digest.string s)\n",
    }
    for name, text in ports.items():
        put(name, text)
    put("ar.ml", ar_types + "\nlet build_prompt ~question:_ ~lookup:_ ~lookup_root:_ _ = Ok \"captured review prompt\"\n")
    put("task.ml", "module Anti_rationalization = Ar\n")
    put("verifier_review_original.mli", original_mli)
    put("verifier_review_original.ml", original_ml)
    put("result_codec.ml", codec)
    put("probe.ml", driver)
    command = ["ocamlfind", "ocamlc", "-w", "+4+8+9", "-warn-error", "+4+8+9", "-package", "yojson", "-linkpkg", *files, "-o", "probe"]
    build = subprocess.run(command, cwd=directory, text=True, capture_output=True)
    run = subprocess.run([str(directory / "probe")], cwd=directory, text=True, capture_output=True) if build.returncode == 0 else None
    report = {"scope": __doc__, "baseline": args.baseline, "source_inputs": inputs,
              "ports": list(ports) + ["AR.build_prompt", "Types_core/Tool_result types"],
              "digest_port": "nonproduction digest port; no crypto/owner-store claim",
              "compile": {"command": command, "exit": build.returncode, "output": build.stdout + build.stderr},
              "execution": None if run is None else {"exit": run.returncode, "output": run.stdout + run.stderr}}
    (out / ("codec-before.json" if args.baseline else "codec-after.json")).write_text(json.dumps(report, indent=2) + "\n")
    print(build.stdout + build.stderr, end="")
    if run:
        print(run.stdout + run.stderr, end="")
    raise SystemExit(build.returncode if run is None else run.returncode)
