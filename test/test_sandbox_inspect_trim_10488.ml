(** #10488: pin the [nonempty_lines] + [parse_inspect_line] pair
    against the docker-inspect-cleanup payload that triggered 4.6%
    log-spam + container leak in production (legacy containers
    without the [sandbox_ttl_sec] label, emitting trailing-empty
    tab-separated fields). *)

open Alcotest
module R = Masc_mcp.Keeper_sandbox_runtime.For_testing

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

(* The docker template is 4 fields; legacy containers without the
   [sandbox_ttl_sec] label produce a 4-field line whose 4th is
   empty. Once [nonempty_lines] preserves the trailing tab, the
   parse splits into 4 fields and [float_opt ""] returns None. *)
let test_parse_4field_with_empty_ttl () =
  let line = "87799\t1777149306.102\ttrue\t" in
  match R.parse_inspect_line line with
  | Ok (owner_pid, started_at, running, ttl_sec) ->
      check (option int) "owner_pid" (Some 87799) owner_pid;
      check (option (float 0.001)) "started_at"
        (Some 1777149306.102) started_at;
      check (option bool) "running" (Some true) running;
      check (option (float 0.001)) "ttl_sec=None" None ttl_sec
  | Error msg -> failf "expected Ok, got Error: %s" msg

let test_parse_4field_full () =
  let line = "12345\t1777149000.0\tfalse\t3600.0" in
  match R.parse_inspect_line line with
  | Ok (owner_pid, started_at, running, ttl_sec) ->
      check (option int) "owner_pid" (Some 12345) owner_pid;
      check (option bool) "running=false" (Some false) running;
      check (option (float 0.001)) "ttl_sec=3600"
        (Some 3600.0) ttl_sec;
      ignore started_at
  | Error msg -> failf "expected Ok, got Error: %s" msg

(* Legacy 3-field fallback: docker emit may be flat [f1\tf2\tf3]
   when the label-template references a label key that does not
   exist on the container. Parser must return [ttl_sec=None]
   instead of erroring out; otherwise the cleanup loop spams the
   same parse failure every cycle. *)
let test_parse_3field_legacy () =
  let line = "999\t1777149999.5\ttrue" in
  match R.parse_inspect_line line with
  | Ok (owner_pid, _, running, ttl_sec) ->
      check (option int) "owner_pid" (Some 999) owner_pid;
      check (option bool) "running" (Some true) running;
      check (option (float 0.001)) "ttl_sec=None on legacy"
        None ttl_sec
  | Error msg -> failf "expected legacy 3-field Ok, got: %s" msg

let test_parse_unexpected_arity () =
  match R.parse_inspect_line "only-one-field" with
  | Error msg ->
      check bool "error message mentions payload"
        true
        (String.length msg > 0)
  | Ok _ -> fail "expected Error on 1-field payload"

(* Combined regression: the historical incident was
   [String.trim → 3 fields → exact-match 4-field parser fails],
   producing the spam line in #10488. With both fixes the same
   raw bytes reach [Ok ttl_sec=None]. *)
let test_end_to_end_legacy_payload () =
  let raw = "87799\t1777149306.102\ttrue\t\n" in
  match R.nonempty_lines raw with
  | [ line ] ->
      (match R.parse_inspect_line line with
       | Ok (owner_pid, _, running, ttl_sec) ->
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
          test_parse_4field_with_empty_ttl;
        test_case "4-field full payload" `Quick
          test_parse_4field_full;
        test_case "3-field legacy fallback (#10488)" `Quick
          test_parse_3field_legacy;
        test_case "unexpected arity errors out" `Quick
          test_parse_unexpected_arity;
      ]);
    ("regression", [
        test_case "raw bytes → nonempty_lines → parse, end-to-end"
          `Quick test_end_to_end_legacy_payload;
      ]);
  ]
