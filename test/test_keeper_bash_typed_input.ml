(** RFC-0091 PR-1 §5.1.4 differential observation test.

    Exercises [Keeper_tool_bash_input.validate] on 8 representative
    inputs and records the legacy [Worker_dev_tools.validate_command_paths]
    verdict alongside (logged via [Printf.eprintf], not asserted).

    The test asserts only the *typed* verdict — the legacy verdict is
    observational because (a) RFC body's §4 audit predictions about
    [path_syntax_blocked] coverage were partially wrong (probed during
    PR-1: [find . -name *.ml] passes legacy [validate_command_paths]
    despite the [*] glob token), and (b) PR-2 deletes the legacy lexer
    entirely so its current verdicts are *expiring evidence* not invariant.

    The observation logs are kept to make any actual divergence visible
    to PR-2 author when migrating callers. *)

open Masc_mcp
module Bash_input = Keeper_tool_bash_input

let legacy_verdict cmd =
  match Worker_dev_tools.validate_command cmd with
  | Error _ -> "legacy_vc=ERR"
  | Ok () ->
    (match Worker_dev_tools.validate_command_paths cmd with
     | Ok () -> "legacy_vcp=OK"
     | Error e -> Printf.sprintf "legacy_vcp=ERR(%s)" (String.sub e 0 (min 40 (String.length e))))
;;

let typed_ok input =
  match Bash_input.validate ~mode:Bash_input.Dev_full input with
  | Ok () -> true
  | Error _ -> false
;;

let mk_exec executable argv =
  Bash_input.Exec { executable; argv; cwd = None; env = [] }
;;

let parse_json_exn json =
  match Bash_input.of_json json with
  | Ok input -> input
  | Error msg -> Alcotest.failf "of_json failed: %s" msg
;;

let parse_json_error json =
  match Bash_input.of_json json with
  | Ok _ -> Alcotest.fail "of_json unexpectedly succeeded"
  | Error msg -> msg
;;

type case = {
  name : string;
  legacy_cmd : string;
  typed : Bash_input.bash_input;
  expect_typed : bool;
  rationale : string;
}

let cases : case list =
  [ { name = "simple_rg"
    ; legacy_cmd = "rg pattern lib/"
    ; typed = mk_exec "rg" [ "pattern"; "lib/" ]
    ; expect_typed = true
    ; rationale = "allowlisted executable + plain argv"
    }
  ; { name = "ls_flag"
    ; legacy_cmd = "ls -la"
    ; typed = mk_exec "ls" [ "-la" ]
    ; expect_typed = true
    ; rationale = "short flag argv"
    }
  ; { name = "cat_path"
    ; legacy_cmd = "cat README.md"
    ; typed = mk_exec "cat" [ "README.md" ]
    ; expect_typed = true
    ; rationale = "relative path argv"
    }
  ; { name = "unknown_executable"
    ; legacy_cmd = "unknown_cmd foo"
    ; typed = mk_exec "unknown_cmd" [ "foo" ]
    ; expect_typed = false
    ; rationale = "executable not in dev allowlist"
    }
  ; { name = "find_glob_pattern"
    ; legacy_cmd = "find . -name *.ml"
    ; typed = mk_exec "find" [ "."; "-name"; "*.ml" ]
    ; expect_typed = true
    ; rationale =
        "execve-style argv: [*] inside an argv token is literal data, \
         not a shell glob; find handles its own pattern matching"
    }
  ; { name = "git_oneline"
    ; legacy_cmd = "git log --oneline -5"
    ; typed = mk_exec "git" [ "log"; "--oneline"; "-5" ]
    ; expect_typed = true
    ; rationale = "multi-arg git invocation"
    }
  ; { name = "pwd_no_args"
    ; legacy_cmd = "pwd"
    ; typed = mk_exec "pwd" []
    ; expect_typed = true
    ; rationale = "zero-argv invocation"
    }
  ; { name = "argv_with_nul"
    ; legacy_cmd = "echo foo"
    ; typed = mk_exec "echo" [ "foo\000bar" ]
    ; expect_typed = false
    ; rationale =
        "NUL in argv token cannot survive process-boundary \
         serialization; typed schema rejects via shell_metachar_in_token"
    }
  ]
;;

let test_case case () =
  let typed = typed_ok case.typed in
  let observed_legacy = legacy_verdict case.legacy_cmd in
  Printf.eprintf
    "[differential] %s: cmd=%S | %s | typed=%s | %s\n"
    case.name
    case.legacy_cmd
    observed_legacy
    (if typed then "OK" else "ERR")
    case.rationale;
  Alcotest.(check bool)
    (Printf.sprintf "%s typed verdict (%s)" case.name case.rationale)
    case.expect_typed
    typed
;;

let test_pipeline_empty () =
  let input =
    Bash_input.Pipeline { stages = []; cwd = None; env = [] }
  in
  Alcotest.(check bool)
    "pipeline with empty stages is rejected"
    false
    (typed_ok input)
;;

let test_pipeline_single_stage_rejected () =
  let input =
    Bash_input.Pipeline
      { stages = [ { executable = "rg"; argv = [ "pattern" ] } ]
      ; cwd = None
      ; env = []
      }
  in
  Alcotest.(check bool)
    "pipeline with one stage is rejected"
    false
    (typed_ok input)
;;

let test_pipeline_stage_executable_check () =
  let input =
    Bash_input.Pipeline
      { stages =
          [ { executable = "rg"; argv = [ "pattern" ] }
          ; { executable = "unknown_cmd"; argv = [] }
          ]
      ; cwd = None
      ; env = []
      }
  in
  Alcotest.(check bool)
    "pipeline: non-allowlisted stage executable is rejected"
    false
    (typed_ok input)
;;

let test_of_json_exec () =
  let input =
    parse_json_exn
      (`Assoc
          [ "executable", `String "rg"
          ; "argv", `List [ `String "pattern"; `String "lib/" ]
          ; "cwd", `String "/tmp"
          ; "env", `Assoc [ "LC_ALL", `String "C" ]
          ])
  in
  match input with
  | Bash_input.Exec { executable; argv; cwd; env } ->
    Alcotest.(check string) "executable" "rg" executable;
    Alcotest.(check (list string)) "argv" [ "pattern"; "lib/" ] argv;
    Alcotest.(check (option string)) "cwd" (Some "/tmp") cwd;
    Alcotest.(check (list (pair string string))) "env" [ "LC_ALL", "C" ] env
  | Bash_input.Pipeline _ -> Alcotest.fail "expected Exec"
;;

let test_of_json_pipeline () =
  let input =
    parse_json_exn
      (`Assoc
          [ ( "pipeline"
            , `List
                [ `Assoc
                    [ "executable", `String "printf"
                    ; "argv", `List [ `String "hello" ]
                    ]
                ; `Assoc
                    [ "executable", `String "wc"
                    ; "argv", `List [ `String "-c" ]
                    ]
                ] )
          ; "cwd", `String "/tmp"
          ])
  in
  match input with
  | Bash_input.Pipeline { stages; cwd; env } ->
    Alcotest.(check int) "stage count" 2 (List.length stages);
    Alcotest.(check (option string)) "cwd" (Some "/tmp") cwd;
    Alcotest.(check (list (pair string string))) "env" [] env;
    (match stages with
     | [ first; second ] ->
       Alcotest.(check string) "first executable" "printf" first.executable;
       Alcotest.(check (list string)) "first argv" [ "hello" ] first.argv;
       Alcotest.(check string) "second executable" "wc" second.executable;
       Alcotest.(check (list string)) "second argv" [ "-c" ] second.argv
     | _ -> Alcotest.fail "expected exactly two stages")
  | Bash_input.Exec _ -> Alcotest.fail "expected Pipeline"
;;

let test_of_json_rejects_legacy_cmd_only () =
  let msg =
    parse_json_error (`Assoc [ "cmd", `String "rg pattern lib/" ])
  in
  Alcotest.(check bool)
    "error mentions typed input"
    true
    (String_util.contains_substring_ci msg "typed keeper_bash input")
;;

let test_of_json_rejects_legacy_cmd_with_exec () =
  let msg =
    parse_json_error
      (`Assoc [ "cmd", `String "rg pattern lib/"; "executable", `String "rg" ])
  in
  Alcotest.(check bool)
    "error mentions typed input"
    true
    (String_util.contains_substring_ci msg "typed keeper_bash input")
;;

let test_of_json_rejects_non_string_argv () =
  let msg =
    parse_json_error
      (`Assoc
          [ "executable", `String "echo"; "argv", `List [ `Int 1 ] ])
  in
  Alcotest.(check bool)
    "error mentions argv[0]"
    true
    (String_util.contains_substring_ci msg "$.argv[0]")
;;

let test_of_json_rejects_mixed_exec_and_pipeline () =
  let msg =
    parse_json_error
      (`Assoc
          [ "executable", `String "echo"
          ; "pipeline", `List [ `Assoc [ "executable", `String "wc" ] ]
          ])
  in
  Alcotest.(check bool)
    "error mentions either executable or pipeline"
    true
    (String_util.contains_substring_ci msg "either executable or pipeline")
;;

let test_of_json_stages_alias_reports_stages_path () =
  let msg =
    parse_json_error
      (`Assoc [ "stages", `List [ `Assoc [ "argv", `List [] ] ] ])
  in
  Alcotest.(check bool)
    "error mentions stages path"
    true
    (String_util.contains_substring_ci msg "$.stages[0].executable")
;;

let shell_arg_string = function
  | Masc_exec.Shell_ir.Lit s -> s
  | Masc_exec.Shell_ir.Var name -> "$" ^ name
  | Masc_exec.Shell_ir.Concat _ -> "<concat>"
;;

let shell_simple_tuple (simple : Masc_exec.Shell_ir.simple) =
  ( Masc_exec.Bin.to_string simple.bin
  , List.map shell_arg_string simple.args )
;;

let to_shell_ir_exn input =
  match Bash_input.to_shell_ir ~mode:Bash_input.Dev_full input with
  | Ok ir -> ir
  | Error error ->
    Alcotest.failf
      "to_shell_ir failed: %a"
      Bash_input.pp_validation_error
      error
;;

let test_pipeline_lowers_to_shell_ir_pipeline () =
  let input =
    Bash_input.Pipeline
      { stages =
          [ { executable = "echo"; argv = [ "hello world" ] }
          ; { executable = "tr"; argv = [ "a-z"; "A-Z" ] }
          ]
      ; cwd = Some "/tmp"
      ; env = [ "LC_ALL", "C" ]
      }
  in
  match to_shell_ir_exn input with
  | Masc_exec.Shell_ir.Pipeline
      [ Masc_exec.Shell_ir.Simple first; Masc_exec.Shell_ir.Simple second ] ->
    Alcotest.(check (pair string (list string)))
      "first stage"
      ("echo", [ "hello world" ])
      (shell_simple_tuple first);
    Alcotest.(check (pair string (list string)))
      "second stage"
      ("tr", [ "a-z"; "A-Z" ])
      (shell_simple_tuple second);
    Alcotest.(check (option string))
      "cwd copied to every stage"
      (Some "/tmp")
      (Option.map Masc_exec.Path_scope.raw second.cwd);
    Alcotest.(check (list (pair string string)))
      "env copied to every stage"
      [ "LC_ALL", "C" ]
      (List.map (fun (key, value) -> key, shell_arg_string value) second.env)
  | other ->
    Alcotest.failf "expected Shell_ir.Pipeline, got %a" Masc_exec.Shell_ir.pp other
;;

let docker_test_sandbox () =
  Masc_exec.Sandbox_target.docker
    ~image:"typed-docker"
    ~runner:(fun ~stdin_content:_ ~argv:_ ~env:_ ~cwd:_ ~timeout_sec:_ ->
      Unix.WEXITED 0, "", "")
;;

let check_docker_sandbox label simple =
  match simple.Masc_exec.Shell_ir.sandbox with
  | Masc_exec.Sandbox_target.Host -> Alcotest.fail (label ^ ": expected Docker sandbox")
  | Docker { image; _ } -> Alcotest.(check string) (label ^ " image") "typed-docker" image
;;

let test_pipeline_lowers_with_injected_docker_sandbox () =
  let input =
    Bash_input.Pipeline
      { stages =
          [ { executable = "echo"; argv = [ "hello" ] }
          ; { executable = "wc"; argv = [ "-c" ] }
          ]
      ; cwd = Some "/tmp"
      ; env = []
      }
  in
  match
    Bash_input.to_shell_ir
      ~mode:Bash_input.Dev_full
      ~sandbox:(docker_test_sandbox ())
      input
  with
  | Ok
      (Masc_exec.Shell_ir.Pipeline
        [ Masc_exec.Shell_ir.Simple first; Masc_exec.Shell_ir.Simple second ]) ->
    check_docker_sandbox "first stage" first;
    check_docker_sandbox "second stage" second
  | Ok other ->
    Alcotest.failf "expected Shell_ir.Pipeline, got %a" Masc_exec.Shell_ir.pp other
  | Error error ->
    Alcotest.failf
      "to_shell_ir failed: %a"
      Bash_input.pp_validation_error
      error
;;

let test_pipe_character_in_exec_argv_is_literal () =
  let input =
    Bash_input.Exec
      { executable = "echo"
      ; argv = [ "foo|bar" ]
      ; cwd = None
      ; env = []
      }
  in
  match to_shell_ir_exn input with
  | Masc_exec.Shell_ir.Simple simple ->
    Alcotest.(check (pair string (list string)))
      "pipe char remains argv data"
      ("echo", [ "foo|bar" ])
      (shell_simple_tuple simple)
  | Masc_exec.Shell_ir.Pipeline _ ->
    Alcotest.fail "literal pipe argv token must not create Shell_ir.Pipeline"
;;

let test_cwd_not_absolute () =
  let input =
    Bash_input.Exec
      { executable = "ls"; argv = []; cwd = Some "relative/path"; env = [] }
  in
  Alcotest.(check bool)
    "Cwd_not_absolute: relative cwd rejected"
    false
    (typed_ok input)
;;

let test_env_key_invalid () =
  let input =
    Bash_input.Exec
      { executable = "ls"
      ; argv = []
      ; cwd = None
      ; env = [ "FOO BAR", "value" ]
      }
  in
  Alcotest.(check bool)
    "Env_key_invalid: env key with space rejected"
    false
    (typed_ok input)
;;

let suite =
  ("RFC-0091 PR-1 differential",
    List.map
      (fun c -> Alcotest.test_case c.name `Quick (test_case c))
    cases
    @ [ Alcotest.test_case "pipeline_empty" `Quick test_pipeline_empty
      ; Alcotest.test_case
          "pipeline_single_stage_rejected"
          `Quick
          test_pipeline_single_stage_rejected
      ; Alcotest.test_case
          "pipeline_stage_executable_check"
          `Quick
          test_pipeline_stage_executable_check
      ; Alcotest.test_case "of_json_exec" `Quick test_of_json_exec
      ; Alcotest.test_case "of_json_pipeline" `Quick test_of_json_pipeline
      ; Alcotest.test_case
          "of_json_rejects_legacy_cmd_only"
          `Quick
          test_of_json_rejects_legacy_cmd_only
      ; Alcotest.test_case
          "of_json_rejects_legacy_cmd_with_exec"
          `Quick
          test_of_json_rejects_legacy_cmd_with_exec
      ; Alcotest.test_case
          "of_json_rejects_non_string_argv"
          `Quick
          test_of_json_rejects_non_string_argv
      ; Alcotest.test_case
          "of_json_rejects_mixed_exec_and_pipeline"
          `Quick
          test_of_json_rejects_mixed_exec_and_pipeline
      ; Alcotest.test_case
          "of_json_stages_alias_reports_stages_path"
          `Quick
          test_of_json_stages_alias_reports_stages_path
      ; Alcotest.test_case
          "pipeline_lowers_to_shell_ir_pipeline"
          `Quick
          test_pipeline_lowers_to_shell_ir_pipeline
      ; Alcotest.test_case
          "pipeline_lowers_with_injected_docker_sandbox"
          `Quick
          test_pipeline_lowers_with_injected_docker_sandbox
      ; Alcotest.test_case
          "pipe_character_in_exec_argv_is_literal"
          `Quick
          test_pipe_character_in_exec_argv_is_literal
      ; Alcotest.test_case "cwd_not_absolute" `Quick test_cwd_not_absolute
      ; Alcotest.test_case "env_key_invalid" `Quick test_env_key_invalid
      ])
;;

let () = Alcotest.run "Keeper_tool_bash_input differential" [ suite ]
