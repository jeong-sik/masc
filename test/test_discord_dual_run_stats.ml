(* RFC-0203 Phase 2 — Discord_dual_run_stats unit tests.

   Counter increment + JSONL audit format + per-path isolation.
   Snapshot reads are not strongly consistent across counters, so
   tests serialize their own writes — concurrency is the producers'
   job, not the unit-test's. *)

open Alcotest
module S = Discord_dual_run_stats

let setenv k v = Unix.putenv k v
let unsetenv k = Unix.putenv k ""

(* Each test isolates its audit-path side-effect via a per-test
   temp file, so concurrent test runs don't see each other's
   appends. *)
let with_temp_audit_path f =
  let dir = Filename.get_temp_dir_name () in
  let suffix = string_of_int (int_of_float (Unix.gettimeofday () *. 1000.0)) in
  let path = Filename.concat dir ("discord_traffic_audit_" ^ suffix ^ ".jsonl") in
  (try Sys.remove path with Sys_error _ -> ());
  setenv "MASC_DISCORD_TRAFFIC_AUDIT_PATH" path;
  (* Also point base_path away from the real workspace in case the
     env var is unset and we fall back to the default. *)
  S.reset_for_test ();
  Fun.protect
    ~finally:(fun () ->
      unsetenv "MASC_DISCORD_TRAFFIC_AUDIT_PATH";
      (try Sys.remove path with Sys_error _ -> ()))
    (fun () -> f path)

let read_lines path =
  if not (Sys.file_exists path) then []
  else
    let ic = open_in path in
    Fun.protect
      ~finally:(fun () -> close_in_noerr ic)
      (fun () ->
        let rec loop acc =
          match input_line ic with
          | line -> loop (line :: acc)
          | exception End_of_file -> List.rev acc
        in
        loop [])

(* ---------------------------------------------------------------- *)
(* Counter increment + per-path isolation                           *)
(* ---------------------------------------------------------------- *)

let test_counters_start_at_zero () =
  with_temp_audit_path (fun _path ->
    let c = S.snapshot ~path:Builtin in
    check int "builtin ready" 0 c.ready;
    check int "builtin message_create" 0 c.message_create;
    let cs = S.snapshot ~path:Sidecar in
    check int "sidecar ready" 0 cs.ready)

let test_inbound_increments_per_path () =
  with_temp_audit_path (fun _path ->
    S.record_inbound ~path:Builtin Message_create;
    S.record_inbound ~path:Builtin Message_create;
    S.record_inbound ~path:Builtin Reaction_add;
    S.record_inbound ~path:Sidecar Message_create;
    let b = S.snapshot ~path:Builtin in
    let s = S.snapshot ~path:Sidecar in
    check int "builtin msg_create" 2 b.message_create;
    check int "builtin reaction_add" 1 b.reaction_add;
    check int "sidecar msg_create" 1 s.message_create;
    check int "sidecar reaction_add" 0 s.reaction_add)

let test_inbound_kinds_have_distinct_buckets () =
  with_temp_audit_path (fun _path ->
    S.record_inbound ~path:Builtin Ready;
    S.record_inbound ~path:Builtin Message_create;
    S.record_inbound ~path:Builtin Reaction_add;
    S.record_inbound ~path:Builtin Ignored;
    let c = S.snapshot ~path:Builtin in
    check (list int) "1 per kind" [1; 1; 1; 1]
      [c.ready; c.message_create; c.reaction_add; c.ignored])

let test_outbound_buckets () =
  with_temp_audit_path (fun _path ->
    S.record_outbound ~path:Builtin (Ok_message_id "MSG1");
    S.record_outbound ~path:Builtin Err_missing_token;
    S.record_outbound ~path:Builtin (Err_transient "dns");
    S.record_outbound ~path:Builtin (Err_workflow "forbidden");
    S.record_outbound ~path:Builtin (Err_runtime "weird");
    let c = S.snapshot ~path:Builtin in
    check int "ok" 1 c.outbound_ok;
    check int "missing_token" 1 c.outbound_err_missing_token;
    check int "transient" 1 c.outbound_err_transient;
    check int "workflow" 1 c.outbound_err_workflow;
    check int "runtime" 1 c.outbound_err_runtime)

(* ---------------------------------------------------------------- *)
(* JSONL audit format                                               *)
(* ---------------------------------------------------------------- *)

let parse_or_fail line =
  match Yojson.Safe.from_string line with
  | exception _ -> failf "audit line is not valid JSON: %S" line
  | json -> json

let assoc_string json key =
  match json with
  | `Assoc kvs ->
    (match List.assoc_opt key kvs with
     | Some (`String s) -> s
     | _ -> failf "missing or non-string %S in %s" key (Yojson.Safe.to_string json))
  | _ -> failf "not an Assoc: %s" (Yojson.Safe.to_string json)

let test_audit_inbound_line () =
  with_temp_audit_path (fun path ->
    S.record_inbound ~path:Builtin Message_create;
    let lines = read_lines path in
    check int "1 line written" 1 (List.length lines);
    let j = parse_or_fail (List.hd lines) in
    check string "direction=inbound" "inbound" (assoc_string j "direction");
    check string "path=builtin" "builtin" (assoc_string j "path");
    check string "kind=message_create" "message_create" (assoc_string j "kind");
    check bool "has timestamp" true
      (String.length (assoc_string j "timestamp") > 0))

let test_audit_outbound_ok_carries_message_id () =
  with_temp_audit_path (fun path ->
    S.record_outbound ~path:Sidecar (Ok_message_id "MSG_42");
    let j = parse_or_fail (List.hd (read_lines path)) in
    check string "direction=outbound" "outbound" (assoc_string j "direction");
    check string "outcome=ok" "ok" (assoc_string j "outcome");
    check string "message_id pinned" "MSG_42" (assoc_string j "message_id"))

let test_audit_outbound_err_carries_message () =
  with_temp_audit_path (fun path ->
    S.record_outbound ~path:Builtin (Err_workflow "Cannot send DM");
    let j = parse_or_fail (List.hd (read_lines path)) in
    check string "outcome=err_workflow" "err_workflow" (assoc_string j "outcome");
    check string "error message pinned" "Cannot send DM"
      (assoc_string j "message"))

let test_audit_missing_token_has_no_message_field () =
  with_temp_audit_path (fun path ->
    S.record_outbound ~path:Builtin Err_missing_token;
    let j = parse_or_fail (List.hd (read_lines path)) in
    check string "outcome=err_missing_token" "err_missing_token"
      (assoc_string j "outcome");
    (* Missing_token doesn't carry a payload — verify field absent. *)
    match j with
    | `Assoc kvs ->
      check bool "no message field" false (List.mem_assoc "message" kvs)
    | _ -> fail "not Assoc")

let test_audit_appends_multiple_lines () =
  with_temp_audit_path (fun path ->
    S.record_inbound ~path:Builtin Ready;
    S.record_inbound ~path:Builtin Message_create;
    S.record_outbound ~path:Sidecar (Ok_message_id "X");
    check int "3 lines appended" 3 (List.length (read_lines path)))

(* ---------------------------------------------------------------- *)
(* Reset                                                            *)
(* ---------------------------------------------------------------- *)

let test_reset_zeros_counters () =
  with_temp_audit_path (fun _path ->
    S.record_inbound ~path:Builtin Message_create;
    S.record_outbound ~path:Sidecar (Ok_message_id "X");
    S.reset_for_test ();
    let b = S.snapshot ~path:Builtin in
    let s = S.snapshot ~path:Sidecar in
    check (pair int int) "both zero" (0, 0) (b.message_create, s.outbound_ok))

(* ---------------------------------------------------------------- *)
(* Entry                                                            *)
(* ---------------------------------------------------------------- *)

let () =
  run "discord_dual_run_stats"
    [ ( "counters"
      , [ test_case "start at zero" `Quick test_counters_start_at_zero
        ; test_case "inbound increments per path" `Quick
            test_inbound_increments_per_path
        ; test_case "inbound kinds have distinct buckets" `Quick
            test_inbound_kinds_have_distinct_buckets
        ; test_case "outbound buckets" `Quick test_outbound_buckets
        ] )
    ; ( "audit"
      , [ test_case "inbound line shape" `Quick test_audit_inbound_line
        ; test_case "outbound ok carries message_id" `Quick
            test_audit_outbound_ok_carries_message_id
        ; test_case "outbound err carries message" `Quick
            test_audit_outbound_err_carries_message
        ; test_case "missing_token has no message field" `Quick
            test_audit_missing_token_has_no_message_field
        ; test_case "appends multiple lines" `Quick
            test_audit_appends_multiple_lines
        ] )
    ; ( "reset"
      , [ test_case "reset zeros counters" `Quick test_reset_zeros_counters ] )
    ]
