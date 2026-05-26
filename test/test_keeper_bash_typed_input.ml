(** Typed tool_execute argv schema tests.

    Exercises [Keeper_tool_bash_input.validate] on representative
    structured inputs and asserts only the typed-schema verdict. *)

open Masc_mcp
module Bash_input = Keeper_tool_bash_input

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
  sample_cmd : string;
  typed : Bash_input.bash_input;
  expect_typed : bool;
  rationale : string;
}

let cases : case list =
  [ { name = "simple_rg"
    ; sample_cmd = "rg pattern lib/"
    ; typed = mk_exec "rg" [ "pattern"; "lib/" ]
    ; expect_typed = true
    ; rationale = "allowlisted executable + plain argv"
    }
  ; { name = "ls_flag"
    ; sample_cmd = "ls -la"
    ; typed = mk_exec "ls" [ "-la" ]
    ; expect_typed = true
    ; rationale = "short flag argv"
    }
  ; { name = "cat_path"
    ; sample_cmd = "cat README.md"
    ; typed = mk_exec "cat" [ "README.md" ]
    ; expect_typed = true
    ; rationale = "relative path argv"
    }
  ; { name = "unknown_executable"
    ; sample_cmd = "unknown_cmd foo"
    ; typed = mk_exec "unknown_cmd" [ "foo" ]
    ; expect_typed = false
    ; rationale = "executable not in dev allowlist"
    }
  ; { name = "find_glob_pattern"
    ; sample_cmd = "find . -name *.ml"
    ; typed = mk_exec "find" [ "."; "-name"; "*.ml" ]
    ; expect_typed = true
    ; rationale =
        "execve-style argv: [*] inside an argv token is literal data, \
         not a shell glob; find handles its own pattern matching"
    }
  ; { name = "git_oneline"
    ; sample_cmd = "git log --oneline -5"
    ; typed = mk_exec "git" [ "log"; "--oneline"; "-5" ]
    ; expect_typed = true
    ; rationale = "multi-arg git invocation"
    }
  ; { name = "pwd_no_args"
    ; sample_cmd = "pwd"
    ; typed = mk_exec "pwd" []
    ; expect_typed = true
    ; rationale = "zero-argv invocation"
    }
  ; { name = "argv_with_nul"
    ; sample_cmd = "echo foo"
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
  Printf.eprintf
    "[typed_tool_execute] %s: sample_cmd=%S | typed=%s | %s\n"
    case.name
    case.sample_cmd
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

let expect_not_allowlisted ~target input =
  match Bash_input.validate ~mode:Bash_input.Dev_full input with
  | Error (Bash_input.Executable_not_allowlisted { name; _ }) ->
    Alcotest.(check string) "blocked target" target name
  | Error error ->
    Alcotest.failf
      "expected Executable_not_allowlisted %S, got %a"
      target
      Bash_input.pp_validation_error
      error
  | Ok () -> Alcotest.failf "expected %S to be blocked" target
;;

let test_wrapper_exec_target_allowlist () =
  List.iter
    (fun input -> expect_not_allowlisted ~target:"rm" input)
    [ mk_exec "env" [ "rm"; "-rf"; "/" ]
    ; mk_exec "opam" [ "exec"; "--"; "rm"; "-rf"; "/" ]
    ; mk_exec "env" [ "opam"; "exec"; "--"; "rm"; "-rf"; "/" ]
    ; mk_exec "opam" [ "exec"; "--"; "env"; "rm"; "-rf"; "/" ]
    ; Bash_input.Pipeline
        { stages =
            [ { executable = "rg"; argv = [ "pattern" ] }
            ; { executable = "env"; argv = [ "rm"; "-rf"; "/" ] }
            ]
        ; cwd = None
        ; env = []
        }
    ];
  expect_not_allowlisted ~target:"'git'" (mk_exec "env" [ "'git'"; "status" ]);
  List.iter
    (fun input ->
      match Bash_input.validate ~mode:Bash_input.Dev_full input with
      | Ok () -> ()
      | Error error ->
        Alcotest.failf
          "expected wrapper target to be allowed, got %a"
          Bash_input.pp_validation_error
          error)
    [ mk_exec "env" [ "git"; "status" ]
    ; mk_exec "opam" [ "exec"; "--"; "git"; "status" ]
    ; mk_exec "env" [ "opam"; "exec"; "--"; "git"; "status" ]
    ; mk_exec "opam" [ "exec"; "--"; "env"; "FOO=bar"; "git"; "status" ]
    ]
;;

let test_standalone_env_rejected () =
  match Bash_input.validate ~mode:Bash_input.Dev_full (mk_exec "env" []) with
  | Error (Bash_input.Empty_argv { executable = "env" }) -> ()
  | Error error ->
    Alcotest.failf
      "expected standalone env to be rejected as empty wrapper, got %a"
      Bash_input.pp_validation_error
      error
  | Ok () -> Alcotest.fail "standalone env should not be accepted"
;;

let test_empty_executable_with_argv_hints_rewrite () =
  match Bash_input.validate ~mode:Bash_input.Dev_full (mk_exec "" [ "ls"; "-la" ]) with
  | Error (Bash_input.Empty_executable { argv }) ->
    Alcotest.(check (list string)) "argv preserved" [ "ls"; "-la" ] argv;
    let msg = Format.asprintf "%a" Bash_input.pp_validation_error (Bash_input.Empty_executable { argv }) in
    Alcotest.(check bool)
      "error points at argv[0]"
      true
      (String_util.contains_substring_ci msg "argv[0]=\"ls\"");
    Alcotest.(check bool)
      "error suggests executable rewrite"
      true
      (String_util.contains_substring_ci msg "executable=\"ls\"");
    Alcotest.(check bool)
      "error removes duplicated executable from argv"
      true
      (String_util.contains_substring_ci msg "argv=[\"-la\"]")
  | Error error ->
    Alcotest.failf
      "expected Empty_executable with argv, got %a"
      Bash_input.pp_validation_error
      error
  | Ok () -> Alcotest.fail "empty executable should not be accepted"
;;

let validation_error_text error = Format.asprintf "%a" Bash_input.pp_validation_error error

let check_not_allowlisted_hint ~name ~mode ~needle () =
  let msg =
    validation_error_text (Bash_input.Executable_not_allowlisted { name; mode })
  in
  Alcotest.(check bool)
    (Printf.sprintf "%s hint" name)
    true
    (String_util.contains_substring_ci msg needle)
;;

let test_not_allowlisted_hints_self_correction () =
  check_not_allowlisted_hint
    ~name:"keeper_tasks_list"
    ~mode:Bash_input.Dev_full
    ~needle:"not shell programs"
    ();
  check_not_allowlisted_hint
    ~name:"gh"
    ~mode:Bash_input.Readonly
    ~needle:"keeper_preflight_check"
    ();
  check_not_allowlisted_hint
    ~name:"bash"
    ~mode:Bash_input.Dev_full
    ~needle:"Shell interpreters"
    ();
  check_not_allowlisted_hint
    ~name:"chmod"
    ~mode:Bash_input.Dev_full
    ~needle:"privileged/destructive"
    ();
  check_not_allowlisted_hint
    ~name:"jq"
    ~mode:Bash_input.Dev_full
    ~needle:"typed task/board tools"
    ()
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

let test_of_json_promotes_empty_exec_from_argv0 () =
  let input =
    parse_json_exn
      (`Assoc
          [ "executable", `String ""
          ; "argv", `List [ `String "gh"; `String "pr"; `String "list" ]
          ; "cwd", `String "/tmp"
          ])
  in
  match input with
  | Bash_input.Exec { executable; argv; cwd; env } ->
    Alcotest.(check string) "promoted executable" "gh" executable;
    Alcotest.(check (list string)) "argv without command duplicate" [ "pr"; "list" ] argv;
    Alcotest.(check (option string)) "cwd" (Some "/tmp") cwd;
    Alcotest.(check (list (pair string string))) "env" [] env
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

let test_of_json_promotes_empty_pipeline_stage_from_argv0 () =
  let input =
    parse_json_exn
      (`Assoc
          [ ( "pipeline"
            , `List
                [ `Assoc
                    [ "executable", `String ""
                    ; "argv", `List [ `String "rg"; `String "--files"; `String "lib" ]
                    ]
                ; `Assoc
                    [ "executable", `String "head"; "argv", `List [ `String "-20" ] ]
                ] )
          ; "cwd", `String "/tmp"
          ])
  in
  match input with
  | Bash_input.Pipeline { stages; cwd; env } ->
    Alcotest.(check (option string)) "cwd" (Some "/tmp") cwd;
    Alcotest.(check (list (pair string string))) "env" [] env;
    (match stages with
     | [ first; second ] ->
       Alcotest.(check string) "first executable" "rg" first.executable;
       Alcotest.(check (list string)) "first argv" [ "--files"; "lib" ] first.argv;
       Alcotest.(check string) "second executable" "head" second.executable;
       Alcotest.(check (list string)) "second argv" [ "-20" ] second.argv
     | _ -> Alcotest.fail "expected exactly two stages")
  | Bash_input.Exec _ -> Alcotest.fail "expected Pipeline"
;;

let test_of_json_rejects_cmd_string_only () =
  let msg =
    parse_json_error (`Assoc [ "cmd", `String "rg pattern lib/" ])
  in
  Alcotest.(check bool)
    "error mentions typed input"
    true
    (String_util.contains_substring_ci msg "typed Shell IR input")
;;

let test_of_json_rejects_cmd_string_with_exec () =
  let msg =
    parse_json_error
      (`Assoc [ "cmd", `String "rg pattern lib/"; "executable", `String "rg" ])
  in
  Alcotest.(check bool)
    "error mentions typed input"
    true
    (String_util.contains_substring_ci msg "typed Shell IR input")
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

let test_of_json_prefers_exec_when_both_present () =
  let input =
    parse_json_exn
      (`Assoc
          [ "executable", `String "echo"
          ; "argv", `List [ `String "hello" ]
          ; "pipeline", `List [ `Assoc [ "executable", `String "wc" ] ]
          ])
  in
  match input with
  | Bash_input.Exec { executable; argv; cwd; env } ->
    Alcotest.(check string) "executable takes precedence" "echo" executable;
    Alcotest.(check (list string)) "argv preserved" [ "hello" ] argv;
    Alcotest.(check (option string)) "cwd" None cwd;
    Alcotest.(check (list (pair string string))) "env" [] env
  | Bash_input.Pipeline _ -> Alcotest.fail "expected Exec when both present"
;;

let test_of_json_rejects_stages_alias () =
  let msg =
    parse_json_error
      (`Assoc [ "stages", `List [ `Assoc [ "argv", `List [] ] ] ])
  in
  Alcotest.(check bool)
    "error rejects stages field"
    true
    (String_util.contains_substring_ci msg "$.stages is not a supported typed Bash field")
;;

let shell_arg_string = function
  | Masc_exec.Shell_ir.Lit (s, _) -> s
  | Masc_exec.Shell_ir.Var (name, _) -> "$" ^ name
  | Masc_exec.Shell_ir.Concat _ -> "<concat>"
;;

let shell_simple_tuple (simple : Masc_exec.Shell_ir.simple) =
  ( Masc_exec.Exec_program.to_string simple.bin
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
    ()
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
  ("typed tool_execute argv schema",
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
      ; Alcotest.test_case
          "wrapper_exec_target_allowlist"
          `Quick
          test_wrapper_exec_target_allowlist
      ; Alcotest.test_case
          "standalone_env_rejected"
          `Quick
          test_standalone_env_rejected
      ; Alcotest.test_case
          "empty_executable_with_argv_hints_rewrite"
          `Quick
          test_empty_executable_with_argv_hints_rewrite
      ; Alcotest.test_case
          "not_allowlisted_hints_self_correction"
          `Quick
          test_not_allowlisted_hints_self_correction
      ; Alcotest.test_case "of_json_exec" `Quick test_of_json_exec
      ; Alcotest.test_case
          "of_json_promotes_empty_exec_from_argv0"
          `Quick
          test_of_json_promotes_empty_exec_from_argv0
      ; Alcotest.test_case "of_json_pipeline" `Quick test_of_json_pipeline
      ; Alcotest.test_case
          "of_json_promotes_empty_pipeline_stage_from_argv0"
          `Quick
          test_of_json_promotes_empty_pipeline_stage_from_argv0
      ; Alcotest.test_case
          "of_json_rejects_cmd_string_only"
          `Quick
          test_of_json_rejects_cmd_string_only
      ; Alcotest.test_case
          "of_json_rejects_cmd_string_with_exec"
          `Quick
          test_of_json_rejects_cmd_string_with_exec
      ; Alcotest.test_case
          "of_json_rejects_non_string_argv"
          `Quick
          test_of_json_rejects_non_string_argv
      ; Alcotest.test_case
          "of_json_prefers_exec_when_both_present"
          `Quick
          test_of_json_prefers_exec_when_both_present
      ; Alcotest.test_case
          "of_json_rejects_stages_alias"
          `Quick
          test_of_json_rejects_stages_alias
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

let () = Alcotest.run "Keeper_tool_bash_input typed" [ suite ]
