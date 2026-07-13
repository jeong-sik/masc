open Masc_exec
open Masc_exec_bash_parser

let parse cmd =
  match Bash.parse_string cmd with
  | Parsed.Parsed ir -> ir
  | Parsed.Parse_error _ | Parsed.Parse_aborted _ | Parsed.Too_complex _ ->
    Alcotest.failf "failed to parse: %s" cmd

let test_pipeline_edge_command_names () =
  let ir = parse "rg foo | grep bar | head -n 1" in
  Alcotest.(check (option string))
    "first command"
    (Some "rg")
    (Shell_ir_command_shape.first_command_name ir);
  Alcotest.(check (option string))
    "last command"
    (Some "head")
    (Shell_ir_command_shape.last_command_name ir);
  Alcotest.(check int) "top-level stage count" 3 (Shell_ir_command_shape.top_level_stage_count ir)

let () =
  Alcotest.run
    "Shell_ir_command_shape"
    [ ( "pipeline_shape"
      , [ Alcotest.test_case
            "projects edge command names"
            `Quick
            test_pipeline_edge_command_names
        ] )
    ]
