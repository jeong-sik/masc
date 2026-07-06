open Alcotest

module H = Dashboard_harness_health

let temp_dir_counter = ref 0

let json_member key = function
  | `Assoc fields -> List.assoc_opt key fields
  | _ -> None

let json_string_member key json =
  match json_member key json with
  | Some (`String value) -> Some value
  | _ -> None

let json_bool_member key json =
  match json_member key json with
  | Some (`Bool value) -> Some value
  | _ -> None

let with_temp_dir prefix f =
  incr temp_dir_counter;
  let dir =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf
         "%s-%d-%06d"
         prefix
         (Unix.getpid ())
         !temp_dir_counter)
  in
  Unix.mkdir dir 0o755;
  let rec rm_rf path =
    if Sys.file_exists path then
      if Sys.is_directory path
      then (
        Sys.readdir path
        |> Array.iter (fun name -> rm_rf (Filename.concat path name));
        Unix.rmdir path)
      else Sys.remove path
  in
  Fun.protect ~finally:(fun () -> rm_rf dir) (fun () -> f dir)

let reset_after f =
  H.reset_runtime_stores_for_testing ();
  Fun.protect ~finally:H.reset_runtime_stores_for_testing f

let record_wake_payload ~trace_id =
  H.record_wake_payload
    ~keeper_name:"keeper-harness"
    ~trace_id
    ~turn_index:7
    ~model_id:"provider/private-model"
    ~context_window:4096
    ~approx_body_bytes:100
    ~system_prompt_bytes:10
    ~tool_defs_bytes:20
    ~messages_bytes:70
    ~message_count:3
    ~role_counts:[ "user", 1; "assistant", 2 ]
    ~tool_count:4
    ~has_compact_happened:false

let test_wake_payload_store_round_trip () =
  reset_after @@ fun () ->
  with_temp_dir "wake-payload-store" @@ fun dir ->
  H.set_wake_payload_store_for_testing ~base_dir:dir;
  ignore (H.get_wake_payload_store ());
  ignore (record_wake_payload ~trace_id:"trace-round-trip");
  match H.read_wake_payload_events () with
  | [ event ] ->
    check string "keeper" "keeper-harness" event.keeper_name;
    check string "trace" "trace-round-trip" event.trace_id;
    check int "turn index" 7 event.turn_index;
    check int "context window" 4096 event.context_window;
    check int "approx bytes" 100 event.approx_body_bytes;
    check int "tool count" 4 event.tool_count;
    check bool "compact flag" false event.has_compact_happened
  | events ->
    failf "expected one wake payload event, got %d" (List.length events)

let test_reset_rebinds_wake_payload_store () =
  reset_after @@ fun () ->
  with_temp_dir "wake-payload-store-a" @@ fun first_dir ->
  with_temp_dir "wake-payload-store-b" @@ fun second_dir ->
  H.set_wake_payload_store_for_testing ~base_dir:first_dir;
  ignore (record_wake_payload ~trace_id:"trace-first");
  H.reset_runtime_stores_for_testing ();
  H.set_wake_payload_store_for_testing ~base_dir:second_dir;
  ignore (record_wake_payload ~trace_id:"trace-second");
  match H.read_wake_payload_events () with
  | [ event ] -> check string "trace after reset" "trace-second" event.trace_id
  | events -> failf "expected rebound store to contain one event, got %d" (List.length events)

let test_pre_compact_store_setter_records_event () =
  reset_after @@ fun () ->
  with_temp_dir "pre-compact-store" @@ fun dir ->
  H.set_pre_compact_store_for_testing ~base_dir:dir;
  let event =
    H.record_pre_compact
      ~keeper_name:"keeper-harness"
      ~context_ratio:0.92
      ~message_count:12
      ~token_count:3456
      ~strategies:[ "drop-old"; "summarize" ]
      ~context_window:8192
      ~is_local_model:true
      ~trigger:Compaction_trigger.Manual
  in
  check string "keeper" "keeper-harness" event.keeper_name;
  check (float 0.0001) "ratio" 0.92 event.context_ratio;
  check int "message count" 12 event.message_count;
  check int "token count" 3456 event.token_count;
  check (list string) "strategies" [ "drop-old"; "summarize" ] event.strategies;
  check int "context window" 8192 event.context_window;
  check bool "local model" true event.is_local_model;
  check string "trigger" "manual" (Compaction_trigger.to_label event.trigger)

let test_json_surfaces_handoff_keeper_name_read_error () =
  reset_after @@ fun () ->
  with_temp_dir "harness-missing-keepers" @@ fun base ->
  let config = Workspace.default_config base in
  let json = H.json ~config () in
  let recent_handoffs =
    match json_member "recent_handoffs" json with
    | Some value -> value
    | None -> fail "missing recent_handoffs"
  in
  check (option string)
    "handoff rail status is unknown"
    (Some "unknown")
    (json_string_member "status" recent_handoffs);
  check (option string)
    "empty reason is keeper-name read failure"
    (Some "keeper_names_read_failed")
    (json_string_member "empty_reason" recent_handoffs);
  check (option bool)
    "keeper names are not known"
    (Some false)
    (json_bool_member "keeper_names_known" recent_handoffs);
  (match json_member "read_errors" recent_handoffs with
   | Some (`List (_ :: _)) -> ()
   | _ -> fail "expected handoff read_errors");
  let overview =
    match json_member "overview" json with
    | Some value -> value
    | None -> fail "missing overview"
  in
  check (option string)
    "overview handoff status is unknown"
    (Some "unknown")
    (json_string_member "handoff_status" overview);
  check (option bool)
    "overview keeper names are not known"
    (Some false)
    (json_bool_member "handoff_keeper_names_known" overview)

let () =
  Eio_main.run @@ fun _env ->
  run
    "dashboard_harness_health"
    [
      ( "runtime_stores",
        [
          test_case "wake payload round trip" `Quick test_wake_payload_store_round_trip;
          test_case "wake payload reset rebinds store" `Quick
            test_reset_rebinds_wake_payload_store;
          test_case "pre-compact setter records event" `Quick
            test_pre_compact_store_setter_records_event;
          test_case "handoff read errors are fail-visible" `Quick
            test_json_surfaces_handoff_keeper_name_read_error;
        ] );
    ]
