"""Execute actual measurement source with named in-memory effect ports; no Dune.

This is not native Goal-store locking, HTTP transport, SDK, or model evidence.
An optional frozen canary snapshot emits the new actual MCP success payload
while retaining the original measurement bytes/identity for inference pairing.
"""
from pathlib import Path
import argparse
import hashlib
import json
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[3]
OUT = Path(__file__).resolve().parent
BASE = "895df663fb303ee2fa95c38bbd28b571db9abb62"
parser = argparse.ArgumentParser()
parser.add_argument("--canary-snapshot", type=Path)
parser.add_argument("--receipt-out", type=Path)
args = parser.parse_args()


def source(path):
    return (ROOT / path).read_text()


def fragment(text, start, end):
    first = text.index(start)
    return text[first:text.index(end, first)]


probe = r'''
module M = Goal_measurement
let count = ref 0
let check label yes = if not yes then failwith label else
  (incr count; Printf.printf "PASS %s\n" label)
let okay = function Ok value -> value | Error error -> failwith (M.error_to_string error)
let member = Yojson.Safe.Util.member
let text field json = member field json |> Yojson.Safe.Util.to_string
let config = Workspace_utils.create ()
let goal : Goal_store.goal =
  { id="goal-probe";criterion_revision="revision-one";title="Observe three results";
    metric=Some "actual persisted results";target_value=Some "3/3";due_date=None;
    priority=1;phase=Goal_phase.Executing;last_review_note=None;last_review_at=None;
    created_at="2026-10-24T15:21:48Z";updated_at="2026-10-24T15:21:48Z" }
let request (goal : Goal_store.goal) = `Assoc
  ["goal_id",`String goal.id;"criterion_revision",`String goal.criterion_revision;
   "observed_value",`String "3/3";"evidence",`String "artifact:workspace/acceptance.json"]
let receipt goal =
  Goal_store.current := Some goal;
  okay (M.record_json config ~actor:"keeper" (request goal))
let () =
  let first = receipt goal in
  let old = Baseline.success first.measurement in
  check "baseline names reported_only as verification without lifecycle"
    (member "verification" old = `String "reported_only"
     && member "goal_at_recording" old = `Null);
  List.iter (fun phase ->
    let goal = {goal with phase} in
    let before = Goal_store.reads.contents in
    let issued = receipt goal in
    let wire = Mcp.handle_goal_measure ~tool_name:"masc_goal_measure" ~start_time:()
      {Mcp.config;agent_name="keeper"} (request goal) in
    let http = Http_payload.success issued in
    check ("actual receipt preserves " ^ Yojson.Safe.to_string (Goal_phase.to_yojson phase))
      (issued.goal_at_recording = goal
       && member "goal_at_recording" wire = Goal_store.goal_to_yojson goal
       && member "goal_at_recording" http = Goal_store.goal_to_yojson goal
       && member "measurement_status" wire = `String "reported_only"
       && member "completion_effect" wire = `String "unchanged"
       && member "verification" wire = `Null
       && !Goal_store.current = Some goal
       && !Goal_store.reads = before + 2)) Goal_phase.all;
  let issued = receipt goal in
  let frozen = M.receipt_fields issued in
  Goal_store.current := Some {goal with phase=Goal_phase.Completed;criterion_revision="revision-two"};
  check "issued receipt remains bound when a later Goal changes"
    (M.receipt_fields issued = frozen && issued.goal_at_recording = goal);
  let reads = !Goal_store.reads in
  ignore (Http_payload.success issued);
  check "receipt serialization performs no later authoritative read" (!Goal_store.reads = reads);
  (match M.record_json config ~actor:"keeper" (request goal) with
   | Error (M.Conflict _) -> check "stale criterion produces no receipt" true
   | Ok _ | Error (M.Invalid_request _ | M.Store_error _) -> failwith "stale criterion");
  Goal_store.current := Some goal;
  Goal_store.after_unlock := Some {goal with phase=Goal_phase.Verifying};
  let issued = okay (M.record_json config ~actor:"keeper" (request goal)) in
  check "record uses returned transaction Goal rather than post-unlock state"
    (issued.goal_at_recording.phase=Goal_phase.Executing &&
     Option.map (fun (g : Goal_store.goal) -> g.phase) !Goal_store.current=Some Goal_phase.Verifying);
  Goal_store.after_unlock := None;
  (match M.load config with
   | Ok [row] -> check "durable schema stores only the observation"
       (List.sort String.compare (match M.to_yojson row with `Assoc fs->List.map fst fs | _->[]) =
        ["actor";"criterion_revision";"evidence";"goal_id";"id";"observed_value";"recorded_at"])
   | Ok _ | Error _ -> failwith "durable measurement");
  let generation = Goal_projection_generation.current () in
  let invalid = `Assoc ["goal_id",`String goal.id] in
  (match M.record_json config ~actor:"keeper" invalid with
   | Error (M.Invalid_request _) -> check "invalid request cannot issue a receipt" true
   | Ok _ | Error (M.Conflict _ | M.Store_error _) -> failwith "invalid request");
  check "a rejected request does not advance observation generation"
    (Goal_projection_generation.current () = generation);
  if Array.length Sys.argv = 3 then (
    let fixture = Yojson.Safe.from_file Sys.argv.(1) in
    let goal_json = member "goal" fixture and measurement = member "measurement" fixture in
    let phase = match Goal_phase.of_fields goal_json with Ok phase->phase | Error e->failwith e in
    let optional name = match member name goal_json with `Null->None | `String s->Some s | _->failwith name in
    let goal : Goal_store.goal =
      {id=text "id" goal_json;criterion_revision=text "criterion_revision" goal_json;
       title=text "title" goal_json;metric=optional "metric";target_value=optional "target_value";
       due_date=optional "due_date";priority=Yojson.Safe.Util.to_int (member "priority" goal_json);
       phase;last_review_note=optional "last_review_note";last_review_at=optional "last_review_at";
       created_at=text "created_at" goal_json;updated_at=text "updated_at" goal_json} in
    Goal_store.current := Some goal;
    Random_id.value := text "id" measurement;
    Masc_domain.value := text "recorded_at" measurement;
    let req = `Assoc (List.map (fun name->name,member name measurement)
      ["goal_id";"criterion_revision";"observed_value";"evidence"]) in
    let answer = Mcp.handle_goal_measure ~tool_name:"masc_goal_measure" ~start_time:()
      {Mcp.config;agent_name=text "actor" measurement} req in
    check "paired receipt retains actual captured measurement identity and bytes"
      (member "measurement" answer = measurement);
    check "paired receipt names the actual captured lifecycle"
      (member "goal_at_recording" answer = goal_json);
    Yojson.Safe.to_file Sys.argv.(2) answer);
  Printf.printf "%d exact-source receipt checks passed\n" !count
'''

with tempfile.TemporaryDirectory(prefix="masc-goal-receipt-") as temporary:
    directory = Path(temporary)
    files, provenance = [], []

    def put(name, code, scope):
        (directory / name).write_text(code)
        files.append(name)
        provenance.append({"compiled": name, "scope": scope,
                           "sha256": hashlib.sha256(code.encode()).hexdigest()})

    util = source("lib/core/json_util.ml")
    put("json_util.ml", fragment(util, "let string_opt_to_json :", "let string_opt_to_json_trimmed")
        + fragment(util, "let assoc_member_opt name", "let assoc_string_opt"), "exact JSON helpers")
    for extension in [".mli", ".ml"]:
        put("goal_phase" + extension, source("lib/goal/goal_phase" + extension), "full actual lifecycle source/interface")
    put("backend_types.ml", 'type error = string\nlet show_error error = error\n', "backend error effect port")
    put("workspace_utils.ml", '''
type config = {store:(string,string) Hashtbl.t}
type committed = {mirror_error:string option}
let create () = {store=Hashtbl.create 4}
let masc_dir _ = "/probe/.masc"
let key_of_path _ path = Some path
let backend_get config ~key = Ok (Hashtbl.find_opt config.store key)
let with_file_lock _ _ callback = callback ()
let write_json_commit_result config path json =
  Hashtbl.replace config.store path (Yojson.Safe.to_string json); Ok {mirror_error=None}
let write_json_result config path json =
  Hashtbl.replace config.store path (Yojson.Safe.to_string json); Ok ()
''', "in-memory backend/write/lock effect port; no real lock or filesystem proof")
    document = source("lib/goal/goal_document.ml")
    put("goal_store.ml", fragment(document, "type goal =", "type criterion =")
        + fragment(document, "let goal_to_yojson", "let pending_notification_to_yojson") + '''
type write_error = Goal_not_found of string | Store_unavailable of string
  | Rejected of string | Persist_failed of string
let write_error_to_string = function Goal_not_found s|Store_unavailable s|Rejected s|Persist_failed s->s
let current : goal option ref = ref None
let after_unlock : goal option ref = ref None
let reads = ref 0
let transact_goal _ ~goal_id callback =
 incr reads;
 match !current with
 | None -> Error (Goal_not_found goal_id)
 | Some goal -> match callback goal with
   | Error message -> Error (Rejected message)
   | Ok (goal,result) ->
     current := (match !after_unlock with Some later->Some later | None->Some goal);
     Ok (goal,result)
''', "exact Goal record/serializer; named transaction result/read-count/interleaving effect port")
    snapshot = source("lib/workspace/workspace_verification_snapshot.ml")
    verification = source("lib/workspace/workspace_verification_store.ml")
    put("workspace_verification_store.ml", "type collaboration_kind = Board_source | Fusion_source\n"
        + fragment(snapshot, "let collaboration_reference reference", "let collaboration_metadata")
        + 'let note_reference_prefix = "note:"\n'
        + fragment(verification, "let artifact_reference_prefix", "(* A producer-relative artifact path"),
        "exact pure Evidence Reference grammar and relative path check")
    put("log.ml", 'module Misc = struct let warn format = Printf.ksprintf (fun _->()) format end\n', "logging effect port")
    put("random_id.ml", 'let value = ref "measurement-id"\nlet hex ~bytes:_ = !value\n', "identifier effect port")
    put("masc_domain.ml", 'let value = ref "2026-10-25T00:00:00Z"\nlet now_iso () = !value\n', "clock effect port")
    for stem in ["goal_projection_generation", "goal_measurement"]:
        for extension in [".mli", ".ml"]:
            put(stem + extension, source("lib/goal/" + stem + extension), "full actual source/interface")
    old = subprocess.check_output(["git", "show", BASE + ":lib/workspace_goals.ml"], cwd=ROOT, text=True)
    old_fields = fragment(old, '[ "measurement", Goal_measurement.to_yojson measurement', '  | Error error ->')
    put("baseline.ml", 'let success measurement = `Assoc (("status",`String "ok") :: ' + old_fields.strip() + ')\n', "exact baseline MCP success fields with envelope port")
    handler = fragment(source("lib/workspace_goals.ml"), "let handle_goal_measure", "(* RFC-0387 stage 2")
    put("mcp.ml", '''
type context = {config:Workspace_utils.config;agent_name:string}
module Tool_result = struct type result = Yojson.Safe.t end
type error_code = Validation_error | Conflict | Internal_error
let ok_result ~tool_name:_ ~start_time:_ fields = `Assoc (("status",`String "ok")::fields)
let error_result_typed ~tool_name:_ ~start_time:_ ~code message =
 let code = match code with Validation_error->"validation_error"|Conflict->"conflict"|Internal_error->"internal_error" in
 `Assoc ["status",`String "error";"error_code",`String code;"message",`String message]
''' + handler, "full actual MCP measurement handler; context/Tool_result/envelope effect ports")
    http = source("lib/server/server_routes_http_routes_dashboard.ml")
    payload = re.search(r'\(`Assoc \(\("ok", `Bool true\).*?Goal_measurement\.receipt_fields receipt\)\)', http, re.S).group()
    put("http_payload.ml", "let success receipt = " + payload + "\n", "exact HTTP success payload expression; not HTTP transport/auth")
    put("probe.ml", probe, "receipt behavior driver")
    command = ["ocamlfind", "ocamlc", "-w", "+4+32+69", "-warn-error", "+4+32+69",
               "-package", "yojson", "-linkpkg", *files, "-o", "probe"]
    built = subprocess.run(command, cwd=directory, capture_output=True, text=True)
    run_command = [str(directory / "probe")]
    if args.canary_snapshot:
        if not args.receipt_out:
            parser.error("--canary-snapshot requires --receipt-out")
        actual = json.loads(args.canary_snapshot.read_text())["state"]
        fixture = {"goal": actual[".masc/goals.json"]["goals"][0],
                   "measurement": actual[".masc/goal_measurements.json"]["measurements"][0]}
        fixture_path = directory / "fixture.json"
        fixture_path.write_text(json.dumps(fixture, ensure_ascii=False))
        run_command += [str(fixture_path), str(args.receipt_out.resolve())]
    ran = subprocess.run(run_command, cwd=directory, capture_output=True, text=True) if built.returncode == 0 else None
    record = {"scope": __doc__, "base": BASE, "source_inputs": provenance,
              "compile": {"command": command, "exit": built.returncode, "output": built.stdout + built.stderr},
              "execution": None if ran is None else {"exit": ran.returncode, "output": ran.stdout + ran.stderr}}
    if args.receipt_out and args.receipt_out.exists():
        record["emitted_receipt_sha256"] = hashlib.sha256(args.receipt_out.read_bytes()).hexdigest()
    (OUT / "source-check.json").write_text(json.dumps(record, indent=2) + "\n")
    print(built.stdout + built.stderr, end="")
    if ran:
        print(ran.stdout + ran.stderr, end="")
    raise SystemExit(built.returncode if ran is None else ran.returncode)
