open Alcotest

module Json = Yojson.Safe.Util
module Memory_subsystems = Server_dashboard_http_memory_subsystems
module Memory_io = Masc.Keeper_memory_os_io
module Recall_ledger = Masc.Keeper_recall_injection_ledger
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

let fact ?(category = Types.Preference) ?(trace_id = "trace-memory")
      ?(turn = 3) ?(first_seen = 10.0) ?last_verified_at claim
  : Types.fact
  =
  { claim
  ; category
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

let test_http_json_surfaces_memory_quality_summary () =
  let dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> rm_rf dir)
    (fun () ->
       let config = Workspace_utils.default_config dir in
       let observation_key = Types.claim_identity (fact "provider diagnostic") in
       append_recall_record
         ~config
         ~keeper_id:"keeper-a"
         ~trace_id:"trace-1"
         ~turn:1
         ~injected_fact_keys:[ "id:stable"; observation_key ]
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
            "surfaces delegation requests"
            `Quick
            test_http_json_surfaces_delegation_requests
        ] )
    ]
;;
