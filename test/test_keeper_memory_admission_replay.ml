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

(* Each manifest entry names the outcome its saved response reaches at this
   head. A capture that stops matching the current request then fails the
   suite instead of silently skipping its replay. *)
type outcome = Capture_not_current | Committed_and_acknowledged | Not_committed

let outcome_label = function
  | Capture_not_current -> "capture_not_current"
  | Committed_and_acknowledged -> "committed_and_acknowledged"
  | Not_committed -> "not_committed"

let outcome_of_label = function
  | "capture_not_current" -> Capture_not_current
  | "committed_and_acknowledged" -> Committed_and_acknowledged
  | "not_committed" -> Not_committed
  | other -> fail ("unknown expected replay outcome: " ^ other)

let outcome_testable =
  testable (fun ppf value -> Format.pp_print_string ppf (outcome_label value)) ( = )

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
  let state_bundle = member "state_bundle" capture in
  let restores_state = state_bundle <> `Null in
  let keeper_id = (if restores_state then json_string "keeper_id" capture
    else "synthetic-" ^ String.map (function '_' -> '-' | c -> c) cohort)
    |> Keeper_id.Keeper_name.of_string |> require |> Keeper_id.Keeper_name.to_string in
  let trace_id = (if restores_state then json_string "trace_id" capture
    else "synthetic-admission-export")
    |> Keeper_id.Trace_id.of_string |> require |> Keeper_id.Trace_id.to_string in
  let absolute_turn = if restores_state then member "absolute_turn" capture
    |> Yojson.Safe.Util.to_int else 0 in
  let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path in
  let initial = if restores_state then (
    let stores = ["current_snapshot", Current.path_for_keepers_dir ~keepers_dir ~keeper_id;
      "consumption_and_lookup_receipt", Current.durable_range_receipt_path ~keepers_dir ~keeper_id;
      "memory_journal", Current.journal_path_for_keepers_dir ~keepers_dir ~keeper_id;
      "pending_queue", Queue.path ~keepers_dir ~keeper_id] in
    let fields = Yojson.Safe.Util.to_assoc state_bundle in
    check (list string) "state bundle permits only the four known stores"
      (List.sort String.compare (List.map fst stores))
      (List.sort String.compare (List.map fst fields));
    let decoded = List.map (fun (name,path) ->
      let entry = List.assoc name fields in
      let present = member "present" entry |> Yojson.Safe.Util.to_bool in
      check (list string) (name ^ " has a closed state envelope")
        (if present then ["bytes";"present";"sha256"] else ["present"])
        (List.sort String.compare (List.map fst (Yojson.Safe.Util.to_assoc entry)));
      let bytes = if present then (
        let bytes = json_string "bytes" entry in
        check string (name ^ " exact stored bytes digest") (json_string "sha256" entry) (sha256 bytes);
        Some bytes) else None in
      name,path,bytes) stores in
    (* All keys and digests are checked before any restore; no path comes from JSON. *)
    List.iter (fun (_,path,bytes) -> match bytes with None -> () | Some bytes ->
      Fs_compat.mkdir_p (Filename.dirname path);
      Fs_compat.save_file_atomic_strict path bytes |> require) decoded;
    let snapshot = Current.read_for_keepers_dir ~keepers_dir ~keeper_id |> require in
    check bool "restored snapshot presence equals capture" initial_present (Option.is_some snapshot);
    check bool "restored snapshot preserves exact captured facts and times" true
      ((match snapshot with None -> [] | Some snapshot -> snapshot.facts) = initial_facts);
    List.iter (fun (name,path,bytes) -> check (option string) (name ^ " restores without rewriting")
      bytes (Fs_compat.load_file_opt path)) decoded;
    snapshot)
  else (
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
      check bool "original identity, sequence and full provenance restored" true (restored = candidate)) candidates;
    initial) in
  let admission = match Queue.read_pending ~keepers_dir ~keeper_id |> require with
    | Some batch -> batch | None -> fail "restored queue is absent" in
  let identities = Queue.candidate_ids admission in
  let generation = match identities with
    | id :: _ -> id.Current.queue_generation | [] -> fail "missing candidate identities" in
  check string "restored candidate bytes match original capture"
    (json_string "candidates_sha256" hashes)
    (hash_json (`List (List.map candidate_json (Queue.candidates admission))));
  let identity_json (id : Current.explicit_candidate_id) =
    `Assoc ["queue_generation",`String id.queue_generation;"request_id",`String id.request_id;
      "sequence",`Int id.sequence;"input_sha256",`String id.input_sha256] in
  if restores_state then check bool "restored candidate receipt identities are exact" true
    (Yojson.Safe.equal (`List (List.map identity_json identities)) (member "candidate_receipts" capture));
  let baseline_receipts = Current.committed_explicit_candidates ~keepers_dir ~keeper_id
    ~queue_generation:generation |> require in
  check bool "incoming candidates have no prior consumed receipt" true
    (List.for_all (fun id -> not (List.mem id baseline_receipts)) identities);
  let _, baseline_bindings =
    Current.read_with_admission_recall_for_keepers_dir ~keepers_dir ~keeper_id |> require in
  let restored_state = `Assoc ["performed",`Bool restores_state;
    "state_bundle_sha256",(if restores_state then `String (hash_json state_bundle) else `Null);
    "prior_consumed_candidate_count",`Int (List.length baseline_receipts);
    "prior_lookup_binding_count",`Int (List.length baseline_bindings);
    "incoming_candidates",`List (List.map identity_json identities)] in
  let queue_path = Queue.path ~keepers_dir ~keeper_id in
  let current_path = Current.path_for_keepers_dir ~keepers_dir ~keeper_id in
  let queue_before = Fs_compat.load_file queue_path in
  let current_before = Fs_compat.load_file_opt current_path in
  let config = Masc.Workspace.default_config base_path in
  let meta = Masc_test_deps.meta_of_json_fixture
    (`Assoc ["name",`String keeper_id; "trace_id",`String trace_id]) |> require in
  let recall_queries = json_list "recall_queries" envelope |> List.map Yojson.Safe.Util.to_string in
  if recall_queries = [] then fail "replay must declare its recall probes";
  let recall ?(source="current") () = List.map (fun query ->
    let response = Masc.Keeper_tool_memory_runtime.keeper_memory_search_json
      ~config ~meta
      ~ctx_work:(Masc.Keeper_context_runtime.create ~eio:false ~system_prompt:"")
      ~args:(`Assoc ["query",`String query;"source",`String source])
      |> Yojson.Safe.from_string in
    `Assoc ["query",`String query;"response",response]) recall_queries in
  let recall_before = recall () in
  let recalled_texts results = List.concat_map (fun result ->
    json_list "matches" (member "response" result) |> List.map (json_string "text")) results in
  if String.equal filename "verified_replacement.json" then
    List.iter (fun (fact : Memory.fact) ->
      check bool "seeded claim is retrievable before the saved response" true
        (List.mem fact.claim (recalled_texts recall_before))) initial_facts;
  let recall_all_before = recall ~source:"all" () in
  let selected_input : Librarian.input =
    {keeper_id=Masc_test_deps.keeper_id_fixture keeper_id; keeper_instructions=instructions;
     turn_ref=Ids.Turn_ref.make ~trace_id ~absolute_turn;
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
  let all_receipts = Current.committed_explicit_candidates ~keepers_dir ~keeper_id
    ~queue_generation:generation |> require in
  check bool "all predecessor consumption receipts survive replay" true
    (List.for_all (fun id -> List.mem id all_receipts) baseline_receipts);
  let receipts = List.filter (fun id -> not (List.mem id baseline_receipts)) all_receipts in
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
  let file_bytes path = match Fs_compat.load_file_opt path with
    | None -> 0 | Some bytes -> String.length bytes in
  let storage_after = `Assoc ["current_snapshot_bytes",`Int (file_bytes current_path);
    "consumption_and_lookup_receipt_bytes",`Int (file_bytes
      (Current.durable_range_receipt_path ~keepers_dir ~keeper_id));
    "pending_queue_bytes",`Int (file_bytes queue_path)] in
  let recall_after = recall () in
  let recall_all_after = recall ~source:"all" () in
  let binding_snapshot, recall_bindings =
    Current.read_with_admission_recall_for_keepers_dir ~keepers_dir ~keeper_id |> require in
  check bool "recall bindings and current snapshot share one recovered read" true
    (binding_snapshot = current);
  List.iter (fun (binding : Current.admission_recall_binding) ->
    check bool "lookup provenance belongs to an acknowledged candidate" true
      (List.mem binding.candidate_id all_receipts);
    check bool "lookup provenance preserves the complete original input" true
      (List.exists (fun (candidate : Queue.candidate) ->
        candidate.request_id = binding.candidate_id.request_id
        && candidate.fact = binding.source_fact) candidates
       || List.exists (fun (prior : Current.admission_recall_binding) ->
         prior.candidate_id = binding.candidate_id && prior.source_fact = binding.source_fact)
         baseline_bindings);
    check bool "lookup destination is a current claim" true
      (List.exists (fun fact -> Memory.memory_id fact = binding.target_memory_id)
         current_facts)) recall_bindings;
  let runs = Runs.list_runs (Runs.global ()) |> List.filter (fun (run : Runs.run) ->
    not (List.exists (fun (prior : Runs.run) -> String.equal prior.run_id run.run_id) prior_runs)) in
  let exact_run = match runs with
    | [run] -> run | _ -> fail "replay did not produce one exact-run observation" in
  if String.equal filename "verified_replacement.json" && !injected then
    (match exact_run.status with
     | Runs.Completed {outcome=Runs.Succeeded; _} -> ()
     | Running | Completed _ | Completion_persistence_failed _ ->
         fail "verified replacement must complete its exact run successfully");
  let followup_proposals = match member "followup_proposals" envelope with
    | `Null -> [] | json -> Yojson.Safe.Util.to_list json |> List.map Yojson.Safe.Util.to_string in
  if String.equal filename "independent_200.json" then
    (* The capture claims to be the R-015-only experiment, so the input is
       pinned to that single correction here rather than accepted as any
       nonempty proposal list. *)
    check (list string) "independent-200 fixture carries the single R-015 correction"
      [ "Verified owner-approved policy change: production release R-015 now requires two independent \
         approvals, replacing its prior owner-approval requirement. Production releases R-001 through \
         R-200 other than R-015 retain their existing owner-approval requirement. This change does not \
         change any staging policy." ]
      followup_proposals;
  if followup_proposals <> [] then (
    check bool "followup starts from an actual committed predecessor" true
      (!injected && receipts <> [] && pending = []);
    (* A binding comparison against the same incomplete subset on both sides
       would pass while the predecessor had already lost addresses, so the
       coverage is established before anything is compared. *)
    check int "every scenario candidate was settled" (List.length candidates) (List.length receipts);
    check int "predecessor recall bound every settled receipt" (List.length receipts)
      (List.length recall_bindings);
    List.iter (fun claim ->
      let result = Masc.Keeper_tool_memory_runtime.keeper_memory_write_with_outcome
        ~config ~meta ~args:(`Assoc ["content",`String claim]) in
      check string "followup enters through the real deferred producer" "persisted_pending_admission"
        (json_string "outcome" (Yojson.Safe.from_string result.raw_output))) followup_proposals;
    let followup_snapshot, followup_bindings =
      Current.read_with_admission_recall_for_keepers_dir ~keepers_dir ~keeper_id |> require in
    check bool "producer preserves predecessor snapshot and lookup provenance" true
      (followup_snapshot = current && followup_bindings = recall_bindings);
    let followup = match Queue.read_pending ~keepers_dir ~keeper_id |> require with
      | Some batch -> batch | None -> fail "followup candidate missing" in
    let followup_candidates = Queue.candidates followup in
    let prior_sequence = List.fold_left (fun highest (id : Current.explicit_candidate_id) ->
      max highest id.sequence) 0 receipts in
    check int "one queued candidate per proposal" (List.length followup_proposals)
      (List.length followup_candidates);
    List.iteri (fun offset (candidate : Queue.candidate) ->
      check string "followup queues the proposed correction verbatim"
        (List.nth followup_proposals offset) candidate.fact.claim;
      check int "followup preserves the existing queue sequence" (prior_sequence + offset + 1)
        candidate.sequence) followup_candidates;
    let followup_ids = Queue.candidate_ids followup in
    List.iter (fun (id : Current.explicit_candidate_id) ->
      check string "followup keeps original queue generation" generation id.queue_generation) followup_ids;
    let stores = ["current_snapshot", current_path;
      "consumption_and_lookup_receipt", Current.durable_range_receipt_path ~keepers_dir ~keeper_id;
      "memory_journal", Current.journal_path_for_keepers_dir ~keepers_dir ~keeper_id;
      "pending_queue", queue_path] in
    let before = List.map (fun (name,path) -> name, Fs_compat.load_file_opt path) stores in
    let state_bundle = `Assoc (List.map (fun (name,bytes) -> name,
      match bytes with None -> `Assoc ["present",`Bool false]
      | Some bytes -> `Assoc ["present",`Bool true;"bytes",`String bytes;
          "sha256",`String (sha256 bytes)]) before) in
    let captured = ref [] and followup_commits = ref 0 and deferred = ref 0 in
    let runner ~runtime_id ~system_prompt ~output_schema ~prompt =
      captured := (runtime_id,system_prompt,output_schema,prompt) :: !captured;
      Ok (Yojson.Safe.to_string (`Assoc ["memory",`Assoc ["working_contexts",`List [];
        "new_claims",`List [];"dropped",`List []];"change_support",`List [];
        "candidates",`List (List.map (fun (candidate : Queue.candidate) ->
          `Assoc ["request_id",`String candidate.request_id;"outcome",`String "deferred";
            "memory_claim",`Null;"reason",`String "Capture only; no semantic judgment performed."])
          followup_candidates)])) in
    let prior_followup_runs = Runs.list_runs (Runs.global ()) in
    let captured_at = Time_compat.now () in
    Runtime.run_best_effort ~write_scope:Runtime.Memory_maintenance ~admission:followup ~cli_runner:runner
      ~on_memory_committed:(fun () -> incr followup_commits)
      ~on_admission_deferred:(fun () -> incr deferred)
      ~base_path ~keepers_dir ~keeper_id
      ~expected_revision:(Option.map (fun (snapshot : Current.t) -> snapshot.revision) current)
      {selected_input with current=Option.map (fun (snapshot : Current.t) ->
         ({Librarian.facts=snapshot.facts} : Librarian.current_selection)) current};
    check int "capture-only followup commits nothing" 0 !followup_commits;
    check int "capture response reaches valid all-deferred branch" 1 !deferred;
    let followup_runs = Runs.list_runs (Runs.global ()) |> List.filter (fun (run : Runs.run) ->
      not (List.exists (fun (prior : Runs.run) -> prior.run_id = run.run_id) prior_followup_runs)) in
    (match followup_runs with [ {status=Runs.Completed {outcome=Runs.Succeeded; _}; _} ] -> ()
      | _ -> fail "followup capture must complete the real decoder");
    Queue.acknowledge_committed ~keepers_dir ~keeper_id |> require;
    List.iter (fun (name,path) -> check (option string) (name ^ " unchanged by capture")
      (List.assoc name before) (Fs_compat.load_file_opt path)) stores;
    let runtime_id,system_prompt,schema,prompt = match !captured with
      | [request] -> request | _ -> fail "expected one followup request" in
    let candidate_rows = `List (List.map candidate_json followup_candidates) in
    let initial_rows = `List (List.map Memory.fact_to_json current_facts) in
    let scenario_input = `Assoc ["predecessor_fixture",`String filename;
      "predecessor_response_sha256",`String (sha256 response_raw);
      "proposed_claims",`List (List.map (fun claim -> `String claim) followup_proposals)] in
    let export = `Assoc ["cohort",`String (cohort ^ "_followup");
      "measurement",`String "production_rendered_synthetic_followup_capture";
      "semantic_judgment_performed",`Bool false;"captured_at",`Float captured_at;
      "phase",`String "after_predecessor_recall_and_followup_enqueue_before_retirement";
      "predecessor_fixture",`String filename;"predecessor_response_sha256",`String (sha256 response_raw);
      "keeper_id",`String keeper_id;"trace_id",`String trace_id;"absolute_turn",`Int 0;
      "runtime_id",`String runtime_id;"system_prompt",`String system_prompt;"prompt",`String prompt;
      "schema",schema;"candidates",candidate_rows;"initial_current_facts",initial_rows;
      "initial_snapshot_present",`Bool (Option.is_some current);"scenario_input",scenario_input;
      "keeper_instructions",`String instructions;"state_bundle",state_bundle;
      "candidate_receipts",`List (List.map (fun (id : Current.explicit_candidate_id) ->
        `Assoc ["queue_generation",`String id.queue_generation;"request_id",`String id.request_id;
          "sequence",`Int id.sequence;"input_sha256",`String id.input_sha256]) followup_ids);
      "input_hashes",`Assoc ["scenario_input_sha256",`String (hash_json scenario_input);
        "prompt_sha256",`String (sha256 prompt);"system_prompt_sha256",`String (sha256 system_prompt);
        "schema_sha256",`String (hash_json schema);"candidates_sha256",`String (hash_json candidate_rows);
        "initial_current_facts_sha256",`String (hash_json initial_rows);
        "keeper_instructions_sha256",`String (sha256 instructions)]] in
    Printf.printf "MEMORY_ADMISSION_FOLLOWUP_EXPORT %s\n%!" (Yojson.Safe.to_string export));
  (* An identical claim created later is a new admission. Old candidate
     provenance must not attach itself to that new incarnation. This uses
     the real replacement path after the measured replay, not a sidecar edit. *)
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
        |> List.exists (fun matched -> json_string "text" matched = replacement)) after));
  let retirement_probe = match current, recall_bindings with
    | Some snapshot, _ :: _ ->
      let source = {Current.kind=Current.Explicit_write; trace_id="synthetic-retirement-probe"} in
      let retired = Current.replace ~keepers_dir ~keeper_id
        ~expected_revision:(Some snapshot.revision) ~now:(Time_compat.now ())
        ~source ~facts:[] () |> require in
      let _, retired_bindings =
        Current.read_with_admission_recall_for_keepers_dir ~keepers_dir ~keeper_id |> require in
      check int "retired target exposes no current lookup binding" 0 (List.length retired_bindings);
      let recalled_retired = recall () in
      List.iter (fun result -> check int "retired current memory cannot answer"
        0 (member "response" result |> member "match_count" |> Yojson.Safe.Util.to_int))
        recalled_retired;
      ignore (Current.replace ~keepers_dir ~keeper_id
        ~expected_revision:(Some retired.revision) ~now:(Time_compat.now ())
        ~source ~facts:current_facts () |> require : Current.t);
      let _, readded_bindings =
        Current.read_with_admission_recall_for_keepers_dir ~keepers_dir ~keeper_id |> require in
      check int "identical re-add cannot revive old admission bindings" 0
        (List.length readded_bindings);
      `Assoc ["performed",`Bool true; "binding_count_before",`Int (List.length recall_bindings);
        "bindings_after_retirement",`Int (List.length retired_bindings);
        "bindings_after_identical_readd",`Int (List.length readded_bindings)]
    | None, _ | Some _, [] -> `Assoc ["performed",`Bool false] in
  let actual_outcome = if not !injected then Capture_not_current
    else if receipts<>[] then Committed_and_acknowledged else Not_committed in
  let payload = `Assoc ["fixture",`String filename; "cohort",`String cohort;
    "response_sha256",`String (sha256 response_raw); "model_metadata",model_metadata;
    "model_schema_encoding",`String (schema_encoding_label model_schema_encoding);
    "gate_policy",`Assoc ["scope",`String "fixture_declared_off_not_live_gate_evidence";
      "lane_enabled",`Bool false; "absorb_gate",`Bool false];
    "actual_request",request_hashes current_request;
    "response_replayed",`Bool !injected;
    "actual_outcome",`String (outcome_label actual_outcome);
    "current_facts",`List (List.map Memory.fact_to_json current_facts);
    "current_snapshot_present",`Bool (Option.is_some current);
    "restored_state",restored_state;
    "recall_before",`List recall_before;
    "recall_all_before",`List recall_all_before;
    "recall_after",`List recall_after;
    "storage_after",storage_after;
    "recall_all_after",`List recall_all_after;
    "retirement_probe",retirement_probe;
    "pending",`List (List.map candidate_json pending);
    "not_committed",`List (List.rev_map (fun (reason : Runtime.not_committed) ->
      `Assoc ["detail",`String reason.detail; "walk_shows_size",`Bool reason.walk_shows_size]) !refusals);
    "exact_run",Runs.run_to_yojson exact_run] in
  Printf.printf "MEMORY_ADMISSION_REPLAY %s\n%!" (Yojson.Safe.to_string payload);
  actual_outcome

type lookup_failure_fixture = Journal_gap | Malformed_receipts | Unreadable_receipts

let test_incomplete_lookup_keeps_direct_search_with failure () =
  with_workspace @@ fun ~base_path ->
  let keeper_id = "lookup-gap" and trace_id = "lookup-gap-test" in
  let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path in
  let fact claim : Memory.fact =
    { claim; category=Memory.Constraint; first_seen=100.; last_seen=100.;
      origin={kind=Memory.Authored; trace_id}; basis=Memory.Observed Memory.Transcript } in
  let target = fact "Current consolidated policy" in
  let evidence = fact "UNIQUE-HISTORICAL-ALIAS" in
  ignore (Queue.append ~keepers_dir ~keeper_id ~request_id:"lookup-gap-input" evidence
    |> require : Queue.candidate);
  let batch = match Queue.read_pending ~keepers_dir ~keeper_id |> require with
    | Some batch -> batch | None -> fail "missing candidate" in
  let candidate_id = match Queue.candidate_ids batch with
    | [id] -> id | _ -> fail "expected one candidate" in
  let binding : Current.admission_recall_binding =
    {candidate_id; source_fact=evidence; target_memory_id=Memory.memory_id target} in
  let born = Current.apply_disposition ~explicit_candidate_ids:[candidate_id]
    ~admission_recall:{decided_at_revision=None; bindings=[binding]} ~absorbed:[] ~revisions:[]
    ~keepers_dir ~keeper_id ~now:200. ~source:{Current.kind=Current.Librarian;trace_id}
    ~new_claims:[target] () |> require in
  ignore (Current.replace ~keepers_dir ~keeper_id ~expected_revision:(Some born.snapshot.revision) ~now:300.
    ~source:{Current.kind=Current.Explicit_write;trace_id}
    ~facts:[target;fact "UNRELATED-CURRENT-FACT"] () |> require : Current.t);
  (match failure with
   | Journal_gap ->
       let journal = Current.journal_path_for_keepers_dir ~keepers_dir ~keeper_id in
       Fs_compat.invalidate_cached_writer journal;
       Fs_compat.save_file journal ""
   | Malformed_receipts | Unreadable_receipts ->
       let path = Current.durable_range_receipt_path ~keepers_dir ~keeper_id in
       Sys.remove path;
       (match failure with
        | Malformed_receipts -> Fs_compat.save_file path "not-json"
        | Unreadable_receipts -> Fs_compat.mkdir_p path
        | Journal_gap -> fail "unexpected journal fixture"));
  let snapshot, coverage =
    Current.read_with_admission_recall_status_for_keepers_dir ~keepers_dir ~keeper_id |> require in
  check bool "healthy snapshot survives unavailable alias proof" true (Option.is_some snapshot);
  check bool "missing provenance remains an explicit error" true (Result.is_error coverage);
  check bool "strict recall still refuses uncertain aliases" true
    (Result.is_error (Current.read_with_admission_recall_for_keepers_dir ~keepers_dir ~keeper_id));
  let config = Masc.Workspace.default_config base_path in
  let meta = Masc_test_deps.meta_of_json_fixture
    (`Assoc ["name",`String keeper_id;"trace_id",`String trace_id]) |> require in
  List.iter (fun source ->
    let search query =
      Masc.Keeper_tool_memory_runtime.keeper_memory_search_json ~config ~meta
        ~ctx_work:(Masc.Keeper_context_runtime.create ~eio:false ~system_prompt:"")
        ~args:(`Assoc ["source",`String source;"query",`String query])
      |> Yojson.Safe.from_string in
    let direct = search "UNRELATED-CURRENT-FACT" in
    check int "unrelated current fact remains searchable" 1
      (member "match_count" direct |> Yojson.Safe.Util.to_int);
    let alias = search "UNIQUE-HISTORICAL-ALIAS" in
    check int "unverifiable historical alias is withheld" 0
      (member "match_count" alias |> Yojson.Safe.Util.to_int);
    check bool "incomplete lookup never asserts absence" true (member "no_match" alias = `Null);
    List.iter (fun result -> check string "lookup gap is model-visible" "incomplete"
      (member "admission_lookup_verification" result |> json_string "status")) [direct;alias])
    ["current";"all"]

let () =
  let manifest = Yojson.Safe.from_file (Masc_test_deps.source_path
      (Filename.concat fixture_dir "manifest.json")) in
  let entries = json_list "fixtures" manifest |> List.map (fun entry ->
    json_string "file" entry, outcome_of_label (json_string "expected_outcome" entry)) in
  let filenames = List.map fst entries in
  if filenames = [] then fail "replay manifest must contain actual response fixtures";
  check bool "replay manifest includes the required followup scenario" true
    (List.mem "independent_200.json" filenames);
  check bool "replay manifest includes the required verified replacement" true
    (List.mem "verified_replacement.json" filenames);
  List.iter (fun name ->
    if name = "" || Filename.basename name <> name then fail "manifest fixture must be a basename") filenames;
  if List.length (List.sort_uniq String.compare filenames) <> List.length filenames then
    fail "duplicate replay fixture in manifest";
  run "synthetic admission exact store replay"
    ["responses",List.map (fun (name, expected_outcome) ->
      test_case name `Quick (fun () ->
        check outcome_testable "replay reaches the manifest's expected outcome"
          expected_outcome (replay name ()))) entries;
     "lookup coverage",[test_case "incomplete provenance preserves direct search" `Quick
       (test_incomplete_lookup_keeps_direct_search_with Journal_gap);
       test_case "malformed receipts preserve direct search" `Quick
         (test_incomplete_lookup_keeps_direct_search_with Malformed_receipts);
       test_case "unreadable receipts preserve direct search" `Quick
         (test_incomplete_lookup_keeps_direct_search_with Unreadable_receipts)]]
