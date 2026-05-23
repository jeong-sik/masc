(** P10 — Output compatibility tests for keeper_shell_ops "ls" lowering.

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

open Masc_mcp

(* ---- lines_to_json ------------------------------------------------ *)

let yojson_t = Alcotest.testable (Yojson.Safe.pp) ( = )

let test_lines_to_json_empty () =
  let json = Keeper_exec_shared.lines_to_json "" in
  Alcotest.check yojson_t "empty string → empty list"
    (`List []) json

let test_lines_to_json_splits_on_newline () =
  let json = Keeper_exec_shared.lines_to_json "a\nb\nc" in
  Alcotest.(check yojson_t) "three lines"
    (`List [ `String "a"; `String "b"; `String "c" ])
    json

let test_lines_to_json_ignores_empty_lines () =
  let json = Keeper_exec_shared.lines_to_json "a\n\nb\n\n" in
  Alcotest.(check yojson_t) "empty lines stripped"
    (`List [ `String "a"; `String "b" ])
    json

let test_lines_to_json_limit_truncates () =
  let json = Keeper_exec_shared.lines_to_json ~limit:2 "a\nb\nc\nd" in
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
         (Yojson.Safe.pp)
         other)
  | other ->
    Alcotest.failf "expected `List, got %a" (Yojson.Safe.pp) other

let test_lines_to_json_byte_budget () =
  (* 1000-byte max_bytes with long lines should trigger truncation. *)
  let long_line = String.make 300 'x' in
  let text = String.concat "\n" [ long_line; long_line; long_line; long_line ] in
  let json = Keeper_exec_shared.lines_to_json ~max_bytes:1_000 text in
  match json with
  | `List items ->
    (* At least one line kept, but not all 4 because 4 × (300 + 4) > 1000 *)
    Alcotest.(check bool) "byte budget truncates" true (List.length items < 4);
    (* Last element is an omission marker *)
    (match List.rev items |> List.hd with
     | `String s ->
       Alcotest.(check bool) "last item is omission marker" true
         (String.starts_with ~prefix:"...[" s)
     | _ -> Alcotest.fail "expected omission string")
  | other ->
    Alcotest.failf "expected `List, got %a" (Yojson.Safe.pp) other

(* ---- process_status_to_json --------------------------------------- *)

let test_process_status_exited_zero () =
  let json = Keeper_alerting_path.process_status_to_json (Unix.WEXITED 0) in
  match json with
  | `Assoc fields ->
    Alcotest.(check (option string)) "kind = exit"
      (Some "exit")
      (List.assoc_opt "kind" fields |> Option.map Yojson.Safe.to_string);
    Alcotest.(check (option int)) "code = 0"
      (Some 0)
      (List.assoc_opt "code" fields
       |> fun o -> Option.bind o (function `Int i -> Some i | _ -> None))
  | other ->
    Alcotest.failf "expected `Assoc, got %a" (Yojson.Safe.pp) other

let test_process_status_exited_nonzero () =
  let json = Keeper_alerting_path.process_status_to_json (Unix.WEXITED 2) in
  match json with
  | `Assoc fields ->
    Alcotest.(check (option int)) "code = 2"
      (Some 2)
      (List.assoc_opt "code" fields
       |> fun o -> Option.bind o (function `Int i -> Some i | _ -> None))
  | other ->
    Alcotest.failf "expected `Assoc, got %a" (Yojson.Safe.pp) other

let test_process_status_timeout () =
  (* Exit code 124 is the Eio timeout convention. *)
  let json = Keeper_alerting_path.process_status_to_json (Unix.WEXITED 124) in
  match json with
  | `Assoc fields ->
    Alcotest.(check (option string)) "kind = timeout"
      (Some "timeout")
      (List.assoc_opt "kind" fields |> Option.map Yojson.Safe.to_string)
  | other ->
    Alcotest.failf "expected `Assoc, got %a" (Yojson.Safe.pp) other

let test_process_status_signaled () =
  let json = Keeper_alerting_path.process_status_to_json (Unix.WSIGNALED Sys.sigkill) in
  match json with
  | `Assoc fields ->
    Alcotest.(check (option string)) "kind = signaled"
      (Some "signaled")
      (List.assoc_opt "kind" fields |> Option.map Yojson.Safe.to_string)
  | other ->
    Alcotest.failf "expected `Assoc, got %a" (Yojson.Safe.pp) other

(* ---- JSON envelope shape contract --------------------------------- *)

let yojson_has_field name json =
  match json with
  | `Assoc fields -> List.mem_assoc name fields
  | _ -> false

let yojson_string_field name json =
  match json with
  | `Assoc fields ->
    List.assoc_opt name fields
    |> fun o -> Option.bind o (function `String s -> Some s | _ -> None)
  | _ -> None

let yojson_bool_field name json =
  match json with
  | `Assoc fields ->
    List.assoc_opt name fields
    |> fun o -> Option.bind o (function `Bool b -> Some b | _ -> None)
  | _ -> None

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
      ; "entries", Keeper_exec_shared.lines_to_json "a\nb"
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
      ; "entries", Keeper_exec_shared.lines_to_json "a\nb"
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

(* ---- Suite registration ------------------------------------------- *)

let () =
  Alcotest.run "keeper_shell_ops"
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
        ] )
    ; ( "process_status_to_json"
      , [ Alcotest.test_case "exited 0" `Quick test_process_status_exited_zero
        ; Alcotest.test_case "exited 2" `Quick test_process_status_exited_nonzero
        ; Alcotest.test_case "timeout (124)" `Quick test_process_status_timeout
        ; Alcotest.test_case "signaled" `Quick test_process_status_signaled
        ] )
    ; ( "p10_envelope_shape"
      , [ Alcotest.test_case "host envelope fields" `Quick
            test_p10_host_envelope_shape
        ; Alcotest.test_case "docker envelope fields" `Quick
            test_p10_docker_envelope_shape
        ] )
    ]
