open Alcotest

(* Offline transport/store replay of committed synthetic captures and untouched
   provider answers. No model call and no semantic row-count oracle. The fixture
   explicitly declares the TypeSafe lane and absorb gate off; this does not
   establish behavior under a live enabled absorption gate. Run with -v. *)
module Librarian = Masc.Keeper_librarian
module Runtime = Masc.Keeper_librarian_runtime
module Memory = Masc.Keeper_memory_os_types
module Current = Masc.Keeper_memory_os_current
module Queue = Masc.Keeper_memory_admission_queue
module Runs = Masc.Exact_lane_run_registry
module Fixture = Exact_output_fixture

let () = Masc.Prompt_defaults.init ()
let require = function Ok value -> value | Error detail -> fail detail
let sha256 bytes = Digestif.SHA256.(digest_string bytes |> to_hex)
let hash_json json = sha256 (Yojson.Safe.to_string json)
let member = Yojson.Safe.Util.member
let json_string name json = member name json |> Yojson.Safe.Util.to_string
let json_list name json = member name json |> Yojson.Safe.Util.to_list
let decode_fact json = Memory.fact_of_json json
  |> Result.map_error Memory.wire_error_to_string |> require
let fixture_dir = "test/fixtures/memory_admission_replay"

let with_workspace f =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  Eio_context.with_test_env ~net:(Eio.Stdenv.net env)
    ~clock:(Eio.Stdenv.clock env) ~mono_clock:(Eio.Stdenv.mono_clock env) ~sw @@ fun () ->
  let base_path = Filename.temp_dir "synthetic-admission-export-" "" in
  Eio.Switch.on_release sw (fun () -> Fs_compat.remove_tree base_path);
  Masc_test_deps.with_process_env Env_config_core.base_path_env_key (Some base_path) @@ fun () ->
  Masc_test_deps.with_process_env Env_config_core.config_dir_env_key
    (Some (Filename.concat base_path "config")) @@ fun () ->
  Config_dir_resolver.reset ();
  Fun.protect ~finally:Config_dir_resolver.reset (fun () -> f ~base_path)

let candidate_json (candidate : Queue.candidate) =
  `Assoc ["sequence",`Int candidate.sequence; "request_id",`String candidate.request_id;
          "fact",Memory.fact_to_json candidate.fact]

(* model_metadata.schema_sha256 digests the schema bytes the capture CLI
   received. Claude Code CLI receives the wire bytes. Codex CLI reads
   `--output-schema` from a file the capture wrote as Python
   json.dumps(schema, indent=2) plus a newline; this rebuilds those bytes for
   ASCII schemas with integer bounds, which is what the captures contain. *)
type schema_encoding = Wire_bytes | Output_schema_file

let schema_encoding_label = function
  | Wire_bytes -> "wire_bytes"
  | Output_schema_file -> "output_schema_file"

let output_schema_file_bytes schema =
  let buffer = Buffer.create 4096 in
  let newline depth =
    Buffer.add_char buffer '\n'; Buffer.add_string buffer (String.make (2 * depth) ' ') in
  let container depth opening closing items emit_item =
    Buffer.add_char buffer opening;
    List.iteri (fun index item ->
      if index > 0 then Buffer.add_char buffer ',';
      newline (depth + 1); emit_item item) items;
    newline depth; Buffer.add_char buffer closing in
  let rec emit depth = function
    | `Assoc [] -> Buffer.add_string buffer "{}"
    | `List [] -> Buffer.add_string buffer "[]"
    | `Assoc fields -> container depth '{' '}' fields (fun (key, value) ->
        Buffer.add_string buffer (Yojson.Safe.to_string (`String key));
        Buffer.add_string buffer ": "; emit (depth + 1) value)
    | `List items -> container depth '[' ']' items (emit (depth + 1))
    | scalar -> Buffer.add_string buffer (Yojson.Safe.to_string scalar) in
  emit 0 schema; Buffer.add_char buffer '\n'; Buffer.contents buffer

let schema_bytes encoding schema = match encoding with
  | Wire_bytes -> Yojson.Safe.to_string schema
  | Output_schema_file -> output_schema_file_bytes schema

(* model_metadata.export_sha256 digests the export file that
   scripts/experiments/collect-admission-exports.py wrote: the exporter's
   compact Yojson capture line plus a newline. Re-serializing the parsed
   capture reproduces that line, as the per-field wire digests below also
   rely on. It covers every capture field, including ones no per-field digest
   names, such as [measurement] and [semantic_judgment_performed]. *)
let capture_export_sha256 capture = sha256 (Yojson.Safe.to_string capture ^ "\n")

let replay filename () =
  let envelope = Yojson.Safe.from_file (Masc_test_deps.source_path
      (Filename.concat fixture_dir filename)) in
  let capture = member "capture" envelope in
  let hashes = member "input_hashes" capture in
  let response_raw = json_string "response_raw" envelope in
  check string "response bytes match the recorded provider response digest"
    (json_string "response_sha256" envelope) (sha256 response_raw);
  let model_metadata = member "model_metadata" envelope in
  (match model_metadata with `Assoc (_::_) -> () | _ -> fail "model metadata is required");
  let metadata_string key = match member key model_metadata with
    | `String value -> value
    | _ -> fail ("model metadata lacks " ^ key) in
  check string "model metadata names the replayed response bytes"
    (metadata_string "response_sha256") (sha256 response_raw);
  check string "model metadata names the captured prompt bytes"
    (json_string "prompt_sha256" hashes) (metadata_string "prompt_sha256");
  check string "model metadata names the stored capture export"
    (metadata_string "export_sha256") (capture_export_sha256 capture);
  let model_schema_encoding =
    let schema = member "schema" capture and digest = metadata_string "schema_sha256" in
    match List.find_opt (fun encoding -> String.equal digest (sha256 (schema_bytes encoding schema)))
        [Wire_bytes; Output_schema_file] with
    | Some encoding -> encoding
    | None -> fail "model metadata schema digest matches no encoding of the replayed schema" in
  let replay_policy = member "replay_policy" envelope in
  check bool "fixture explicitly declares TypeSafe lane off" false
    (member "lane_enabled" replay_policy |> Yojson.Safe.Util.to_bool);
  check bool "fixture explicitly declares absorption gate off" false
    (member "absorb_gate" replay_policy |> Yojson.Safe.Util.to_bool);
  check string "stored prompt bytes match their capture digest"
    (json_string "prompt_sha256" hashes) (sha256 (json_string "prompt" capture));
  check string "stored system prompt bytes match their capture digest"
    (json_string "system_prompt_sha256" hashes) (sha256 (json_string "system_prompt" capture));
  check string "stored schema matches its capture digest"
    (json_string "schema_sha256" hashes) (hash_json (member "schema" capture));
  let cohort = json_string "cohort" capture in
  let initial_facts = json_list "initial_current_facts" capture |> List.map decode_fact in
  let initial_present = member "initial_snapshot_present" capture |> Yojson.Safe.Util.to_bool in
  if not initial_present && initial_facts <> [] then fail "absent initial snapshot contains facts";
  let candidates = json_list "candidates" capture |> List.map (fun json ->
    ({Queue.sequence=member "sequence" json |> Yojson.Safe.Util.to_int;
      request_id=json_string "request_id" json; fact=decode_fact (member "fact" json)} : Queue.candidate)) in
  if candidates = [] then fail "replay must contain admission input";
  let check_hash key json = check string key (json_string key hashes) (hash_json json) in
  check_hash "initial_current_facts_sha256" (`List (List.map Memory.fact_to_json initial_facts));
  check_hash "candidates_sha256" (`List (List.map candidate_json candidates));
  check_hash "scenario_input_sha256" (member "scenario_input" capture);
  let instructions = json_string "keeper_instructions" capture in
  check string "keeper instructions digest" (json_string "keeper_instructions_sha256" hashes)
    (sha256 instructions);
  with_workspace @@ fun ~base_path ->
  Fixture.with_official_client_runtimes @@ fun () ->
  Masc_test_deps.with_typesafeai_policy
    {Runtime_schema.default_typesafeai with lane_enabled=false; absorb_gate=false} @@ fun () ->
  Prompt_registry.set_markdown_dir (Masc_test_deps.source_path "config/prompts");
  ignore (Fixture.publish_registry ~cli_slot_ids:[Fixture.cli_primary_runtime]
    ~lane_id:"librarian_exact" ~slot_ids:[]
    (Fixture.resolver_snapshot ~source:"synthetic admission replay"
       [{Fixture.id="unused-synthetic-slot"; base_url="http://127.0.0.1:1"}])
    : Runtime_exact_output_registry.t);
  let keeper_id = "synthetic-" ^ String.map (function '_' -> '-' | c -> c) cohort in
  let trace_id = "synthetic-admission-export" in
  let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path in
  (* Captures seed nonempty snapshots at their original fact time. For an
     explicitly empty snapshot, the first recorded input supplies its clock. *)
  let initial_time = match initial_facts, candidates with
    | first :: rest, _ -> List.fold_left (fun stamp (fact : Memory.fact) ->
        max stamp fact.last_seen) first.last_seen rest
    | [], candidate :: _ -> candidate.fact.first_seen
    | [], [] -> fail "missing reconstruction timestamp" in
  let initial = if initial_present then Some (Current.replace ~keepers_dir ~keeper_id
      ~expected_revision:None ~now:initial_time
      ~source:{Current.kind=Current.Explicit_write; trace_id} ~facts:initial_facts () |> require)
    else None in
  List.iter (fun (candidate : Queue.candidate) ->
    let restored = Queue.append ~keepers_dir ~keeper_id ~request_id:candidate.request_id
      candidate.fact |> require in
    check bool "original identity, sequence and full provenance restored" true
      (restored = candidate)) candidates;
  let admission = match Queue.read_pending ~keepers_dir ~keeper_id |> require with
    | Some batch -> batch | None -> fail "restored queue is absent" in
  let identities = Queue.candidate_ids admission in
  let generation = match identities with
    | id :: _ -> id.Current.queue_generation | [] -> fail "missing candidate identities" in
  check string "restored candidate bytes match original capture"
    (json_string "candidates_sha256" hashes)
    (hash_json (`List (List.map candidate_json (Queue.candidates admission))));
  let queue_path = Queue.path ~keepers_dir ~keeper_id in
  let current_path = Current.path_for_keepers_dir ~keepers_dir ~keeper_id in
  let queue_before = Fs_compat.load_file queue_path in
  let current_before = Fs_compat.load_file_opt current_path in
  let config = Masc.Workspace.default_config base_path in
  let meta = Masc_test_deps.meta_of_json_fixture
    (`Assoc ["name",`String keeper_id; "trace_id",`String trace_id]) |> require in
  let recall_queries = json_list "recall_queries" envelope |> List.map Yojson.Safe.Util.to_string in
  if recall_queries = [] then fail "replay must declare its recall probes";
  let recall () = List.map (fun query ->
    let response = Masc.Keeper_tool_memory_runtime.keeper_memory_search_json
      ~config ~meta
      ~ctx_work:(Masc.Keeper_context_runtime.create ~eio:false ~system_prompt:"")
      ~args:(`Assoc ["query",`String query;"source",`String "current"])
      |> Yojson.Safe.from_string in
    `Assoc ["query",`String query;"response",response]) recall_queries in
  let recall_before = recall () in
  let recalled_texts results = List.concat_map (fun result ->
    json_list "matches" (member "response" result) |> List.map (json_string "text")) results in
  if String.equal filename "verified_replacement.json" then
    List.iter (fun (fact : Memory.fact) ->
      check bool "seeded claim is retrievable before the saved response" true
        (List.mem fact.claim (recalled_texts recall_before))) initial_facts;
  let selected_input : Librarian.input =
    {keeper_id=Masc_test_deps.keeper_id_fixture keeper_id; keeper_instructions=instructions;
     turn_ref=Ids.Turn_ref.make ~trace_id ~absolute_turn:0;
     current=Option.map (fun (snapshot : Current.t) ->
       ({Librarian.facts=snapshot.facts} : Librarian.current_selection)) initial;
     historical_task_contexts=[]; goal_context=Librarian.No_task;
     working_context=Masc.Keeper_librarian_context.empty;
     messages=[]; tool_observations=[]; counterpart_observations=[]} in
  let calls = ref 0 and captured_request = ref None in
  let request_hashes (runtime_id, system_prompt, output_schema, prompt) =
    `Assoc ["runtime_id",`String runtime_id; "prompt_sha256",`String (sha256 prompt);
      "system_prompt_sha256",`String (sha256 system_prompt);
      "schema_sha256",`String (hash_json output_schema)] in
  let matches_capture (runtime_id, system_prompt, output_schema, prompt) =
    String.equal (json_string "runtime_id" capture) runtime_id
    && String.equal (json_string "prompt_sha256" hashes) (sha256 prompt)
    && String.equal (json_string "system_prompt_sha256" hashes) (sha256 system_prompt)
    && String.equal (json_string "schema_sha256" hashes) (hash_json output_schema) in
  let injected = ref false in
  let runner ~runtime_id ~system_prompt ~output_schema ~prompt =
    incr calls;
    let request = runtime_id, system_prompt, output_schema, prompt in
    captured_request := Some request;
    if matches_capture request then (injected := true; Ok response_raw)
    else Error (Masc.Fusion_official_client.Setup_failure
      "captured request differs from current contract; recorded response was not replayed") in
  let prior_runs = Runs.list_runs (Runs.global ()) in
  let committed = ref 0 and refusals = ref [] in
  Runtime.run_best_effort ~write_scope:Runtime.Memory_maintenance ~admission ~cli_runner:runner
    ~on_memory_committed:(fun () -> incr committed)
    ~on_not_committed:(fun reason -> refusals := reason :: !refusals)
    ~base_path ~keepers_dir ~keeper_id
    ~expected_revision:(Option.map (fun (snapshot : Current.t) -> snapshot.revision) initial)
    selected_input;
  check int "one request eligibility check" 1 !calls;
  let current_request = match !captured_request with
    | Some request -> request | None -> fail "no replay request captured" in
  check bool "response injected only for exact captured request"
    (matches_capture current_request) !injected;
  let receipts = Current.committed_explicit_candidates ~keepers_dir ~keeper_id
    ~queue_generation:generation |> require in
  if !committed = 0 then check bool "no commit has no receipt" true (receipts=[])
  else (
    check int "single snapshot commit" 1 !committed;
    check bool "consumption belongs to exact reconstructed inputs" true
      (receipts<>[] && List.for_all (fun id -> List.mem id identities) receipts));
  if not !injected then check int "stale capture cannot commit" 0 !committed;
  (* A response is replayed only when the current request matches its saved
     capture. Stale captures remain explicit refusals; a valid injected
     verified response must exercise commit and acknowledgement. *)
  if String.equal filename "verified_replacement.json" && !injected then
    check int "verified replacement must commit exactly once" 1 !committed;
  (* No success flag consumes the queue. Even failed/deferred responses pass
     through acknowledgement, whose sole authority is the real Memory receipt. *)
  Queue.acknowledge_committed ~keepers_dir ~keeper_id |> require;
  if !committed = 0 then (
    check string "failed/deferred response cannot consume pending input"
      queue_before (Fs_compat.load_file queue_path);
    check (option string) "failed/deferred response cannot mutate current Memory"
      current_before (Fs_compat.load_file_opt current_path));
  let pending = match Queue.read_pending ~keepers_dir ~keeper_id |> require with
    | None -> [] | Some batch -> Queue.candidates batch in
  check bool "acknowledgement leaves exactly unconsumed candidate identities" true
    (List.map (fun (row : Queue.candidate) -> row.request_id) pending =
     List.filter_map (fun (id : Current.explicit_candidate_id) ->
       if List.mem id receipts then None else Some id.request_id) identities);
  let current = Current.read_for_keepers_dir ~keepers_dir ~keeper_id |> require in
  let current_facts = match current with None -> [] | Some snapshot -> snapshot.Current.facts in
  let runs = Runs.list_runs (Runs.global ()) |> List.filter (fun (run : Runs.run) ->
    not (List.exists (fun (prior : Runs.run) -> String.equal prior.run_id run.run_id) prior_runs)) in
  let exact_run = match runs with
    | [run] -> run | _ -> fail "replay did not produce one exact-run observation" in
  if String.equal filename "verified_replacement.json" && !injected then (
    let replacement = "Owner-approved policy revision replaces the prior production P-42 rule: deployment now requires two independent approvals." in
    check (list string) "replacement is the sole current claim" [replacement]
      (List.map (fun (fact : Memory.fact) -> fact.claim) current_facts);
    List.iter (fun (old : Memory.fact) ->
      check bool "superseded identity is absent from current Memory" false
        (List.exists (fun (fact : Memory.fact) -> Memory.memory_id fact = Memory.memory_id old) current_facts)) initial_facts;
    (* Leaving current Memory is half of a replacement. The saved answer drops
       each seeded claim with a reason, so the store must keep the complete
       original and that reason as recoverable history. *)
    let drop_reasons = Yojson.Safe.from_string response_raw |> member "memory"
      |> json_list "dropped" |> List.map (json_string "reason") in
    let archived = Current.read_dropped ~keepers_dir ~keeper_id ~current_facts |> require in
    check (list string) "superseded identities are archived, not lost"
      (List.map Memory.memory_id initial_facts)
      (List.map (fun (row : Current.archived_fact) -> Memory.memory_id row.original) archived);
    check bool "archive keeps each complete superseded original" true
      (List.for_all2 (fun (old : Memory.fact) (row : Current.archived_fact) -> row.original = old)
         initial_facts archived);
    check (list (option string)) "archive keeps the saved answer's drop reason"
      (List.map Option.some drop_reasons)
      (List.map (fun (row : Current.archived_fact) -> row.removal.drop_reason) archived);
    let after = recall () in
    check bool "replacement is retrievable by the fixture query" true
      (List.exists (fun result ->
        json_list "matches" (member "response" result)
        |> List.exists (fun matched -> json_string "text" matched = replacement)) after);
    match exact_run.status with
     | Runs.Completed {outcome=Runs.Succeeded; _} -> ()
     | Running | Completed _ | Completion_persistence_failed _ ->
         fail "verified replacement must complete its exact run successfully");
  let payload = `Assoc ["fixture",`String filename; "cohort",`String cohort;
    "response_sha256",`String (sha256 response_raw); "model_metadata",model_metadata;
    "model_schema_encoding",`String (schema_encoding_label model_schema_encoding);
    "gate_policy",`Assoc ["scope",`String "fixture_declared_off_not_live_gate_evidence";
      "lane_enabled",`Bool false; "absorb_gate",`Bool false];
    "actual_request",request_hashes current_request;
    "response_replayed",`Bool !injected;
    "actual_outcome",`String (if not !injected then "capture_not_current"
      else if receipts<>[] then "committed_and_acknowledged" else "not_committed");
    "current_facts",`List (List.map Memory.fact_to_json current_facts);
    "current_snapshot_present",`Bool (Option.is_some current);
    "recall_before",`List recall_before;
    "recall_after",`List (recall ());
    "pending",`List (List.map candidate_json pending);
    "not_committed",`List (List.rev_map (fun (reason : Runtime.not_committed) ->
      `Assoc ["detail",`String reason.detail; "walk_shows_size",`Bool reason.walk_shows_size]) !refusals);
    "exact_run",Runs.run_to_yojson exact_run] in
  Printf.printf "MEMORY_ADMISSION_REPLAY %s\n%!" (Yojson.Safe.to_string payload)

let () =
  let manifest = Yojson.Safe.from_file (Masc_test_deps.source_path
      (Filename.concat fixture_dir "manifest.json")) in
  let filenames = json_list "fixtures" manifest |> List.map Yojson.Safe.Util.to_string in
  if filenames = [] then fail "replay manifest must contain actual response fixtures";
  check bool "replay manifest includes the required verified replacement" true
    (List.mem "verified_replacement.json" filenames);
  List.iter (fun name ->
    if name = "" || Filename.basename name <> name then fail "manifest fixture must be a basename") filenames;
  if List.length (List.sort_uniq String.compare filenames) <> List.length filenames then
    fail "duplicate replay fixture in manifest";
  run "synthetic admission exact store replay"
    ["responses",List.map (fun name -> test_case name `Quick (replay name)) filenames]
