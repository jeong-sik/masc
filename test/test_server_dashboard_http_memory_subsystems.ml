open Alcotest

module Json = Yojson.Safe.Util
module Memory_subsystems = Server_dashboard_http_memory_subsystems
module Memory_io = Masc.Keeper_memory_os_io
module P = Masc.Procedural_memory
module Projection = Masc.Skill_candidate_projection
module Recall_ledger = Masc.Keeper_recall_injection_ledger
module Store = Masc.Skill_candidate_store
module Delegation_request = Masc.Keeper_delegation_request
module Delegation_store = Masc.Keeper_delegation_request_store
module Types = Masc.Keeper_memory_os_types

let request target =
  Httpun.Request.create ~headers:(Httpun.Headers.of_list []) `GET target
;;

let check_include target expected =
  check
    bool
    target
    expected
    (Memory_subsystems.dashboard_memory_subsystems_include_entries (request target))
;;

let temp_dir () =
  Filename.temp_dir "memory_subsystems_dashboard_test" ""
;;

let rm_rf dir =
  let rec rm path =
    if Sys.file_exists path
    then
      if Sys.is_directory path
      then (
        Sys.readdir path |> Array.iter (fun entry -> rm (Filename.concat path entry));
        Unix.rmdir path)
      else Sys.remove path
  in
  try rm dir with
  | _ -> ()
;;

let test_include_entries_query_param () =
  check_include "/dashboard/memory-subsystems" false;
  check_include "/dashboard/memory-subsystems?include_memory_entries=1" true;
  check_include "/dashboard/memory-subsystems?include_memory_entries=true" true;
  check_include "/dashboard/memory-subsystems?include_memory_entries=yes" true;
  check_include "/dashboard/memory-subsystems?include_memory_entries=y" true;
  check_include "/dashboard/memory-subsystems?include_memory_entries=0" false;
  check_include "/dashboard/memory-subsystems?include_memory_entries=false" false;
  check_include "/dashboard/memory-subsystems?include_memory_entries=no" false;
  check_include "/dashboard/memory-subsystems?include_memory_entries=n" false
;;

let test_focus_entries_enables_memory_entries () =
  check_include "/dashboard/memory-subsystems?focus=entries" true;
  check_include "/dashboard/memory-subsystems?focus=%20entries%20" true;
  check_include "/dashboard/memory-subsystems?focus=episodes" false
;;

let test_http_json_explicitly_disabled_entries_surface () =
  let dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> rm_rf dir)
    (fun () ->
      let config = Workspace_utils.default_config dir in
      let json =
        Memory_subsystems.dashboard_memory_subsystems_http_json
          ~config
          ~include_memory_entries:false
          (request "/dashboard/memory-subsystems?limit=9999&focus=entries")
      in
      let memory_entries = Json.(json |> member "memory_entries") in
      check int "memory total" 0 Json.(memory_entries |> member "total" |> to_int);
      check
        int
        "memory filtered"
        0
        Json.(memory_entries |> member "filtered" |> to_int);
      check int "memory shown" 0 Json.(memory_entries |> member "shown" |> to_int);
      check int "limit clamped" 500 Json.(memory_entries |> member "limit" |> to_int);
      check
        int
        "items empty"
        0
        Json.(memory_entries |> member "items" |> to_list |> List.length))
;;

let fact ?(category = Types.Preference) ?(trace_id = "trace-user-model")
      ?(turn = 3) ?(first_seen = 10.0) ?last_verified_at claim
  : Types.fact
  =
  { claim
  ; category
  ; external_ref = None
  ; claim_kind = None
  ; source = { trace_id; turn; tool_call_id = None }
  ; observed_by = []
  ; first_seen
  ; valid_until = None
  ; last_verified_at
  ; schema_version = Types.schema_version
  ; claim_id = None
  }
;;

let test_http_json_surfaces_user_model_projection () =
  let dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> rm_rf dir)
    (fun () ->
      let config = Workspace_utils.default_config dir in
      let keepers_dir =
        Config_dir_resolver.keepers_dir_for_base_path ~base_path:config.base_path
      in
      Memory_io.For_testing.with_keepers_dir keepers_dir (fun () ->
        Memory_io.append_fact
          ~keeper_id:"sangsu"
          (fact ~category:Types.Preference ~last_verified_at:20.0
             "User prefers terse operational summaries");
        Memory_io.append_fact
          ~keeper_id:"sangsu"
          (fact ~category:Types.Constraint ~trace_id:"trace-constraint" ~turn:4
             "User requires worktree-first changes");
        Memory_io.append_fact
          ~keeper_id:"sangsu"
          (fact ~category:Types.Fact "The repo uses OCaml");
        let json =
          Memory_subsystems.dashboard_memory_subsystems_http_json
            ~config
            ~include_memory_entries:false
            (request "/dashboard/memory-subsystems?limit=100")
        in
        let user_model = Json.(json |> member "user_model") in
        check string "schema" "masc.user_model.memory_projection.v1"
          Json.(user_model |> member "schema" |> to_string);
        let prompt = Json.(user_model |> member "prompt") in
        check string "prompt block id" "user_model"
          Json.(prompt |> member "block_id" |> to_string);
        check string "prompt injection" "extra_system_context"
          Json.(prompt |> member "injection" |> to_string);
        check string "prompt hook" "keeper_run_tools_hooks.before_turn_params"
          Json.(prompt |> member "runtime_hook" |> to_string);
        check int "total" 2 Json.(user_model |> member "total" |> to_int);
        check int "shown" 2 Json.(user_model |> member "shown" |> to_int);
        let items = Json.(user_model |> member "items" |> to_list) in
        let claims =
          items |> List.map (fun item -> Json.(item |> member "claim" |> to_string))
        in
        check
          (list string)
          "preference and constraint only"
          [ "User prefers terse operational summaries"
          ; "User requires worktree-first changes"
          ]
          claims))
;;

let test_http_json_user_model_uses_config_base_path () =
  let dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> rm_rf dir)
    (fun () ->
      let config = Workspace_utils.default_config dir in
      let base_keepers_dir =
        Config_dir_resolver.keepers_dir_for_base_path ~base_path:config.base_path
      in
      Memory_io.For_testing.with_keepers_dir base_keepers_dir (fun () ->
        Memory_io.append_fact
          ~keeper_id:"target"
          (fact ~category:Types.Preference "Target workspace preference"));
      let ambient_keepers_dir = Filename.concat dir "ambient-keepers" in
      Memory_io.For_testing.with_keepers_dir ambient_keepers_dir (fun () ->
        Memory_io.append_fact
          ~keeper_id:"ambient"
          (fact ~category:Types.Preference "Ambient workspace preference");
        let json =
          Memory_subsystems.dashboard_memory_subsystems_http_json
            ~config
            ~include_memory_entries:false
            (request "/dashboard/memory-subsystems?limit=100")
        in
        let user_model = Json.(json |> member "user_model") in
        let items = Json.(user_model |> member "items" |> to_list) in
        let claims =
          items |> List.map (fun item -> Json.(item |> member "claim" |> to_string))
        in
        check (list string) "scoped claims" [ "Target workspace preference" ] claims))
;;

let skill_candidate () =
  let procedure : P.procedure =
    { id = "dashboard-visible-skill"
    ; agent_name = "keeper"
    ; pattern = "When the same repair loop succeeds repeatedly, draft a skill"
    ; evidence = [ "proof-store://abc"; "proof-store://def"; "proof-store://ghi" ]
    ; success_count = 3
    ; failure_count = 0
    ; confidence = 1.0
    ; created_at = 0.0
    ; last_applied = 0.0
    }
  in
  match Projection.candidate_of_procedure procedure with
  | Some candidate -> candidate
  | None -> fail "expected dashboard skill candidate"
;;

let test_http_json_surfaces_draft_skill_candidates () =
  let dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> rm_rf dir)
    (fun () ->
      let config = Workspace_utils.default_config dir in
      let candidate = skill_candidate () in
      (match Store.write_candidate ~base_path:dir candidate with
       | Ok _ -> ()
       | Error msg -> fail msg);
      let json =
        Memory_subsystems.dashboard_memory_subsystems_http_json
          ~config
          ~include_memory_entries:false
          (request "/dashboard/memory-subsystems?limit=100")
      in
      let drafts = Json.(json |> member "draft_skill_candidates") in
      check int "draft total" 1 Json.(drafts |> member "total" |> to_int);
      check int "draft shown" 1 Json.(drafts |> member "shown" |> to_int);
      check string "draft index path"
        (Store.index_path ~base_path:dir)
        Json.(drafts |> member "index_path" |> to_string);
      let item =
        match Json.(drafts |> member "items" |> to_list) with
        | [ item ] -> item
        | _ -> fail "expected one draft skill candidate"
      in
      check string "candidate id" candidate.id Json.(item |> member "id" |> to_string);
      check string "candidate state" "candidate"
        Json.(item |> member "promotion_state" |> to_string);
       check string "skill path suffix" "SKILL.md"
         (Filename.basename Json.(item |> member "skill_md_path" |> to_string)))
;;

let test_http_json_surfaces_delegation_requests () =
  let dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> rm_rf dir)
    (fun () ->
      let config = Workspace_utils.default_config dir in
      let delegation =
        Delegation_request.make ~requester:"planner"
          ~goal:"ship connector parity"
          ~topic:"Review non-dashboard rendering"
          ~reason:"existing channels lose rich blocks"
          ()
      in
      (match Delegation_store.write_request ~base_path:dir delegation with
       | Ok _ -> ()
       | Error msg -> fail msg);
      let json =
        Memory_subsystems.dashboard_memory_subsystems_http_json
          ~config
          ~include_memory_entries:false
          (request "/dashboard/memory-subsystems?limit=100")
      in
      let requests = Json.(json |> member "delegation_requests") in
      check int "delegation total" 1 Json.(requests |> member "total" |> to_int);
      check int "delegation shown" 1 Json.(requests |> member "shown" |> to_int);
      check string "delegation index path"
        (Delegation_store.index_path ~base_path:dir)
        Json.(requests |> member "index_path" |> to_string);
      let item =
        match Json.(requests |> member "items" |> to_list) with
        | [ item ] -> item
        | _ -> fail "expected one delegation request"
      in
      check string "delegation id" delegation.id
        Json.(item |> member "id" |> to_string);
      check string "delegation requester" "planner"
        Json.(item |> member "requester" |> to_string);
      check string "task seed suffix" "TASK_SEED.md"
        (Filename.basename Json.(item |> member "task_seed_md_path" |> to_string)))
;;

let shared_fact ?(observed_by = []) ?(last_verified_at = 10.0) claim : Types.fact =
  { claim
  ; category = Types.Fact
  ; external_ref = None
  ; claim_kind = None
  ; source = { trace_id = "shared"; turn = 1; tool_call_id = None }
  ; observed_by
  ; first_seen = 10.0
  ; valid_until = None
  ; last_verified_at = Some last_verified_at
  ; schema_version = Types.schema_version
  ; claim_id = None
  }
;;

let append_recall_record
      ?failure_reason
      ~(config : Workspace_utils.config)
      ~keeper_id
      ~trace_id
      ~turn
      ~injected_fact_keys
      ~injected_episode_keys
      ~n_facts_in_store
      ()
  =
  let masc_root = Workspace_utils.masc_dir config in
  let store =
    Dated_jsonl.create
      ~base_dir:(Recall_ledger.base_dir ~masc_root)
      ()
  in
  Recall_ledger.to_json
    ?failure_reason
    ~keeper_id
    ~trace_id
    ~turn
    ~injected_fact_keys
    ~injected_episode_keys
    ~n_facts_in_store
    ~now:(float_of_int turn)
    ()
  |> Dated_jsonl.append store
;;

let append_malformed_recall_record ~(config : Workspace_utils.config) =
  let masc_root = Workspace_utils.masc_dir config in
  let store =
    Dated_jsonl.create
      ~base_dir:(Recall_ledger.base_dir ~masc_root)
      ()
  in
  Dated_jsonl.append
    store
    (`Assoc
      [ "keeper_id", `String "keeper-bad"
      ; "injected_fact_keys", `List [ `Int 1 ]
      ; "injected_episode_keys", `List []
      ])
;;

let legacy_unstructured_fallback_fact_key () =
  Types.claim_identity
    (fact (Types.librarian_unstructured_fallback_claim_prefix ^ " (provider): raw"))
;;

let test_http_json_surfaces_memory_quality_summary () =
  let dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> rm_rf dir)
    (fun () ->
       let config = Workspace_utils.default_config dir in
       let fallback_key = legacy_unstructured_fallback_fact_key () in
       append_recall_record
         ~config
         ~keeper_id:"keeper-a"
         ~trace_id:"trace-1"
         ~turn:1
         ~injected_fact_keys:[ "id:stable"; fallback_key ]
         ~injected_episode_keys:[]
         ~n_facts_in_store:10
         ();
       append_recall_record
         ~config
         ~keeper_id:"keeper-a"
         ~trace_id:"trace-2"
         ~turn:2
         ~injected_fact_keys:[ "id:stable" ]
         ~injected_episode_keys:[ "trace-2:g0" ]
         ~n_facts_in_store:10
         ();
       append_recall_record
         ~failure_reason:"prompt_render_error"
         ~config
         ~keeper_id:"keeper-b"
         ~trace_id:"trace-3"
         ~turn:3
         ~injected_fact_keys:[]
         ~injected_episode_keys:[]
         ~n_facts_in_store:0
         ();
       let json =
         Memory_subsystems.dashboard_memory_subsystems_http_json
           ~config
           ~include_memory_entries:false
           (request "/dashboard/memory-subsystems?limit=100")
       in
       let quality = Json.(json |> member "memory_quality") in
       check string "quality schema" "masc.memory_quality.recall_ledger.v1"
         Json.(quality |> member "schema" |> to_string);
       check int "sampled records" 3
         Json.(quality |> member "sampled_records" |> to_int);
       check int "records with recall" 2
         Json.(quality |> member "records_with_recall" |> to_int);
       check int "empty recall records" 1
         Json.(quality |> member "empty_recall_records" |> to_int);
       check int "failure records" 1
         Json.(quality |> member "failure_records" |> to_int);
       check int "decode error records" 0
         Json.(quality |> member "decode_error_records" |> to_int);
       check bool "outcome not joined in dashboard summary" false
         Json.(quality |> member "outcome_joined" |> to_bool);
       let fact_injections = Json.(quality |> member "fact_injections") in
       check int "total fact injections" 3
         Json.(fact_injections |> member "total" |> to_int);
       check int "unique fact keys" 2
         Json.(fact_injections |> member "unique_fact_keys" |> to_int);
       check int "echoed fact keys" 1
         Json.(fact_injections |> member "echoed_fact_keys" |> to_int);
       check int "max fact echo count" 2
         Json.(fact_injections |> member "max_fact_echo_count" |> to_int);
       let echoed = Json.(fact_injections |> member "top_echoed_fact_keys" |> to_list) in
       check int "one echoed top key" 1 (List.length echoed);
       let top_echo = List.hd echoed in
       check string "top echoed key" "id:stable"
         Json.(top_echo |> member "key" |> to_string);
       check int "top echoed count" 2
         Json.(top_echo |> member "count" |> to_int);
       let reasons = Json.(quality |> member "failure_reasons" |> to_list) in
       check int "one failure reason" 1 (List.length reasons);
       let reason = List.hd reasons in
       check string "failure reason key" "prompt_render_error"
         Json.(reason |> member "key" |> to_string);
       check int "failure reason count" 1
         Json.(reason |> member "count" |> to_int))
;;

let test_http_json_surfaces_memory_quality_decode_errors () =
  let dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> rm_rf dir)
    (fun () ->
       let config = Workspace_utils.default_config dir in
       append_recall_record
         ~failure_reason:"free-form provider detail that must not become a label"
         ~config
         ~keeper_id:"keeper-a"
         ~trace_id:"trace-1"
         ~turn:1
         ~injected_fact_keys:[ "id:stable" ]
         ~injected_episode_keys:[]
         ~n_facts_in_store:1
         ();
       append_malformed_recall_record ~config;
       let json =
         Memory_subsystems.dashboard_memory_subsystems_http_json
           ~config
           ~include_memory_entries:false
           (request
              "/dashboard/memory-subsystems?limit=100&memory_quality_limit=10&memory_quality_top_key_limit=1")
       in
       let quality = Json.(json |> member "memory_quality") in
       check int "sample limit from query" 10
         Json.(quality |> member "sample_limit" |> to_int);
       check int "one decoded record" 1
         Json.(quality |> member "sampled_records" |> to_int);
       check int "one decode error record" 1
         Json.(quality |> member "decode_error_records" |> to_int);
       let reasons = Json.(quality |> member "failure_reasons" |> to_list) in
       check int "one bounded failure reason" 1 (List.length reasons);
       let reason = List.hd reasons in
       check
         string
         "unknown reason is grouped"
         Recall_ledger.failure_reason_unknown_label
         Json.(reason |> member "key" |> to_string);
       check int "unknown reason count" 1
         Json.(reason |> member "count" |> to_int);
       let top_echoed =
         Json.(
           quality
           |> member "fact_injections"
           |> member "top_echoed_fact_keys"
           |> to_list)
       in
       check int "top key limit applies" 0 (List.length top_echoed))
;;

let test_http_json_hebbian_derives_from_shared_facts () =
  let dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> rm_rf dir)
    (fun () ->
       let config = Workspace_utils.default_config dir in
       let keepers_dir =
         Config_dir_resolver.keepers_dir_for_base_path ~base_path:config.base_path
       in
       Memory_io.For_testing.with_keepers_dir keepers_dir (fun () ->
         Memory_io.append_fact
           ~keeper_id:Types.shared_store_id
           (shared_fact
              ~observed_by:[ "keeper-a"; "keeper-b" ]
              ~last_verified_at:42.0
              "Shared operational fact");
         let json =
           Memory_subsystems.dashboard_memory_subsystems_http_json
             ~config
             ~include_memory_entries:false
             (request "/dashboard/memory-subsystems?limit=100")
         in
         let hebbian = Json.(json |> member "hebbian") in
         check
           (float 0.0001)
           "last_consolidation from shared fact"
           42.0
           Json.(hebbian |> member "last_consolidation" |> to_number);
         let synapses = Json.(hebbian |> member "synapses" |> to_list) in
         check int "one synapse for one shared pair" 1 (List.length synapses);
         let synapse = List.hd synapses in
         let from_agent = Json.(synapse |> member "from_agent" |> to_string) in
         let to_agent = Json.(synapse |> member "to_agent" |> to_string) in
         let pair = List.sort String.compare [ from_agent; to_agent ] in
         check (list string) "synapse links the two observers" [ "keeper-a"; "keeper-b" ] pair;
         check bool "weight is positive" true (Json.(synapse |> member "weight" |> to_number) > 0.0)))
;;

let test_http_json_hebbian_empty_without_shared_facts () =
  let dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> rm_rf dir)
    (fun () ->
       let config = Workspace_utils.default_config dir in
       let json =
         Memory_subsystems.dashboard_memory_subsystems_http_json
           ~config
           ~include_memory_entries:false
           (request "/dashboard/memory-subsystems?limit=100")
       in
       let hebbian = Json.(json |> member "hebbian") in
       check int "empty synapses" 0 Json.(hebbian |> member "synapses" |> to_list |> List.length);
       check
         (float 0.0001)
         "last_consolidation zero when no shared facts"
         0.0
         Json.(hebbian |> member "last_consolidation" |> to_number))
;;

let test_http_json_hebbian_dedupes_duplicate_observers () =
  let dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> rm_rf dir)
    (fun () ->
       let config = Workspace_utils.default_config dir in
       let keepers_dir =
         Config_dir_resolver.keepers_dir_for_base_path ~base_path:config.base_path
       in
       Memory_io.For_testing.with_keepers_dir keepers_dir (fun () ->
         (* A duplicate observer in a single fact must not inflate the edge. *)
         Memory_io.append_fact
           ~keeper_id:Types.shared_store_id
           (shared_fact
              ~observed_by:[ "keeper-a"; "keeper-a"; "keeper-b" ]
              ~last_verified_at:10.0
              "Shared operational fact");
         let json =
           Memory_subsystems.dashboard_memory_subsystems_http_json
             ~config
             ~include_memory_entries:false
             (request "/dashboard/memory-subsystems?limit=100")
         in
         let synapses = Json.(json |> member "hebbian" |> member "synapses" |> to_list) in
         check int "one synapse after dedupe" 1 (List.length synapses)))
;;

let () =
  Eio_main.run @@ fun _env ->
  Alcotest.run
    "server_dashboard_http_memory_subsystems"
    [ ( "request"
      , [ test_case
            "include_memory_entries accepts explicit bool forms"
            `Quick
            test_include_entries_query_param
        ; test_case
            "focus entries enables memory entries"
            `Quick
            test_focus_entries_enables_memory_entries
        ] )
    ; ( "json"
      , [ test_case
            "explicit disabled entries keeps empty surface"
            `Quick
            test_http_json_explicitly_disabled_entries_surface
        ; test_case
            "surfaces user model projection"
            `Quick
            test_http_json_surfaces_user_model_projection
        ; test_case
            "user model projection reads config base path"
            `Quick
            test_http_json_user_model_uses_config_base_path
        ; test_case
            "hebbian derives from shared facts"
            `Quick
            test_http_json_hebbian_derives_from_shared_facts
        ; test_case
            "surfaces memory quality summary"
            `Quick
            test_http_json_surfaces_memory_quality_summary
        ; test_case
            "surfaces memory quality decode errors"
            `Quick
            test_http_json_surfaces_memory_quality_decode_errors
        ; test_case
            "hebbian empty without shared facts"
            `Quick
            test_http_json_hebbian_empty_without_shared_facts
        ; test_case
            "hebbian dedupes duplicate observers"
            `Quick
            test_http_json_hebbian_dedupes_duplicate_observers
        ; test_case
            "surfaces draft skill candidates"
            `Quick
            test_http_json_surfaces_draft_skill_candidates
        ; test_case
            "surfaces delegation requests"
            `Quick
            test_http_json_surfaces_delegation_requests
        ] )
    ]
;;
