open Alcotest
open Masc
module Trace = Server_dashboard_http_keeper_api_trace
module Runtime_lens_scan = Server_dashboard_http_keeper_runtime_manifest_scan
module Runtime_lens_swimlane = Server_dashboard_http_keeper_runtime_lens_swimlane
module T = Trajectory

let rec rm_rf path =
  if Sys.file_exists path
  then
    if Sys.is_directory path
    then (
      Sys.readdir path |> Array.iter (fun name -> rm_rf (Filename.concat path name));
      Unix.rmdir path)
    else Sys.remove path
;;

let with_temp_dir f =
  let path = Filename.temp_file "trace-test" "" in
  Sys.remove path;
  Unix.mkdir path 0o700;
  Fun.protect ~finally:(fun () -> rm_rf path) (fun () -> f path)
;;

let record_thinking ~masc_root ~keeper_name ~trace_id ~ts ~ts_iso ~turn
    ~content =
  let block =
    Agent_sdk.Types.Thinking { content; signature = None }
  in
  let entry =
    match
      T.make_thinking_entry ~ts ~ts_iso ~keeper_turn_id:turn ~oas_turn:0
        ~block_index:0 ~block
    with
    | Ok entry -> entry
    | Error error ->
        fail
          ("invalid Thinking fixture: " ^ T.entry_decode_error_to_string error)
  in
  let acc =
    T.create_accumulator ~masc_root ~keeper_name ~trace_id ~keeper_turn_id:turn
      ~generation:0 ()
  in
  T.record_thinking acc entry;
  T.finalize acc T.Completed |> ignore
;;

let test_chat_trace_block_by_turn_ref_reads_allowed_trace_history () =
  with_temp_dir (fun dir ->
    let config = Workspace.default_config dir in
    let masc_root = Workspace.masc_root_dir config in
    let keeper_name = "keeper-chat-trace" in
    record_thinking ~masc_root ~keeper_name ~trace_id:"trace-current" ~ts:1.0
      ~ts_iso:"2026-07-01T00:00:01Z" ~turn:1 ~content:"current turn";
    record_thinking ~masc_root ~keeper_name ~trace_id:"trace-old" ~ts:2.0
      ~ts_iso:"2026-07-01T00:00:02Z" ~turn:42 ~content:"old turn";
    let trace_block_by_turn_ref =
      Trace.chat_trace_block_by_turn_ref
        ~max_lines:10
        ~config
        ~keeper_name
        ~allowed_trace_ids:[ "trace-current"; "trace-old" ]
    in
    let old_ref = Ids.Turn_ref.make ~trace_id:"trace-old" ~absolute_turn:42 in
    (match trace_block_by_turn_ref old_ref with
     | Some
         (Keeper_chat_blocks.Trace
           { trace = [ Keeper_chat_blocks.Trace_think { text = "old turn"; _ } ] })
       -> ()
     | Some _ -> fail "old trace_id returned unexpected trace block"
     | None -> fail "old trace_id from trace_history should enrich");
    let disallowed_ref =
      Ids.Turn_ref.make ~trace_id:"trace-unlisted" ~absolute_turn:42
    in
    check
      bool
      "unlisted trace_id is not used as a filesystem read key"
      true
      (Option.is_none (trace_block_by_turn_ref disallowed_ref)))
;;

let string_member key = function
  | `Assoc fields -> (
    match List.assoc_opt key fields with
    | Some (`String value) -> value
    | Some _ -> fail (Printf.sprintf "%s is not a string" key)
    | None -> fail (Printf.sprintf "%s missing" key))
  | _ -> fail "expected object"
;;

let runtime_manifest_json_with_field row_json field replacement =
  match row_json with
  | `Assoc fields ->
    `Assoc
      (List.map
         (fun (key, value) ->
            if String.equal key field then key, replacement else key, value)
         fields)
  | _ -> fail "runtime manifest row must encode as an object"
;;

let runtime_manifest_json_with_event row_json event =
  runtime_manifest_json_with_field row_json "event" (`String event)
;;

let runtime_manifest_json_without_field row_json field =
  match row_json with
  | `Assoc fields -> `Assoc (List.remove_assoc field fields)
  | _ -> fail "runtime manifest row must encode as an object"
;;

let test_runtime_manifest_scan_surfaces_diagnostics_without_repeat_warnings () =
  with_temp_dir @@ fun dir ->
  let config = Workspace.default_config dir in
  let keeper_name = "manifest-diagnostic-keeper" in
  let trace_id = "trace-manifest-diagnostics" in
  let active_row =
    Keeper_runtime_manifest.make
      ~keeper_name
      ~trace_id
      ~keeper_turn_id:1
      ~event:Keeper_runtime_manifest.Turn_started
      ~status:"started"
      ()
    |> Keeper_runtime_manifest.to_json
  in
  let rows =
    [ runtime_manifest_json_with_event active_row "state_snapshot_sidecar_saved"
    ; runtime_manifest_json_with_event active_row "working_state_sidecar_saved"
    ; runtime_manifest_json_with_event active_row "future_manifest_event"
    ; runtime_manifest_json_with_event active_row "future_manifest_event_2"
    ; runtime_manifest_json_with_event active_row "future_manifest_event_3"
    ; runtime_manifest_json_with_field
        (runtime_manifest_json_with_event active_row "state_snapshot_sidecar_saved")
        "schema_version"
        (`Int 2)
    ; runtime_manifest_json_without_field active_row "status"
    ; active_row
    ]
  in
  let path =
    Keeper_runtime_manifest.path_for_trace config ~keeper_name ~trace_id
  in
  Fs_compat.mkdir_p (Filename.dirname path);
  let channel = open_out path in
  List.iter
    (fun row -> Printf.fprintf channel "%s\n" (Yojson.Safe.to_string row))
    rows;
  Printf.fprintf channel "{not-json\n";
  close_out channel;
  let warnings = ref [] in
  Console_sink.For_testing.reset ();
  Console_sink.For_testing.set_writer (Some (fun line -> warnings := line :: !warnings));
  let scan =
    Fun.protect
      ~finally:Console_sink.For_testing.reset
      (fun () ->
         Runtime_lens_scan.read_runtime_manifest_scan
           ~config
           ~keeper_name
           ~trace_id
           ~limit:2
           ())
  in
  check int "one active row decoded" 1 scan.total_rows;
  check int "all rows scanned" 9 scan.scanned_lines;
  check int "reader emits no per-row warnings" 0 (List.length !warnings);
  let diagnostics = Runtime_lens_scan.runtime_manifest_scan_diagnostics_json scan in
  let open Yojson.Safe.Util in
  check string
    "diagnostic schema"
    "keeper.runtime_manifest_scan_diagnostics.v1"
    (diagnostics |> member "schema" |> to_string);
  check int
    "retired rows counted"
    2
    (diagnostics |> member "retired_event_count" |> to_int);
  check int
    "unsupported rows counted"
    3
    (diagnostics |> member "unsupported_event_count" |> to_int);
  check int
    "unsupported rows outside the identity request bound are explicit"
    1
    (diagnostics
     |> member "unsupported_event_unattributed_count"
     |> to_int);
  check int
    "invalid manifest rows counted"
    2
    (diagnostics |> member "invalid_manifest_row_count" |> to_int);
  check int
    "invalid json rows counted"
    1
    (diagnostics |> member "invalid_json_row_count" |> to_int);
  let retired_counts = diagnostics |> member "retired_event_counts" |> to_list in
  check int "retired kinds remain distinct" 2 (List.length retired_counts);
  let unsupported_counts =
    diagnostics |> member "unsupported_event_counts" |> to_list
  in
  check int
    "unsupported identity aggregation obeys request bound"
    2
    (List.length unsupported_counts);
  check int
    "diagnostic samples obey request bound"
    2
    (diagnostics |> member "samples" |> to_list |> List.length)
;;

let test_tool_runtime_zero_event_lane_is_not_observed () =
  let scan =
    Runtime_lens_scan.make_runtime_manifest_scan
      ~path:"/tmp/empty-runtime-manifest.jsonl"
      ~limit:10
      ~scan_line_limit:10
      ~scan_scope:"test"
  in
  let json =
    Runtime_lens_swimlane.runtime_lens_swimlane_json
      scan
      []
      ~lane:"tool_runtime"
      ~label:"Tool Runtime"
      ~events:[]
      ~terminal_status:"not_observed"
      ~synthetic_events:[]
  in
  check string "terminal status" "not_observed"
    (string_member "terminal_status" json);
  check string "empty tool-runtime lane is not complete" "not_observed"
    (string_member "completeness" json)
;;

let () =
  Eio_main.run @@ fun env ->
  Masc_test_deps.init_eio_clock env;
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  run
    "Server_dashboard_http_keeper_api_trace"
    [ ( "chat_trace_block_by_turn_ref"
       , [ test_case
             "reads allowed trajectory trace ids"
             `Quick
             test_chat_trace_block_by_turn_ref_reads_allowed_trace_history
         ] )
    ; ( "runtime_lens_swimlane"
      , [ test_case
            "tool_runtime zero-event lane is not observed"
            `Quick
            test_tool_runtime_zero_event_lane_is_not_observed
        ] )
    ; ( "runtime_manifest_scan"
      , [ test_case
            "surfaces retired and unsupported rows without repeated warnings"
            `Quick
            test_runtime_manifest_scan_surfaces_diagnostics_without_repeat_warnings
        ] )
    ]
;;
