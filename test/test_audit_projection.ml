(* Golden equivalence for the audit-snapshot read-path migration
   (operator_control_snapshot_tool_audit + keeper_status_metrics): the new
   [Jsonl_incremental_projection.recent_lines] must return byte-identical lines
   to the prior tail read [Keeper_memory.read_file_tail_lines_result] that the
   audit path used, on cold start, after incremental appends, at the window
   cap, and across the [initial_tail_bytes] boundary on a large file. If these
   pass, the unchanged downstream parsers (collect_recent_tool_names /
   latest_snapshot_of_lines) produce identical output, so the migration is
   behavior-preserving. *)

module Jip = Masc.Jsonl_incremental_projection

let write_append path lines =
  let oc = open_out_gen [ Open_append; Open_creat ] 0o644 path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () -> List.iter (fun l -> output_string oc (l ^ "\n")) lines)
;;

let tail_oracle path ~max_bytes ~max_lines =
  match
    Masc.Keeper_memory.read_file_tail_lines_result path ~max_bytes ~max_lines
  with
  | Ok lines -> lines
  | Error _ -> Alcotest.fail "oracle tail read failed"
;;

let with_tmp prefix f =
  let path = Filename.temp_file prefix ".jsonl" in
  Fun.protect ~finally:(fun () -> try Sys.remove path with Sys_error _ -> ()) (fun () -> f path)
;;

(* Decision-log window used by operator_control_snapshot_tool_audit. *)
let win = 120
let bytes = 120000

let test_cold_start_matches_tail () =
  with_tmp "audit_proj_cold" (fun path ->
    write_append path
      [ {|{"tool":"a"}|}; {|{"tool":"b"}|}; {|{"tools_used":["c","d"]}|} ];
    let t = Jip.create () in
    let got =
      Jip.recent_lines t ~key:path ~path ~window:win
        ~initial_tail_bytes:bytes
    in
    let expected = tail_oracle path ~max_bytes:bytes ~max_lines:win in
    Alcotest.(check (list string)) "cold start = tail" expected got)
;;

let test_incremental_after_append () =
  with_tmp "audit_proj_incr" (fun path ->
    write_append path [ {|{"tool":"a"}|}; {|{"tool":"b"}|} ];
    let t = Jip.create () in
    let _ : string list =
      Jip.recent_lines t ~key:path ~path ~window:win
        ~initial_tail_bytes:bytes
    in
    (* Append more lines; the same projection [t] must fold only the delta and
       still equal a fresh full tail read. *)
    write_append path [ {|{"tool":"c"}|}; {|{"tools_used":["d","e"]}|} ];
    let got =
      Jip.recent_lines t ~key:path ~path ~window:win
        ~initial_tail_bytes:bytes
    in
    let expected = tail_oracle path ~max_bytes:bytes ~max_lines:win in
    Alcotest.(check (list string)) "after append = tail" expected got)
;;

let test_window_cap_matches_tail () =
  (* More lines than the keeper_status_metrics window (12): both keep only the
     last 12, in file order. *)
  with_tmp "audit_proj_cap" (fun path ->
    let lines = List.init 50 (fun i -> Printf.sprintf {|{"tool":"t%d"}|} i) in
    write_append path lines;
    let t = Jip.create () in
    let got =
      Jip.recent_lines t ~key:path ~path ~window:12
        ~initial_tail_bytes:40000
    in
    let expected = tail_oracle path ~max_bytes:40000 ~max_lines:12 in
    Alcotest.(check (list string)) "window cap = tail (last 12)" expected got)
;;

let test_large_file_boundary () =
  (* File larger than [initial_tail_bytes]: exercises the cold-start tail seek
     + line alignment. recent_lines must match the tail read's last [win]
     lines exactly. *)
  with_tmp "audit_proj_big" (fun path ->
    let lines = List.init 10000 (fun i -> Printf.sprintf {|{"tool":"tool_%05d"}|} i) in
    write_append path lines;
    let t = Jip.create () in
    let got =
      Jip.recent_lines t ~key:path ~path ~window:win
        ~initial_tail_bytes:bytes
    in
    let expected = tail_oracle path ~max_bytes:bytes ~max_lines:win in
    Alcotest.(check (list string)) "large file boundary = tail" expected got)
;;

(* Review fix [P2]: a file recreated at the same path with a NEW inode and a
   size larger than the prior consumed offset must reseed. Only an inode check
   (not [size < consumed]) detects this; without it the stale offset would skip
   the new file's head and read mid-line garbage. *)
let test_recreation_resets_offset () =
  with_tmp "audit_proj_recreate" (fun path ->
    write_append path [ {|{"tool":"old1"}|}; {|{"tool":"old2"}|} ];
    let t = Jip.create () in
    let _ : string list =
      Jip.recent_lines t ~key:path ~path ~window:win ~initial_tail_bytes:bytes
    in
    Sys.remove path;
    write_append path
      [ {|{"tool":"new1"}|}; {|{"tool":"new2"}|}; {|{"tool":"new3"}|};
        {|{"tool":"new4"}|} ];
    let got =
      Jip.recent_lines t ~key:path ~path ~window:win ~initial_tail_bytes:bytes
    in
    let expected = tail_oracle path ~max_bytes:bytes ~max_lines:win in
    Alcotest.(check (list string)) "recreation reseeds from new file" expected
      got)
;;

(* Review fix [P2]: whitespace-only lines are dropped, matching the tail oracle
   ([String.trim] filter) rather than reaching a JSON parser. *)
let test_blank_lines_filtered () =
  with_tmp "audit_proj_blank" (fun path ->
    write_append path
      [ {|{"tool":"a"}|}; "   "; {|{"tool":"b"}|}; "\t"; {|{"tool":"c"}|} ];
    let t = Jip.create () in
    let got =
      Jip.recent_lines t ~key:path ~path ~window:win ~initial_tail_bytes:bytes
    in
    let expected = tail_oracle path ~max_bytes:bytes ~max_lines:win in
    Alcotest.(check (list string)) "blank lines filtered = tail" expected got)
;;

(* Review fix [P3]: [peek] exposes the cached accumulator (newest-first ring) so
   a caller can fall back to the last good projection on a transient read
   error. *)
let test_peek_returns_last_projection () =
  with_tmp "audit_proj_peek" (fun path ->
    write_append path [ {|{"tool":"a"}|}; {|{"tool":"b"}|} ];
    let t = Jip.create () in
    let got =
      Jip.recent_lines t ~key:path ~path ~window:win ~initial_tail_bytes:bytes
    in
    match Jip.peek t ~key:path with
    | Some cached ->
        Alcotest.(check (list string)) "peek reversed = recent_lines" got
          (List.rev cached)
    | None -> Alcotest.fail "peek returned None after a successful read")
;;

let test_tool_name_parser_surfaces_malformed_rows () =
  let lines =
    [
      "{not-json";
      {|{"tools_used":["masc_status"]}|};
      "[]";
    ]
  in
  let names, errors =
    Masc.Operator_control_snapshot_tool_names.collect_recent_tool_names_with_errors
      lines
  in
  Alcotest.(check (list string))
    "valid tool names survive malformed neighbors"
    [ "masc_status" ]
    names;
  Alcotest.(check int) "malformed rows are reported" 2 (List.length errors);
  let error_json =
    match errors with
    | first :: _ ->
      Masc.Operator_control_snapshot_tool_names.recent_tool_name_parse_error_to_json
        ~source:"operator_tool_audit_decisions_jsonl"
        ~keeper:"audit-probe"
        ~path:"/tmp/decision-log.jsonl"
        first
    | [] -> Alcotest.fail "expected parse errors"
  in
  Alcotest.(check string)
    "parse error source"
    "operator_tool_audit_decisions_jsonl"
    Yojson.Safe.Util.(error_json |> member "source" |> to_string);
  Alcotest.(check string)
    "parse error keeper"
    "audit-probe"
    Yojson.Safe.Util.(error_json |> member "keeper" |> to_string)
;;

let test_context_metrics_parser_surfaces_malformed_rows () =
  let valid_context =
    `Assoc
      [
        ("snapshot_source", `String "keeper_context_status");
        ("context_ratio", `Float 0.5);
        ("context_tokens", `Int 128);
        ("context_max", `Int 512);
      ]
    |> Yojson.Safe.to_string
  in
  let rows, errors =
    Masc.Keeper_status_metrics.parse_metrics_json_lines
      [ "{not-json"; valid_context; "[]" ]
  in
  Alcotest.(check int) "valid metrics rows survive" 1 (List.length rows);
  Alcotest.(check int) "malformed metrics rows are reported" 2 (List.length errors);
  let snapshots =
    List.filter_map
      Masc.Operator_control_context_snapshot.keeper_context_snapshot_from_metrics_json
      rows
  in
  let snapshot =
    match snapshots with
    | [ snapshot ] -> snapshot
    | _ -> Alcotest.fail "expected exactly one context snapshot"
  in
  Alcotest.(check (option string))
    "context source survives malformed neighbors"
    (Some "keeper_context_status")
    snapshot.context_source;
  Alcotest.(check (option int))
    "context tokens survive malformed neighbors"
    (Some 128)
    snapshot.context_tokens;
  let error_json =
    match errors with
    | first :: _ ->
      Masc.Keeper_status_metrics.metrics_json_line_parse_error_to_json
        ~source:"operator_context_snapshot_metrics_jsonl"
        ~keeper:"context-probe"
        ~path:"/tmp/metrics.jsonl"
        first
    | [] -> Alcotest.fail "expected parse errors"
  in
  Alcotest.(check string)
    "context parse error source"
    "operator_context_snapshot_metrics_jsonl"
    Yojson.Safe.Util.(error_json |> member "source" |> to_string);
  Alcotest.(check string)
    "context parse error keeper"
    "context-probe"
    Yojson.Safe.Util.(error_json |> member "keeper" |> to_string)
;;

let () =
  Alcotest.run "audit_projection"
    [ ( "recent_lines_vs_tail"
      , [ Alcotest.test_case "cold start matches tail" `Quick
            test_cold_start_matches_tail
        ; Alcotest.test_case "incremental after append matches tail" `Quick
            test_incremental_after_append
        ; Alcotest.test_case "window cap matches tail" `Quick
            test_window_cap_matches_tail
        ; Alcotest.test_case "large file boundary matches tail" `Quick
            test_large_file_boundary
        ; Alcotest.test_case "recreation resets offset (inode)" `Quick
            test_recreation_resets_offset
        ; Alcotest.test_case "blank lines filtered" `Quick
            test_blank_lines_filtered
        ; Alcotest.test_case "peek returns last projection" `Quick
            test_peek_returns_last_projection
        ] )
    ; ( "tool_name_diagnostics"
      , [ Alcotest.test_case "malformed rows are surfaced" `Quick
            test_tool_name_parser_surfaces_malformed_rows
        ] )
    ; ( "context_metrics_diagnostics"
      , [ Alcotest.test_case "malformed rows are surfaced" `Quick
            test_context_metrics_parser_surfaces_malformed_rows
        ] )
    ]
;;
