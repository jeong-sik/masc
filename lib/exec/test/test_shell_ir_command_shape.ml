open Masc_exec
open Masc_exec_bash_parser

let parse cmd =
  match Bash.parse_string cmd with
  | Parsed.Parsed ir -> ir
  | Parsed.Parse_error _ | Parsed.Parse_aborted _ | Parsed.Too_complex _ ->
    Alcotest.failf "failed to parse: %s" cmd

let check_recovery cmd expected =
  Alcotest.(check bool)
    cmd
    expected
    (Shell_ir_command_shape.is_git_recovery_command (parse cmd))

let check_diagnostic cmd expected =
  Alcotest.(check bool)
    cmd
    expected
    (Shell_ir_command_shape.is_git_diagnostic_command (parse cmd))

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

let test_git_diagnostic_command_shapes () =
  check_diagnostic "git status --short" true;
  check_diagnostic "env git log --oneline -5" true;
  check_diagnostic "git worktree list" true;
  check_diagnostic "env GIT_DIR=../other/.git git status" false;
  check_diagnostic "git show HEAD:README.md" false;
  check_diagnostic "git checkout HEAD -- README.md" false

let test_git_recovery_command_shapes () =
  check_recovery "git checkout HEAD -- config/deleted-one.txt" true;
  check_recovery
    "env FOO=bar git checkout HEAD -- test/fixtures/deleted-two.txt"
    true;
  check_recovery "git checkout main" true;
  check_recovery "git checkout -q main" true;
  check_recovery "git switch main" true;
  check_recovery "opam exec -- git reset --hard HEAD" true;
  check_recovery "git clean -df" true;
  check_recovery "git clean -qfd" true

let test_git_non_recovery_command_shapes () =
  check_recovery "git checkout other-branch" false;
  check_recovery "git checkout master" false;
  check_recovery "git checkout -b feature" false;
  check_recovery "git switch -c feature" false;
  check_recovery "git switch feature" false;
  check_recovery "git checkout HEAD -- ../outside.txt" false;
  check_recovery "git checkout HEAD -- :/" false;
  check_recovery "git checkout HEAD -- ':(glob)*.ml'" false;
  check_recovery "git -C ../other reset --hard HEAD" false;
  check_recovery "git --work-tree ../other reset --hard HEAD" false;
  check_recovery "git --git-dir=../other/.git clean -df" false;
  check_recovery
    "env GIT_DIR=../other/.git GIT_WORK_TREE=../other git reset --hard HEAD"
    false;
  check_recovery "git reset --hard" false;
  check_recovery "git reset --hard HEAD~1" false;
  check_recovery "git reset --soft HEAD" false;
  check_recovery "git clean -xdf" false;
  check_recovery "git clean -ffd" false;
  check_recovery "git clean -f --force -d" false;
  check_recovery "git clean -df some-path" false;
  check_recovery "git status" false

let () =
  Alcotest.run
    "Shell_ir_command_shape"
    [ ( "pipeline_shape"
      , [ Alcotest.test_case
            "projects edge command names"
            `Quick
            test_pipeline_edge_command_names
        ] )
    ; ( "git_recovery"
      , [ Alcotest.test_case
            "recognizes diagnostic commands"
            `Quick
            test_git_diagnostic_command_shapes
        ; Alcotest.test_case
            "recognizes narrow recovery commands"
            `Quick
            test_git_recovery_command_shapes
        ; Alcotest.test_case
            "rejects non-recovery git writes"
            `Quick
            test_git_non_recovery_command_shapes
        ] )
    ]
