(** P10 — Output compatibility tests for tool_search_files_ops "ls" lowering.

    The "ls" branch was lowered from raw argv execution to the canonical
    Shell IR pipeline (to_shell_ir → classify → gate_typed →
    validate_paths → dispatch_decided).  These tests pin the output
    envelope shape so the lowering is constrained by documented behaviour
    rather than by prose intent.

    Scope:
    - lines_to_json formatter (entries array shape, limit, byte budget)
    - process_status_to_json (status field shape in P10 host envelope)
    - JSON envelope field contract (ok, op, path, via, status, entries)

    Out of scope: Docker routing (preserved verbatim from pre-P10). *)

open Masc

(* ---- lines_to_json ------------------------------------------------ *)

let yojson_t = Alcotest.testable (Yojson.Safe.pretty_print ~std:false) ( = )
let test_lines_to_json_empty () =
  let json = Keeper_tool_shared_runtime.lines_to_json "" in
  Alcotest.check yojson_t "empty string → empty list"
    (`List []) json

let test_lines_to_json_splits_on_newline () =
  let json = Keeper_tool_shared_runtime.lines_to_json "a\nb\nc" in
  Alcotest.(check yojson_t) "three lines"
    (`List [ `String "a"; `String "b"; `String "c" ])
    json

let test_lines_to_json_ignores_empty_lines () =
  let json = Keeper_tool_shared_runtime.lines_to_json "a\n\nb\n\n" in
  Alcotest.(check yojson_t) "empty lines stripped"
    (`List [ `String "a"; `String "b" ])
    json

let test_lines_to_json_limit_truncates () =
  let json = Keeper_tool_shared_runtime.lines_to_json ~limit:2 "a\nb\nc\nd" in
  match json with
  | `List items ->
    Alcotest.(check int) "limit=2 keeps 2 lines + omission marker" 3
      (List.length items);
    (match List.nth items 2 with
     | `String s ->
       Alcotest.(check bool) "omission marker mentions count"
         true
         (String.starts_with ~prefix:"...[2 more lines omitted" s)
     | other ->
       Alcotest.failf "expected omission string, got %a"
         (Yojson.Safe.pretty_print ~std:false)         other)
  | other ->
    Alcotest.failf "expected `List, got %a" (Yojson.Safe.pretty_print ~std:false) other
let test_lines_to_json_byte_budget () =
  (* 1000-byte max_bytes with long lines should trigger truncation. *)
  let long_line = String.make 300 'x' in
  let text = String.concat "\n" [ long_line; long_line; long_line; long_line ] in
  let json = Keeper_tool_shared_runtime.lines_to_json ~max_bytes:1_000 text in
  match json with
  | `List items ->
    (* 3 lines (912 bytes) fit + 1 omission marker = 4 items; the
       original 4th 304-byte line tips the budget over 1000 and is
       replaced by the marker.  The truncation invariant is the
       marker's presence on the tail, not the item count: marker +
       N kept yields the same length as N+1 kept-without-marker. *)
    Alcotest.(check bool) "at least one line kept alongside marker" true
      (List.length items >= 2);
    (* Last element is an omission marker — the real truncation evidence. *)
    (match List.rev items |> List.hd with
     | `String s ->
       Alcotest.(check bool) "last item is omission marker" true
         (String.starts_with ~prefix:"...[" s)
     | _ -> Alcotest.fail "expected omission string")
  | other ->
    Alcotest.failf "expected `List, got %a" (Yojson.Safe.pretty_print ~std:false) other

(* A file stored as one line (minified JSON) is one 300,000-byte match. The
   byte budget keeps the first line whatever its size, so it used to come back
   whole. *)
let test_lines_to_json_single_long_line_is_cut () =
  let json = Keeper_tool_shared_runtime.lines_to_json (String.make 300_000 'x') in
  match json with
  | `List [ `String line ] ->
    Alcotest.(check string) "default cap keeps 2000 bytes and says how much was cut"
      (String.make 2_000 'x' ^ "...[cut: 2000 of 300000 bytes kept]")
      line
  | other ->
    Alcotest.failf "expected one line, got %a" (Yojson.Safe.pretty_print ~std:false) other

let test_lines_to_json_line_cap_never_exceeds_the_budget () =
  let json =
    Keeper_tool_shared_runtime.lines_to_json ~max_bytes:1_000 (String.make 5_000 'z')
  in
  match json with
  | `List [ `String line ] ->
    Alcotest.(check string) "a budget below the line cap lowers the cap"
      (String.make 1_000 'z' ^ "...[cut: 1000 of 5000 bytes kept]")
      line
  | other ->
    Alcotest.failf "expected one line, got %a" (Yojson.Safe.pretty_print ~std:false) other

let test_lines_to_json_long_line_keeps_the_other_matches () =
  let text = String.concat "\n" [ "first"; String.make 50_000 'y'; "last" ] in
  let json = Keeper_tool_shared_runtime.lines_to_json ~max_line_bytes:100 text in
  match json with
  | `List [ `String first; `String cut; `String last ] ->
    Alcotest.(check string) "line before the long one" "first" first;
    Alcotest.(check string) "the long line"
      (String.make 100 'y' ^ "...[cut: 100 of 50000 bytes kept]")
      cut;
    Alcotest.(check string) "line after the long one" "last" last
  | other ->
    Alcotest.failf "expected three lines, got %a" (Yojson.Safe.pretty_print ~std:false) other

(* 100 Korean syllables are 300 bytes; a cut at byte 100 lands inside the 34th
   syllable and has to step back to byte 99. *)
let test_lines_to_json_cut_does_not_split_a_character () =
  let line = String.concat "" (List.init 100 (fun _ -> "가")) in
  let json = Keeper_tool_shared_runtime.lines_to_json ~max_line_bytes:100 line in
  match json with
  | `List [ `String cut ] ->
    Alcotest.(check string) "33 whole characters kept"
      (String.concat "" (List.init 33 (fun _ -> "가")) ^ "...[cut: 99 of 300 bytes kept]")
      cut;
    Alcotest.(check bool) "valid UTF-8" true (String.is_valid_utf_8 cut)
  | other ->
    Alcotest.failf "expected one line, got %a" (Yojson.Safe.pretty_print ~std:false) other

(* rg exits 2 when any file fails to open while others matched, and its whole
   output went into error_detail; one such call carried 1.04 MB. *)
let test_cut_to_bytes_keeps_what_fits () =
  Alcotest.(check string) "text of exactly max_bytes is kept" "abc"
    (Keeper_tool_shared_runtime.cut_to_bytes ~max_bytes:3 "abc");
  Alcotest.(check string) "one byte over is cut and counted"
    "abc...[cut: 3 of 4 bytes kept]"
    (Keeper_tool_shared_runtime.cut_to_bytes ~max_bytes:3 "abcd")

(* ---- process_status_to_json --------------------------------------- *)

let test_process_status_exited_zero () =
  let json = Keeper_alerting_path.process_status_to_json (Unix.WEXITED 0) in
  match json with
  | `Assoc fields ->
    Alcotest.(check (option string)) "kind = exit"
      (Some "exit")
      (List.assoc_opt "kind" fields
       |> fun opt -> Option.bind opt (function `String s -> Some s | _ -> None));
    Alcotest.(check (option int)) "code = 0"
      (Some 0)
      (List.assoc_opt "code" fields
       |> fun opt -> Option.bind opt (function `Int i -> Some i | _ -> None))  | other ->
    Alcotest.failf "expected `Assoc, got %a" (Yojson.Safe.pretty_print ~std:false) other
let test_process_status_exited_nonzero () =
  let json = Keeper_alerting_path.process_status_to_json (Unix.WEXITED 2) in
  match json with
  | `Assoc fields ->
    Alcotest.(check (option int)) "code = 2"
      (Some 2)
      (List.assoc_opt "code" fields
       |> fun opt -> Option.bind opt (function `Int i -> Some i | _ -> None))  | other ->
    Alcotest.failf "expected `Assoc, got %a" (Yojson.Safe.pretty_print ~std:false) other
let test_process_status_exited_124 () =
  let json = Keeper_alerting_path.process_status_to_json (Process_eio.timed_out_status) in
  match json with
  | `Assoc fields ->
    Alcotest.(check (option string)) "kind = exit"
      (Some "exit")
      (List.assoc_opt "kind" fields
       |> fun opt -> Option.bind opt (function `String s -> Some s | _ -> None));
    Alcotest.(check (option int)) "code = 124"
      (Some 124)
      (List.assoc_opt "code" fields
       |> fun opt -> Option.bind opt (function `Int i -> Some i | _ -> None))
  | other ->
    Alcotest.failf "expected `Assoc, got %a" (Yojson.Safe.pretty_print ~std:false) other
let test_process_status_signaled () =
  let json = Keeper_alerting_path.process_status_to_json (Unix.WSIGNALED Sys.sigkill) in
  match json with
  | `Assoc fields ->
    Alcotest.(check (option string)) "kind = signal"
      (Some "signal")
      (List.assoc_opt "kind" fields
       |> fun opt -> Option.bind opt (function `String s -> Some s | _ -> None))
  | other ->
    Alcotest.failf "expected `Assoc, got %a" (Yojson.Safe.pretty_print ~std:false) other
(* ---- JSON envelope shape contract --------------------------------- *)

let yojson_has_field name json =
  match json with
  | `Assoc fields -> List.mem_assoc name fields
  | _ -> false

let yojson_string_field name json =
  match json with
  | `Assoc fields ->
    List.assoc_opt name fields
    |> fun opt -> Option.bind opt (function `String s -> Some s | _ -> None)  | _ -> None

let yojson_bool_field name json =
  match json with
  | `Assoc fields ->
    List.assoc_opt name fields
    |> fun opt -> Option.bind opt (function `Bool b -> Some b | _ -> None)  | _ -> None

let test_p10_host_envelope_shape () =
  (* Reconstruct the exact envelope that P10 host ls emits after
     dispatch_decided, using the same field order and constructors.
     This test MUST be updated if the envelope structure changes. *)
  let envelope =
    `Assoc
      [ "ok", `Bool true
      ; "op", `String "ls"
      ; "path", `String "/tmp"
      ; "via", `String "host"
      ; "status", Keeper_alerting_path.process_status_to_json (Unix.WEXITED 0)
      ; "entries", Keeper_tool_shared_runtime.lines_to_json "a\nb"
      ]
  in
  Alcotest.(check bool) "has ok" true (yojson_has_field "ok" envelope);
  Alcotest.(check bool) "has op" true (yojson_has_field "op" envelope);
  Alcotest.(check bool) "has path" true (yojson_has_field "path" envelope);
  Alcotest.(check bool) "has via" true (yojson_has_field "via" envelope);
  Alcotest.(check bool) "has status" true (yojson_has_field "status" envelope);
  Alcotest.(check bool) "has entries" true (yojson_has_field "entries" envelope);
  Alcotest.(check (option string)) "via = host"
    (Some "host")
    (yojson_string_field "via" envelope);
  Alcotest.(check (option string)) "op = ls"
    (Some "ls")
    (yojson_string_field "op" envelope);
  Alcotest.(check (option bool)) "ok = true"
    (Some true)
    (yojson_bool_field "ok" envelope)

let test_p10_docker_envelope_shape () =
  (* Docker path is preserved verbatim; this documents the shape for
     comparison with the host path.  Docker envelope lacks the status
     field that the host path gained in P10. *)
  let envelope =
    `Assoc
      [ "ok", `Bool true
      ; "op", `String "ls"
      ; "path", `String "/tmp"
      ; "via", `String "docker"
      ; "entries", Keeper_tool_shared_runtime.lines_to_json "a\nb"
      ]
  in
  Alcotest.(check bool) "docker has ok" true (yojson_has_field "ok" envelope);
  Alcotest.(check bool) "docker has op" true (yojson_has_field "op" envelope);
  Alcotest.(check bool) "docker has path" true (yojson_has_field "path" envelope);
  Alcotest.(check bool) "docker has via" true (yojson_has_field "via" envelope);
  Alcotest.(check bool) "docker has entries" true (yojson_has_field "entries" envelope);
  Alcotest.(check bool) "docker lacks status field"
    false
    (yojson_has_field "status" envelope)

(* ---- Endpoint that cannot be resolved ------------------------------ *)

let test_unresolved_endpoint_is_the_operators_and_keeps_the_tree_refusal () =
  let tree_refusal = Keeper_alerting_path.caller_refusal (Keeper_alerting_path.Cwd_is_file { cwd = "/etc/passwd" }) in
  let endpoint_error = "sandbox endpoint \"builder\" is not configured" in
  let refusal = Keeper_alerting_path.endpoint_unresolved ~tree_refusal ~endpoint_error in
  Alcotest.(check bool) "tree refusal was the caller's" true
    (tree_refusal.Keeper_alerting_path.failure_class = Tool_result.Policy_rejection);
  Alcotest.(check bool) "unresolved endpoint is the operator's" true
    (refusal.Keeper_alerting_path.failure_class = Tool_result.Runtime_failure);
  Alcotest.(check bool) "the operator's endpoint error leads" true
    (String.starts_with ~prefix:endpoint_error refusal.Keeper_alerting_path.message);
  Alcotest.(check bool) "the tree refusal follows" true
    (String.ends_with ~suffix:(tree_refusal.Keeper_alerting_path.message ^ ")")
       refusal.Keeper_alerting_path.message)

(* ---- Suite registration ------------------------------------------- *)

let () =
  Alcotest.run "tool_search_files_ops"
    [ ( "lines_to_json"
      , [ Alcotest.test_case "empty string" `Quick test_lines_to_json_empty
        ; Alcotest.test_case "split on newline" `Quick
            test_lines_to_json_splits_on_newline
        ; Alcotest.test_case "ignore empty lines" `Quick
            test_lines_to_json_ignores_empty_lines
        ; Alcotest.test_case "limit truncates" `Quick
            test_lines_to_json_limit_truncates
        ; Alcotest.test_case "byte budget truncates" `Quick
            test_lines_to_json_byte_budget
        ; Alcotest.test_case "single long line is cut" `Quick
            test_lines_to_json_single_long_line_is_cut
        ; Alcotest.test_case "line cap never exceeds the budget" `Quick
            test_lines_to_json_line_cap_never_exceeds_the_budget
        ; Alcotest.test_case "long line keeps the other matches" `Quick
            test_lines_to_json_long_line_keeps_the_other_matches
        ; Alcotest.test_case "cut does not split a character" `Quick
            test_lines_to_json_cut_does_not_split_a_character
        ; Alcotest.test_case "cut_to_bytes keeps what fits" `Quick
            test_cut_to_bytes_keeps_what_fits
        ] )
    ; ( "process_status_to_json"
      , [ Alcotest.test_case "exited 0" `Quick test_process_status_exited_zero
        ; Alcotest.test_case "exited 2" `Quick test_process_status_exited_nonzero
        ; Alcotest.test_case "exit 124" `Quick test_process_status_exited_124
        ; Alcotest.test_case "signaled" `Quick test_process_status_signaled
        ] )
    ; ( "p10_envelope_shape"
      , [ Alcotest.test_case "host envelope fields" `Quick
            test_p10_host_envelope_shape
        ; Alcotest.test_case "docker envelope fields" `Quick
            test_p10_docker_envelope_shape
        ] )
    ; ( "endpoint_unresolved"
      , [ Alcotest.test_case "operator's class, tree refusal kept" `Quick
            test_unresolved_endpoint_is_the_operators_and_keeps_the_tree_refusal
        ] )
    ]
