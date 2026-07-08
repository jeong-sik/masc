open Masc_exec
open Masc_exec_bash_parser

let parse cmd =
  match Bash.parse_string cmd with
  | Parsed.Parsed ir -> ir
  | Parsed.Parse_error _ | Parsed.Parse_aborted _ | Parsed.Too_complex _ ->
    Alcotest.failf "failed to parse: %s" cmd

let field name fields = List.assoc_opt name fields

let test_glob_literal_failure_fields () =
  let fields =
    Shell_ir_diagnostics.glob_literal_failure_fields
      ~ir:(parse "ls src/*.ml")
      ~status:(Unix.WEXITED 2)
      ~stderr:"ls: src/*.ml: No such file or directory"
  in
  Alcotest.(check (option bool))
    "glob flag"
    (Some true)
    (match field "typed_glob_not_expanded" fields with
     | Some (`Bool value) -> Some value
     | Some _ | None -> None);
  Alcotest.(check (option string))
    "literal token"
    (Some "src/*.ml")
    (match field "literal_glob_token" fields with
     | Some (`String value) -> Some value
     | Some _ | None -> None)

let test_success_has_no_glob_hint () =
  let fields =
    Shell_ir_diagnostics.glob_literal_failure_fields
      ~ir:(parse "ls src/*.ml")
      ~status:(Unix.WEXITED 0)
      ~stderr:""
  in
  Alcotest.(check int) "no fields" 0 (List.length fields)

let test_duplicate_argv0_failure_fields () =
  let fields =
    Shell_ir_diagnostics.duplicate_argv0_failure_fields
      ~ir:(parse "wc wc")
      ~status:(Unix.WEXITED 1)
      ~stderr:"wc: wc: No such file or directory"
  in
  Alcotest.(check (option bool))
    "argv0 duplicate flag"
    (Some true)
    (match field "argv0_duplicates_executable" fields with
     | Some (`Bool value) -> Some value
     | Some _ | None -> None);
  Alcotest.(check (option string))
    "duplicated executable"
    (Some "wc")
    (match field "duplicated_executable" fields with
     | Some (`String value) -> Some value
     | Some _ | None -> None)

let test_duplicate_argv0_no_hint_on_success () =
  (* argv[0] == executable that SUCCEEDS is treated as intentional payload;
     the intentional-payload design must not be nagged. *)
  let fields =
    Shell_ir_diagnostics.duplicate_argv0_failure_fields
      ~ir:(parse "wc wc")
      ~status:(Unix.WEXITED 0)
      ~stderr:""
  in
  Alcotest.(check int) "no fields on success" 0 (List.length fields)

let test_duplicate_argv0_no_hint_when_distinct () =
  (* A normal command whose argv[0] differs from the executable never triggers
     the duplicate hint, even on a path-not-found failure. *)
  let fields =
    Shell_ir_diagnostics.duplicate_argv0_failure_fields
      ~ir:(parse "cat README.md")
      ~status:(Unix.WEXITED 1)
      ~stderr:"cat: README.md: No such file or directory"
  in
  Alcotest.(check int) "no fields when argv0 != executable" 0 (List.length fields)

let () =
  Alcotest.run
    "Shell_ir_diagnostics"
    [ ( "glob_literal"
      , [ Alcotest.test_case
            "emits literal glob hint on path failure"
            `Quick
            test_glob_literal_failure_fields
        ; Alcotest.test_case
            "does not emit hint on success"
            `Quick
            test_success_has_no_glob_hint
        ] )
    ; ( "duplicate_argv0"
      , [ Alcotest.test_case
            "emits rewrite hint on path failure with duplicated argv[0]"
            `Quick
            test_duplicate_argv0_failure_fields
        ; Alcotest.test_case
            "does not emit hint on success (intentional payload preserved)"
            `Quick
            test_duplicate_argv0_no_hint_on_success
        ; Alcotest.test_case
            "does not emit hint when argv[0] differs from executable"
            `Quick
            test_duplicate_argv0_no_hint_when_distinct
        ] )
    ]
