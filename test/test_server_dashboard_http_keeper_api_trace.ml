open Alcotest
open Masc
module Trace = Server_dashboard_http_keeper_api_trace
module Types = Server_dashboard_http_keeper_api_types
module Runtime_lens_scan = Server_dashboard_http_keeper_runtime_manifest_scan
module Runtime_lens_swimlane = Server_dashboard_http_keeper_runtime_lens_swimlane
module T = Trajectory

let mk_thinking_with_turn ~turn ~ts ~redacted ~content =
  T.Thinking
    { ts
    ; ts_iso = "2026-06-29T00:00:00Z"
    ; turn
    ; content
    ; content_length = String.length content
    ; redacted
    }
;;

let mk_thinking ~ts ~redacted ~content =
  mk_thinking_with_turn ~turn:1 ~ts ~redacted ~content
;;

let test_dedupe_preserves_first_order () =
  let t1 = mk_thinking ~ts:1.0 ~redacted:false ~content:"A" in
  let t2 = mk_thinking ~ts:2.0 ~redacted:false ~content:"B" in
  let t1_dup = mk_thinking ~ts:1.0 ~redacted:false ~content:"A" in
  let input = [ t1; t2; t1_dup ] in
  let result = Trace.dedupe_thinking_lines input in
  check int "length" 2 (List.length result);
  match result with
  | [ T.Thinking a; T.Thinking b ] ->
    check string "first" "A" a.content;
    check string "second" "B" b.content
  | _ -> fail "expected two thinking lines"
;;

let test_dedupe_precision () =
  let t1 = mk_thinking ~ts:1.1234561 ~redacted:false ~content:"A" in
  let t2 = mk_thinking ~ts:1.1234562 ~redacted:false ~content:"A" in
  let input = [ t1; t2 ] in
  let result = Trace.dedupe_thinking_lines input in
  (* Without the fix, Printf.sprintf "%.6f" would truncate both to 1.123456 and drop t2 *)
  check int "length" 2 (List.length result)
;;

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

let test_read_invalid_json_skips () =
  with_temp_dir (fun dir ->
    let config = Workspace.default_config dir in
    let trace_file = Keeper_types_support.keeper_internal_history_path config "test_trace" in
    let trace_dir = Filename.dirname trace_file in
    Unix.system (Printf.sprintf "mkdir -p '%s'" trace_dir) |> ignore;
    let oc = open_out trace_file in
    (* Rows persist message text as typed [content_blocks] (the only supported
       message-content shape), not a flat [content] string. 1 valid line, 1
       invalid line (missing ts/timestamp), 1 valid line. *)
    Printf.fprintf
      oc
      "{\"source\":\"internal_assistant\",\"content_blocks\":[{\"type\":\"text\",\"text\":\"A\"}],\"ts_unix\":1.0}\n\
       {\"source\":\"internal_assistant\",\"content_blocks\":[{\"type\":\"text\",\"text\":\"B\"}]}\n\
       {\"source\":\"internal_assistant\",\"content_blocks\":[{\"type\":\"text\",\"text\":\"C\"}],\"ts_unix\":3.0}\n";
    close_out oc;
    let result = Trace.read_internal_history_lines ~config ~trace_id:"test_trace" in
    (* Should skip the invalid line ("B") without failing *)
    check int "length" 2 (List.length result);
    match result with
    | [ T.Thinking a; T.Thinking c ] ->
      check string "first" "A" a.content;
      check (float 0.0) "first_ts" 1.0 a.ts;
      check string "second" "C" c.content;
      check (float 0.0) "second_ts" 3.0 c.ts
    | _ -> fail "expected two valid thinking lines")
;;

let test_converter_decodes_content_blocks () =
  (* Regression: persisted internal_assistant rows store text under typed
     [content_blocks]. Before the fix, the converter read a flat [content]
     field, decoded "" for every row, and returned None — the whole keeper
     reasoning history was skipped (3339+ "Skipped invalid internal history
     trace row" WARNs/day) and invisible in the dashboard trace. *)
  let json =
    Yojson.Safe.from_string
      "{\"source\":\"internal_assistant\",\"content_blocks\":[{\"type\":\"text\",\"text\":\"hello world\"}],\"ts_unix\":2.0}"
  in
  match Types.internal_history_json_to_trajectory_line json with
  | Some (T.Thinking entry) ->
    check string "content" "hello world" entry.content;
    check int "content_length" (String.length "hello world") entry.content_length;
    check (float 0.0) "ts" 2.0 entry.ts
  | Some (T.Tool_call _) -> fail "expected Thinking, got Tool_call"
  | None -> fail "content_blocks row must decode to a Thinking line"
;;

let test_converter_rejects_flat_content () =
  (* Contract: [content_blocks] is the only supported message-content shape
     (Keeper_context_core_message_json). A legacy flat [content] string is not
     the supported shape and must not silently masquerade as message text. *)
  let json =
    Yojson.Safe.from_string
      "{\"source\":\"internal_assistant\",\"content\":\"legacy flat\",\"ts_unix\":2.0}"
  in
  check
    bool
    "flat content (no content_blocks) does not decode"
    true
    (Option.is_none (Types.internal_history_json_to_trajectory_line json))
;;

let test_skip_warns_once_per_file () =
  (* Per-file summary: a trace file whose rows do not decode to thinking lines
     must emit ONE summary WARN, not one per row. The dashboard re-reads each
     trace on every poll, so the previous per-row WARN flooded the log (~16k/day
     from a single busy trace, 84% of all warnings in one observed day). *)
  with_temp_dir (fun dir ->
    let config = Workspace.default_config dir in
    let trace_file =
      Keeper_types_support.keeper_internal_history_path config "summary_trace"
    in
    let trace_dir = Filename.dirname trace_file in
    Unix.system (Printf.sprintf "mkdir -p '%s'" trace_dir) |> ignore;
    let oc = open_out trace_file in
    (* Four rows that do not decode to a thinking line (no ts field -> ts<=0). *)
    Printf.fprintf
      oc
      "{\"source\":\"internal_assistant\",\"content_blocks\":[{\"type\":\"text\",\"text\":\"A\"}]}\n\
       {\"source\":\"internal_assistant\",\"content_blocks\":[{\"type\":\"text\",\"text\":\"B\"}]}\n\
       {\"source\":\"internal_assistant\",\"content_blocks\":[{\"type\":\"text\",\"text\":\"C\"}]}\n\
       {\"source\":\"internal_assistant\",\"content_blocks\":[{\"type\":\"text\",\"text\":\"D\"}]}\n";
    close_out oc;
    let warnings = ref [] in
    Console_sink.For_testing.reset ();
    Console_sink.For_testing.set_writer (Some (fun l -> warnings := l :: !warnings));
    Fun.protect ~finally:Console_sink.For_testing.reset (fun () ->
      let result = Trace.read_internal_history_lines ~config ~trace_id:"summary_trace" in
      check int "all four undecodable rows skipped" 0 (List.length result));
    let trace_warns =
      List.filter
        (fun l -> Astring.String.is_infix ~affix:"internal history trace" l)
        !warnings
    in
    check int "one summary warn for the file, not one per skipped row" 1
      (List.length trace_warns))
;;

let test_chat_trace_block_by_turn_ref_reads_allowed_trace_history () =
  with_temp_dir (fun dir ->
    let config = Workspace.default_config dir in
    let masc_root = Workspace.masc_root_dir config in
    let keeper_name = "keeper-chat-trace" in
    T.append_thinking
      ~masc_root
      ~keeper_name
      ~trace_id:"trace-current"
      { ts = 1.0
      ; ts_iso = "2026-07-01T00:00:01Z"
      ; turn = 1
      ; content = "current turn"
      ; content_length = String.length "current turn"
      ; redacted = false
      };
    T.append_thinking
      ~masc_root
      ~keeper_name
      ~trace_id:"trace-old"
      { ts = 2.0
      ; ts_iso = "2026-07-01T00:00:02Z"
      ; turn = 42
      ; content = "old turn"
      ; content_length = String.length "old turn"
      ; redacted = false
      };
    let trace_block_by_turn_ref =
      Trace.chat_trace_block_by_turn_ref
        ~max_lines:10
        ~max_internal_lines:10
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
    [ ( "dedupe_thinking_lines"
      , [ test_case "preserves first order" `Quick test_dedupe_preserves_first_order
        ; test_case "preserves sub-microsecond precision" `Quick test_dedupe_precision
        ] )
    ; ( "read_internal_history_lines"
      , [ test_case "skips invalid jsonl rows" `Quick test_read_invalid_json_skips
        ; test_case "summarises skips once per file" `Quick test_skip_warns_once_per_file
        ] )
     ; ( "internal_history_json_to_trajectory_line"
       , [ test_case
             "decodes content_blocks rows"
             `Quick
             test_converter_decodes_content_blocks
         ; test_case
             "rejects flat content rows"
             `Quick
             test_converter_rejects_flat_content
         ] )
     ; ( "chat_trace_block_by_turn_ref"
       , [ test_case
             "reads allowed trace_history trace ids"
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
