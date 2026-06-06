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
    ]
