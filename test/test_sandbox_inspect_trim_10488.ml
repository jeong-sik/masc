(** #10488: pin the current four-field docker-inspect cleanup payload.
    Missing ttl labels are represented by an empty fourth field, whose
    trailing tab must survive [nonempty_lines]. *)

open Alcotest
module R = Masc.Keeper_sandbox_runtime.For_testing

(* Docker template emits [\t]-separated fields and a trailing empty
   field when one label is missing, e.g.
   [87799\t1777149306.102\t<TAB>] for the [running] field expanded
   into "true" → [87799\t1777149306.102\ttrue\t]. The trailing tab
   was previously consumed by [String.trim] in [nonempty_lines]. *)
let test_nonempty_lines_preserves_trailing_tab () =
  let raw = "f1\tf2\tf3\t\n" in
  match R.nonempty_lines raw with
  | [ line ] ->
      check string "trailing tab preserved" "f1\tf2\tf3\t" line
  | other ->
      failf "expected single line, got %d: [%s]"
        (List.length other) (String.concat " | " other)

let test_nonempty_lines_strips_cr () =
  let raw = "abc\r\ndef\r\n" in
  check (list string) "CR stripped, LF split"
    [ "abc"; "def" ] (R.nonempty_lines raw)

let test_nonempty_lines_drops_blank () =
  let raw = "\n\nabc\n\n" in
  check (list string) "blank lines dropped"
    [ "abc" ] (R.nonempty_lines raw)

(* The docker template is five fields. A missing [sandbox_ttl_sec] label
   leaves the fourth field empty, and [float_opt ""] returns [None]; the
   fifth (container kind) is absent the same way when unlabelled. *)
let test_parse_5field_with_empty_trailing_fields () =
  let line = "87799\t1777149306.102\ttrue\t\t" in
  match R.parse_inspect_line line with
  | Ok (owner_pid, started_at, running, ttl_sec, container_kind) ->
      check (option string) "container_kind=None on empty field"
        None container_kind;
      check (option int) "owner_pid" (Some 87799) owner_pid;
      check (option (float 0.001)) "started_at"
        (Some 1777149306.102) started_at;
      check (option bool) "running" (Some true) running;
      check (option (float 0.001)) "ttl_sec=None" None ttl_sec
  | Error msg -> failf "expected Ok, got Error: %s" msg

let test_parse_5field_full () =
  let line = "12345\t1777149000.0\tfalse\t3600.0\tpersistent" in
  match R.parse_inspect_line line with
  | Ok (owner_pid, started_at, running, ttl_sec, container_kind) ->
      check (option int) "owner_pid" (Some 12345) owner_pid;
      check (option bool) "running=false" (Some false) running;
      check (option (float 0.001)) "ttl_sec=3600"
        (Some 3600.0) ttl_sec;
      check (option string) "container_kind=persistent"
        (Some "persistent") container_kind;
      ignore started_at
  | Error msg -> failf "expected Ok, got Error: %s" msg

let test_parse_4field_rejected () =
  let line = "999\t1777149999.5\ttrue\t" in
  match R.parse_inspect_line line with
  | Error msg ->
      check bool "error message mentions payload" true (String.length msg > 0)
  | Ok _ -> fail "expected Error on retired 4-field payload"

let test_parse_unexpected_arity () =
  match R.parse_inspect_line "only-one-field" with
  | Error msg ->
      check bool "error message mentions payload"
        true
        (String.length msg > 0)
  | Ok _ -> fail "expected Error on 1-field payload"

let test_parse_rejects_malformed_current_fields () =
  List.iter
    (fun line ->
       match R.parse_inspect_line line with
       | Error _ -> ()
       | Ok _ -> failf "malformed current payload accepted: %S" line)
    [ "\t1777149000.0\ttrue\t\tturn"
    ; "owner\t1777149000.0\ttrue\t\tturn"
    ; "12345\t0\ttrue\t\tturn"
    ; "12345\tnan\ttrue\t\tturn"
    ; "12345\t1777149000.0\trunning\t\tturn"
    ; "12345\t1777149000.0\ttrue\t0\tturn"
    ; "12345\t1777149000.0\ttrue\tnan\tturn"
    ]

let test_end_to_end_current_payload () =
  let raw = "87799\t1777149306.102\ttrue\t\tturn\n" in
  match R.nonempty_lines raw with
  | [ line ] ->
      (match R.parse_inspect_line line with
       | Ok (owner_pid, _, running, ttl_sec, _) ->
           check (option int) "owner_pid" (Some 87799) owner_pid;
           check (option bool) "running" (Some true) running;
           check (option (float 0.001)) "ttl_sec=None"
             None ttl_sec
       | Error msg -> failf "parse failed: %s" msg)
  | other ->
      failf "expected single line, got %d" (List.length other)

let () =
  run "sandbox_inspect_trim_10488" [
    ("nonempty_lines", [
        test_case "preserves trailing tab (4-field docker output)"
          `Quick test_nonempty_lines_preserves_trailing_tab;
        test_case "strips CR but keeps content" `Quick
          test_nonempty_lines_strips_cr;
        test_case "drops blank-only lines" `Quick
          test_nonempty_lines_drops_blank;
      ]);
    ("parse_inspect_line", [
        test_case "4-field with empty ttl_sec" `Quick
          test_parse_5field_with_empty_trailing_fields;
        test_case "4-field full payload" `Quick
          test_parse_5field_full;
        test_case "retired 3-field payload is rejected" `Quick
          test_parse_4field_rejected;
        test_case "unexpected arity errors out" `Quick
          test_parse_unexpected_arity;
        test_case "malformed current fields are rejected" `Quick
          test_parse_rejects_malformed_current_fields;
      ]);
    ("regression", [
        test_case "current raw bytes → nonempty_lines → parse"
          `Quick test_end_to_end_current_payload;
      ]);
  ]
