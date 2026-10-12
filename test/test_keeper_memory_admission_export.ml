open Alcotest

(* Measurement fixture: captures production-rendered requests, without a provider.
   The injected response defers everything solely to leave stores unchanged;
   it is not an expected semantic judgment for any cohort. Run with -v to export.
   Independent policy applicability is not a required output row count: an exact
   scoped consolidation may preserve R-001..R-200, while "all releases" would
   wrongly extend it to R-201. Later quality evaluation must test recoverable
   applicability, exclusions and changed policy, not literal sentence replay. *)
module Librarian = Masc.Keeper_librarian
module Runtime = Masc.Keeper_librarian_runtime
module Memory = Masc.Keeper_memory_os_types
module Current = Masc.Keeper_memory_os_current
module Queue = Masc.Keeper_memory_admission_queue
module Fixture = Exact_output_fixture

let () = Masc.Prompt_defaults.init ()
let require = function Ok value -> value | Error detail -> fail detail
let sha256 bytes = Digestif.SHA256.(digest_string bytes |> to_hex)
let hash_json json = sha256 (Yojson.Safe.to_string json)

let instructions =
  "Remember durable release policy and verified changes, keeping separate release IDs and environments distinct. Do not retain one-off check/run receipts. Unconfirmed guesses or observations without a known event/environment remain deferred. Incidental check numbers add no durable knowledge."

let prior_policy = "Production release P-42 requires owner approval before deployment."
let fact claim = Memory.observed ~claim ~category:Memory.Fact ~now:(Time_compat.now ())
  ~origin:{kind=Memory.Authored; trace_id="synthetic-initial-policy"}

type cohort =
  { name : string
  ; initial_claims : string list
  ; proposed_claims : string list
  }

let cohorts =
  List.concat_map (fun count ->
    [ {name=Printf.sprintf "repeated_%d" count; initial_claims=[prior_policy];
       proposed_claims=List.init count (fun index -> Printf.sprintf
         "Synthetic check %d reconfirmed the unchanged production P-42 owner-approval policy."
         (index+1))};
      {name=Printf.sprintf "independent_%d" count; initial_claims=[];
       proposed_claims=List.init count (fun index -> Printf.sprintf
         "Verified policy: production release R-%03d requires owner approval before deployment."
         (index+1))} ]) [1;30;200]
  @ [ {name="verified_replacement"; initial_claims=[prior_policy];
       proposed_claims=["Owner-approved policy revision replaces the prior production P-42 rule: deployment now requires two independent approvals."]};
      {name="unresolved_event"; initial_claims=[prior_policy];
       proposed_claims=["The incident now needs two approvals; neither incident identity nor environment is known."]} ]

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

let export cohort () = with_workspace @@ fun ~base_path ->
  Fixture.with_official_client_runtimes @@ fun () ->
  Prompt_registry.set_markdown_dir (Masc_test_deps.source_path "config/prompts");
  (* No API slot exists and the sole CLI runner is injected below. *)
  ignore (Fixture.publish_registry ~cli_slot_ids:[Fixture.cli_primary_runtime]
    ~lane_id:"librarian_exact" ~slot_ids:[]
    (Fixture.resolver_snapshot ~source:"synthetic admission export"
       [{Fixture.id="unused-synthetic-slot"; base_url="http://127.0.0.1:1"}])
    : Runtime_exact_output_registry.t);
  let keeper_id = "synthetic-" ^ String.map (function '_' -> '-' | c -> c) cohort.name in
  let trace_id = "synthetic-admission-export" in
  let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path in
  let config = Masc.Workspace.default_config base_path in
  let meta = Masc_test_deps.meta_of_json_fixture
    (`Assoc ["name",`String keeper_id; "trace_id",`String trace_id]) |> require in
  let meta = {meta with Masc.Keeper_meta_contract.instructions=instructions} in
  let initial_facts = List.map fact cohort.initial_claims in
  let initial = match initial_facts with
    | [] -> None
    | _ -> Some (Current.replace ~keepers_dir ~keeper_id ~expected_revision:None
        ~now:(Time_compat.now ()) ~source:{Current.kind=Current.Explicit_write; trace_id}
        ~facts:initial_facts () |> require) in
  let current_path = Current.path_for_keepers_dir ~keepers_dir ~keeper_id in
  let current_before = Fs_compat.load_file_opt current_path in
  List.iter (fun content ->
    let result = Masc.Keeper_tool_memory_runtime.keeper_memory_write_with_outcome
      ~config ~meta ~args:(`Assoc ["content",`String content]) in
    let receipt = Yojson.Safe.from_string result.raw_output in
    check string "producer persisted candidate" "persisted_pending_admission"
      Yojson.Safe.Util.(receipt |> member "outcome" |> to_string)) cohort.proposed_claims;
  let admission = match Queue.read_pending ~keepers_dir ~keeper_id |> require with
    | Some batch -> batch | None -> fail "producer left no candidate batch" in
  let candidates = Queue.candidates admission in
  check int "every proposed input reached the real queue"
    (List.length cohort.proposed_claims) (List.length candidates);
  let queue_path = Queue.path ~keepers_dir ~keeper_id in
  let queue_before = Fs_compat.load_file queue_path in
  let selected_input : Librarian.input =
    { keeper_id=Masc_test_deps.keeper_id_fixture keeper_id;
      keeper_instructions=meta.instructions;
      turn_ref=Ids.Turn_ref.make ~trace_id ~absolute_turn:0;
      current=Option.map (fun (snapshot : Current.t) ->
        ({Librarian.facts=snapshot.facts} : Librarian.current_selection)) initial;
      historical_task_contexts=[]; goal_context=Librarian.No_task;
      working_context=Masc.Keeper_librarian_context.empty;
      messages=[]; tool_observations=[]; counterpart_observations=[] } in
  let captured = ref [] in
  let runner ~runtime_id ~system_prompt ~output_schema ~prompt =
    captured := (runtime_id,system_prompt,output_schema,prompt) :: !captured;
    Ok (Yojson.Safe.to_string (`Assoc [
      "memory", `Assoc ["working_contexts",`List []; "new_claims",`List []; "dropped",`List []];
      "change_support", `List [];
      "candidates", `List (List.map (fun (candidate : Queue.candidate) ->
        `Assoc ["request_id",`String candidate.request_id; "outcome",`String "deferred";
                "memory_claim",`Null; "reason",`String "Capture-only fixture; no semantic judgment was performed."])
        candidates)])) in
  let committed = ref 0 and not_committed = ref 0 in
  Runtime.run_best_effort ~write_scope:Runtime.Memory_maintenance ~admission ~cli_runner:runner
    ~on_memory_committed:(fun () -> incr committed)
    ~on_not_committed:(fun _ -> incr not_committed)
    ~base_path ~keepers_dir ~keeper_id
    ~expected_revision:(Option.map (fun (value : Current.t) -> value.revision) initial)
    selected_input;
  let module Runs = Masc.Exact_lane_run_registry in
  let runs = Runs.list_runs (Runs.global ()) |> List.filter
    (fun (run : Runs.run) -> String.equal run.actor keeper_id) in
  (match runs with
   | [{status=Runs.Completed {outcome=Runs.Succeeded; _}; _}] -> ()
   | _ -> fail "capture response did not complete through the real admission decoder");
  check int "capture response commits no Memory" 0 !committed;
  check int "runtime reports a retained batch" 1 !not_committed;
  Queue.acknowledge_committed ~keepers_dir ~keeper_id |> require;
  check string "no pending input consumed" queue_before (Fs_compat.load_file queue_path);
  check (option string) "current snapshot remains byte-exact or absent" current_before
    (Fs_compat.load_file_opt current_path);
  let runtime_id,system_prompt,schema,prompt = match !captured with
    | [capture] -> capture | _ -> fail "expected one complete production-rendered request" in
  let candidate_rows = `List (List.map candidate_json candidates) in
  let initial_rows = `List (List.map Memory.fact_to_json initial_facts) in
  (* Identities computed from the pending batch. The capture defers every
     candidate, so none of them is a committed consumption receipt. *)
  let identities = Queue.candidate_ids admission in
  let generation = match identities with
    | (first : Current.explicit_candidate_id) :: _ -> first.queue_generation
    | [] -> fail "pending batch produced no candidate identity" in
  check int "capture commits no candidate receipt" 0
    (List.length (Current.committed_explicit_candidates ~keepers_dir ~keeper_id
       ~queue_generation:generation |> require));
  let scenario_input = `Assoc ["cohort",`String cohort.name;
    "keeper_instructions",`String instructions;
    "initial_claims",`List (List.map (fun s -> `String s) cohort.initial_claims);
    "proposed_claims",`List (List.map (fun s -> `String s) cohort.proposed_claims)] in
  let payload = `Assoc [
    "cohort",`String cohort.name; "measurement",`String "production_rendered_synthetic_capture";
    "semantic_judgment_performed",`Bool false;
    "runtime_id",`String runtime_id; "system_prompt",`String system_prompt;
    "prompt",`String prompt; "schema",schema;
    "candidates",candidate_rows; "initial_current_facts",initial_rows;
    "initial_snapshot_present",`Bool (Option.is_some initial);
    "scenario_input",scenario_input;
    "keeper_instructions",`String instructions;
    "candidate_receipts",`List (List.map (fun (id : Current.explicit_candidate_id) ->
      `Assoc ["queue_generation",`String id.queue_generation; "request_id",`String id.request_id;
              "sequence",`Int id.sequence; "input_sha256",`String id.input_sha256]) identities);
    "input_hashes",`Assoc ["scenario_input_sha256",`String (hash_json scenario_input);
      "prompt_sha256",`String (sha256 prompt);
      "system_prompt_sha256",`String (sha256 system_prompt);
      "schema_sha256",`String (hash_json schema);
      "candidates_sha256",`String (hash_json candidate_rows);
      "initial_current_facts_sha256",`String (hash_json initial_rows);
      "keeper_instructions_sha256",`String (sha256 instructions)] ] in
  Printf.printf "MEMORY_ADMISSION_EXPORT %s\n%!" (Yojson.Safe.to_string payload)

let () = run "synthetic admission request export"
  ["cohorts", List.map (fun cohort -> test_case cohort.name `Quick (export cohort)) cohorts]
