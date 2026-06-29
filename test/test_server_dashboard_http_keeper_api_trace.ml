open Alcotest
open Masc
module Trace = Server_dashboard_http_keeper_api_trace
module T = Trajectory

let mk_thinking ~ts ~redacted ~content =
  T.Thinking
    { ts
    ; ts_iso = "2026-06-29T00:00:00Z"
    ; turn = 1
    ; content
    ; content_length = String.length content
    ; redacted
    }
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
    (* 1 valid line, 1 invalid line (missing ts/timestamp), 1 valid line *)
    Printf.fprintf
      oc
      "{\"source\":\"internal_assistant\",\"content\":\"A\",\"ts_unix\":1.0}\n\
       {\"source\":\"internal_assistant\",\"content\":\"B\"}\n\
       {\"source\":\"internal_assistant\",\"content\":\"C\",\"ts_unix\":3.0}\n";
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
      , [ test_case "skips invalid jsonl rows" `Quick test_read_invalid_json_skips ] )
    ]
;;
