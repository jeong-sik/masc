open Alcotest
open Masc
module Trace = Server_dashboard_http_keeper_api_trace
module Types = Server_dashboard_http_keeper_api_types
module Lens_summaries = Server_dashboard_http_keeper_runtime_lens_summaries
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

let test_parse_tool_output_json_result_surfaces_malformed_output () =
  let call =
    `Assoc
      [ ("tool", `String "keeper_task_claim")
      ; ("output", `String "{not-json")
      ; ("trace_id", `String "trace-runtime-lens")
      ; ("keeper_turn_id", `Int 9)
      ]
  in
  (match Types.parse_tool_output_json_result call with
   | Ok _ -> fail "malformed tool output must surface Error"
   | Error msg ->
     check bool "parse error is populated" true (String.length msg > 0));
  check bool "legacy option facade projects parse failure to None" true
    (Option.is_none (Types.parse_tool_output_json_opt call))
;;

let test_claim_scope_summary_surfaces_tool_output_parse_error () =
  let call =
    `Assoc
      [ ("tool", `String "keeper_task_claim")
      ; ("output", `String "{not-json")
      ; ("trace_id", `String "trace-runtime-lens")
      ; ("keeper_turn_id", `Int 9)
      ]
  in
  let summary = Lens_summaries.claim_scope_summary_of_tool_call_json call in
  let open Yojson.Safe.Util in
  check bool "matching claim is present" true (summary |> member "present" |> to_bool);
  check string "status" "read_error" (summary |> member "status" |> to_string);
  check string "read error source" "runtime_lens.tool_output"
    (summary |> member "read_error_source" |> to_string);
  check string "trace id preserved" "trace-runtime-lens"
    (summary |> member "trace_id" |> to_string);
  check int "keeper turn id preserved" 9
    (summary |> member "keeper_turn_id" |> to_int)
;;

let string_member key = function
  | `Assoc fields -> (
    match List.assoc_opt key fields with
    | Some (`String value) -> value
    | Some _ -> fail (Printf.sprintf "%s is not a string" key)
    | None -> fail (Printf.sprintf "%s missing" key))
  | _ -> fail "expected object"
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
     ; ( "tool_output_json"
       , [ test_case
             "parse result surfaces malformed output"
             `Quick
             test_parse_tool_output_json_result_surfaces_malformed_output
         ; test_case
             "claim summary surfaces tool output parse error"
             `Quick
             test_claim_scope_summary_surfaces_tool_output_parse_error
         ] )
     ; ( "runtime_lens_swimlane"
       , [ test_case
             "tool_runtime zero-event lane is not observed"
             `Quick
             test_tool_runtime_zero_event_lane_is_not_observed
         ] )
     ]
;;
