(** Typed tool_execute argv schema tests.

    Exercises [Keeper_tool_execute_typed_input.validate] on representative
    structured inputs and asserts only the typed-schema verdict. *)

open Masc
module Execute_input = Keeper_tool_execute_typed_input

let typed_ok input =
  match Execute_input.validate input with
  | Ok () -> true
  | Error _ -> false
;;

let mk_exec executable argv =
  Execute_input.Exec
    { executable
    ; argv
    ; cwd = None
    ; env = []
    ; stdin = Execute_input.Inherit
    ; stdout = Execute_input.Inherit
    ; stderr = Execute_input.Inherit
    }
;;

let parse_json_exn json =
  match Execute_input.of_json json with
  | Ok input -> input
  | Error msg -> Alcotest.failf "of_json failed: %s" msg
;;

let parse_json_error json =
  match Execute_input.of_json json with
  | Ok _ -> Alcotest.fail "of_json unexpectedly succeeded"
  | Error msg -> msg
;;

type case = {
  name : string;
  sample_cmd : string;
  typed : Execute_input.execute_input;
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
  ; { name = "grep_recursive_logged_shape"
    ; sample_cmd = "grep -rn try_acquire repos/masc/lib --include=*.ml"
    ; typed =
        mk_exec
          "grep"
          [ "-rn"; "try_acquire"; "repos/masc/lib"; "--include=*.ml" ]
    ; expect_typed = true
    ; rationale =
        "safe grep search shape observed in keeper Execute logs stays allowlisted"
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
  ; { name = "duplicate_executable_argv0"
    ; sample_cmd = "cat cat README.md"
    ; typed = mk_exec "cat" [ "cat"; "README.md" ]
    ; expect_typed = false
    ; rationale =
        "typed Execute argv excludes argv[0]; repeating executable would \
         execute the wrong file list"
    }
  ; { name = "unknown_executable"
    ; sample_cmd = "unknown_cmd foo"
    ; typed = mk_exec "unknown_cmd" [ "foo" ]
    ; expect_typed = true
    ; rationale =
        "structural validation allows any executable string; admission is \
         enforced by Shell IR risk classification at runtime"
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
  ; { name = "argv_with_newlines"
    ; sample_cmd = "gh pr create --body '<multiline markdown>'"
    ; typed =
        mk_exec
          "gh"
          [ "pr"
          ; "create"
          ; "--body"
          ; "Replace self-shadowing `match sandbox_root with | Some _ -> \
             sandbox_root | ...` with `Option.first_some sandbox_root \
             ctx.sandbox_root`.\n\
             \n\
             No behavioral change. Single commit."
          ]
    ; expect_typed = true
    ; rationale =
        "execve-style argv: markdown backticks, pipe characters, and newlines \
         inside a gh body are literal argument data"
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
    Execute_input.Pipeline { stages = []; cwd = None; env = [] }
  in
  Alcotest.(check bool)
    "pipeline with empty stages is rejected"
    false
    (typed_ok input)
;;

let test_pipeline_single_stage_rejected () =
  let input =
    Execute_input.Pipeline
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
    Execute_input.Pipeline
      { stages =
          [ { executable = "rg"; argv = [ "pattern" ] }
          ; { executable = "unknown_cmd"; argv = [] }
          ]
      ; cwd = None
      ; env = []
      }
  in
  Alcotest.(check bool)
    "pipeline: structural validation does not reject unknown executables"
    true
    (typed_ok input)
;;

let test_empty_executable_with_argv_hints_rewrite () =
  match Execute_input.validate  (mk_exec "" [ "ls"; "-la" ]) with
  | Error (Execute_input.Empty_executable { argv }) ->
    Alcotest.(check (list string)) "argv preserved" [ "ls"; "-la" ] argv;
    let msg = Format.asprintf "%a" Execute_input.pp_validation_error (Execute_input.Empty_executable { argv }) in
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
      Execute_input.pp_validation_error
      error
  | Ok () -> Alcotest.fail "empty executable should not be accepted"
;;

let test_duplicate_executable_argv0_rejected () =
  match
    Execute_input.validate
            (mk_exec "cat" [ "cat"; "-n"; "keeper_sandbox.mli" ])
  with
  | Error (Execute_input.Executable_repeated_in_argv0 { executable; argv }) ->
    Alcotest.(check string) "executable" "cat" executable;
    Alcotest.(check (list string))
      "argv preserved for rewrite"
      [ "cat"; "-n"; "keeper_sandbox.mli" ]
      argv;
    let msg =
      Format.asprintf
        "%a"
        Execute_input.pp_validation_error
        (Execute_input.Executable_repeated_in_argv0 { executable; argv })
    in
    Alcotest.(check bool)
      "error points at argv[0]"
      true
      (String_util.contains_substring_ci msg "argv[0]");
    Alcotest.(check bool)
      "error rewrites without duplicated executable"
      true
      (String_util.contains_substring_ci
         msg
         "argv=[\"-n\",\"keeper_sandbox.mli\"]")
  | Error error ->
    Alcotest.failf
      "expected Executable_repeated_in_argv0, got %a"
      Execute_input.pp_validation_error
      error
  | Ok () -> Alcotest.fail "duplicated argv[0] should not be accepted"
;;

(* Regression: validate-bypass paths (to_shell_ir_unvalidated /
   shell_simple) must preserve argv so the helpful "argv[0] looks like
   the command name" hint is reachable. Before the fix shell_bin
   fabricated [argv = []], which collapsed the diagnostic into the
   generic catch-all and kept the LLM in a self-correction deadlock.
   Live reproducer: keeper-qa-king sent
     Exec { executable=""; argv=["gh";"pr";"list";...] }
   from resolve_typed_git_cwd, hit shell_bin, and got the wrong
   message in 2026-05-26 logs. *)
let test_unvalidated_path_preserves_argv_in_error () =
  let input = mk_exec "" [ "gh"; "pr"; "list"; "--state"; "open" ] in
  match Execute_input.to_shell_ir_unvalidated  input with
  | Error (Execute_input.Empty_executable { argv }) ->
    Alcotest.(check (list string))
      "argv preserved through shell_simple/shell_bin"
      [ "gh"; "pr"; "list"; "--state"; "open" ]
      argv;
    let msg =
      Format.asprintf
        "%a"
        Execute_input.pp_validation_error
        (Execute_input.Empty_executable { argv })
    in
    Alcotest.(check bool)
      "rewrite hint points at argv[0]"
      true
      (String_util.contains_substring_ci msg "argv[0]=\"gh\"")
  | Error error ->
    Alcotest.failf
      "expected Empty_executable with preserved argv, got %a"
      Execute_input.pp_validation_error
      error
  | Ok _ ->
    Alcotest.fail "empty executable should not produce a Shell IR"
;;

let validation_error_text error = Format.asprintf "%a" Execute_input.pp_validation_error error


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
  | Execute_input.Exec { executable; argv; cwd; env; _ } ->
    Alcotest.(check string) "executable" "rg" executable;
    Alcotest.(check (list string)) "argv" [ "pattern"; "lib/" ] argv;
    Alcotest.(check (option string)) "cwd" (Some "/tmp") cwd;
    Alcotest.(check (list (pair string string))) "env" [ "LC_ALL", "C" ] env
  | Execute_input.Pipeline _ -> Alcotest.fail "expected Exec"
;;

let test_of_json_rejects_argv_without_executable () =
  let msg =
    parse_json_error
      (`Assoc
          [ "argv", `List [ `String "git"; `String "status"; `String "--short" ]
          ; "cwd", `String "/tmp"
          ; "env", `Assoc [ "LC_ALL", `String "C" ]
          ])
  in
  Alcotest.(check bool)
    "error requires explicit command form"
    true
    (String_util.contains_substring_ci msg "$.executable or $.pipeline is required")
;;

let test_of_json_preserves_duplicate_executable_argv0 () =
  let input =
    parse_json_exn
      (`Assoc
          [ "executable", `String "cat"
          ; "argv", `List [ `String "cat"; `String "repos/masc/README.md" ]
          ])
  in
  match input with
  | Execute_input.Exec { executable; argv; _ } ->
    Alcotest.(check string) "executable" "cat" executable;
    Alcotest.(check (list string))
      "argv remains caller-authored"
      [ "cat"; "repos/masc/README.md" ]
      argv
  | Execute_input.Pipeline _ -> Alcotest.fail "expected Exec"
;;

let test_of_json_rejects_empty_argv_without_executable () =
  let msg =
    parse_json_error (`Assoc [ "argv", `List [] ])
  in
  Alcotest.(check bool)
    "error still requires a command form"
    true
    (String_util.contains_substring_ci msg "$.executable or $.pipeline is required")
;;

let test_of_json_rejects_empty_pipeline_with_executable () =
  let msg =
    parse_json_error
      (`Assoc
          [ "executable", `String "echo"
          ; "argv", `List [ `String "hello" ]
          ; "pipeline", `List []
          ])
  in
  Alcotest.(check bool)
    "error rejects mutually exclusive fields"
    true
    (String_util.contains_substring_ci msg "mutually exclusive")
;;

let test_of_json_keeps_empty_exec_for_validation () =
  let input =
    parse_json_exn
      (`Assoc
          [ "executable", `String ""
          ; "argv", `List [ `String "gh"; `String "pr"; `String "list" ]
          ; "cwd", `String "/tmp"
          ])
  in
  match input with
  | Execute_input.Exec { executable; argv; cwd; env; _ } ->
    Alcotest.(check string) "empty executable is not promoted" "" executable;
    Alcotest.(check (list string))
      "argv0 command remains caller-authored"
      [ "gh"; "pr"; "list" ]
      argv;
    Alcotest.(check (option string)) "cwd" (Some "/tmp") cwd;
    Alcotest.(check (list (pair string string))) "env" [] env
  | Execute_input.Pipeline _ -> Alcotest.fail "expected Exec"
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
  | Execute_input.Pipeline { stages; cwd; env } ->
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
  | Execute_input.Exec _ -> Alcotest.fail "expected Pipeline"
;;

let test_of_json_pipeline_preserves_duplicate_stage_argv0 () =
  let input =
    parse_json_exn
      (`Assoc
          [ ( "pipeline"
            , `List
                [ `Assoc
                    [ "executable", `String "printf"
                    ; "argv", `List [ `String "printf"; `String "hello" ]
                    ]
                ; `Assoc
                    [ "executable", `String "wc"
                    ; "argv", `List [ `String "wc"; `String "-c" ]
                    ]
                ] )
          ])
  in
  match input with
  | Execute_input.Pipeline { stages; _ } ->
    (match stages with
     | [ first; second ] ->
       Alcotest.(check (list string))
         "first argv remains caller-authored"
         [ "printf"; "hello" ]
         first.argv;
       Alcotest.(check (list string))
         "second argv remains caller-authored"
         [ "wc"; "-c" ]
         second.argv
     | _ -> Alcotest.fail "expected exactly two stages")
  | Execute_input.Exec _ -> Alcotest.fail "expected Pipeline"
;;

let test_of_json_keeps_empty_pipeline_stage_for_validation () =
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
  | Execute_input.Pipeline { stages; cwd; env } ->
    Alcotest.(check (option string)) "cwd" (Some "/tmp") cwd;
    Alcotest.(check (list (pair string string))) "env" [] env;
    (match stages with
     | [ first; second ] ->
       Alcotest.(check string) "first executable remains empty" "" first.executable;
       Alcotest.(check (list string))
         "first argv0 command remains caller-authored"
         [ "rg"; "--files"; "lib" ]
         first.argv;
       Alcotest.(check string) "second executable" "head" second.executable;
       Alcotest.(check (list string)) "second argv" [ "-20" ] second.argv
     | _ -> Alcotest.fail "expected exactly two stages")
  | Execute_input.Exec _ -> Alcotest.fail "expected Pipeline"
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

let test_of_json_rejects_exec_and_pipeline_together () =
  let msg =
    parse_json_error
      (`Assoc
          [ "executable", `String "echo"
          ; "argv", `List [ `String "hello" ]
          ; "pipeline", `List [ `Assoc [ "executable", `String "wc" ] ]
          ])
  in
  Alcotest.(check bool)
    "error mentions mutual exclusion"
    true
    (String_util.contains_substring_ci msg "mutually exclusive")
;;

(* Pipeline은 redirect_target triple을 갖지 않는다(Exec variant 전용). stdin/stdout/stderr가
   pipeline과 함께 오면 이전에는 of_json이 조용히 버렸다(silent failure). 명시적 거부를 고정. *)
let test_of_json_rejects_pipeline_with_redirect () =
  let msg =
    parse_json_error
      (`Assoc
          [ ( "pipeline"
            , `List
                [ `Assoc
                    [ "executable", `String "printf"; "argv", `List [ `String "x" ] ]
                ; `Assoc [ "executable", `String "wc" ]
                ] )
          ; "stdout", `Assoc [ "file", `String "/tmp/out.log" ]
          ])
  in
  Alcotest.(check bool)
    "error states redirects unsupported with pipeline"
    true
    (String_util.contains_substring_ci msg "not supported with $.pipeline")
;;

let test_of_json_rejects_stages_alias () =
  let msg =
    parse_json_error
      (`Assoc [ "stages", `List [ `Assoc [ "argv", `List [] ] ] ])
  in
  Alcotest.(check bool)
    "error rejects stages field"
    true
    (String_util.contains_substring_ci msg "$.stages is not a supported typed Execute field")
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
  match Execute_input.to_shell_ir  input with
  | Ok ir -> ir
  | Error error ->
    Alcotest.failf
      "to_shell_ir failed: %a"
      Execute_input.pp_validation_error
      error
;;

let test_pipeline_lowers_to_shell_ir_pipeline () =
  let input =
    Execute_input.Pipeline
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

let test_exec_lowering_rejects_duplicate_executable_argv () =
  let input =
    Execute_input.Exec
      { executable = "git"
      ; argv = [ "git"; "status" ]
      ; cwd = None
      ; env = []
      ; stdin = Execute_input.Inherit
      ; stdout = Execute_input.Inherit
      ; stderr = Execute_input.Inherit
      }
  in
  match Execute_input.to_shell_ir  input with
  | Error
      (Execute_input.Executable_repeated_in_argv0
        { executable = "git"; argv = [ "git"; "status" ] }) -> ()
  | Error error ->
    Alcotest.failf
      "expected Executable_repeated_in_argv0, got %a"
      Execute_input.pp_validation_error
      error
  | Ok ir ->
    Alcotest.failf
      "duplicated argv[0] should not produce Shell IR, got %a"
      Masc_exec.Shell_ir.pp
      ir
;;

let docker_test_sandbox () =
  Masc_exec.Sandbox_target.docker
    ~image:"typed-docker"
    ~runner:(fun ~on_stdout_chunk:_ ~on_stderr_chunk:_ ~stdin_content:_ ~argv:_ ~env:_ ~cwd:_ ->
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
    Execute_input.Pipeline
      { stages =
          [ { executable = "echo"; argv = [ "hello" ] }
          ; { executable = "wc"; argv = [ "-c" ] }
          ]
      ; cwd = Some "/tmp"
      ; env = []
      }
  in
  match
    Execute_input.to_shell_ir
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
      Execute_input.pp_validation_error
      error
;;

let test_pipe_character_in_exec_argv_is_literal () =
  let input =
    Execute_input.Exec
      { executable = "echo"
      ; argv = [ "foo|bar" ]
      ; cwd = None
      ; env = []
      ; stdin = Execute_input.Inherit
      ; stdout = Execute_input.Inherit
      ; stderr = Execute_input.Inherit
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

let test_standalone_pipe_operator_in_exec_argv_rejected () =
  let check_case ~name ~token ~index argv =
    let input =
      Execute_input.Exec
        { executable = "tail"
        ; argv
        ; cwd = None
        ; env = []
        ; stdin = Execute_input.Inherit
        ; stdout = Execute_input.Inherit
        ; stderr = Execute_input.Inherit
        }
    in
    match Execute_input.validate input with
    | Error
        (Execute_input.Argv_contains_shell_pipeline_operator
          { executable; index = actual_index; token = actual_token } as err) ->
      Alcotest.(check string) (name ^ " executable") "tail" executable;
      Alcotest.(check int) (name ^ " index") index actual_index;
      Alcotest.(check string) (name ^ " token") token actual_token;
      let msg = Format.asprintf "%a" Execute_input.pp_validation_error err in
      Alcotest.(check bool)
        (name ^ " message points to Execute pipeline field")
        true
        (String_util.contains_substring_ci msg "top-level pipeline field");
      Alcotest.(check bool)
        (name ^ " message forbids sh/bash wrapper")
        true
        (String_util.contains_substring_ci msg "do not wrap this in sh/bash")
    | Error other ->
      Alcotest.failf
        "%s: expected Argv_contains_shell_pipeline_operator, got %a"
        name
        Execute_input.pp_validation_error
        other
    | Ok () -> Alcotest.failf "%s: expected standalone %S to be rejected" name token
  in
  check_case
    ~name:"tail_pipe_head_log_shape"
    ~token:"|"
    ~index:3
    [ "-n"; "200"; "/tmp/keeper.log"; "|"; "head"; "-80" ];
  check_case
    ~name:"stderr_pipe_operator"
    ~token:"|&"
    ~index:2
    [ "-f"; "/tmp/keeper.log"; "|&"; "head"; "-80" ]
;;

let test_gh_multiline_body_lowers_to_literal_argv () =
  let body =
    "Replace self-shadowing `match sandbox_root with | Some _ -> sandbox_root \
     | ...` with `Option.first_some sandbox_root ctx.sandbox_root`.\n\
     \n\
     No behavioral change. Single commit."
  in
  let input =
    Execute_input.Exec
      { executable = "gh"
      ; argv = [ "pr"; "create"; "--body"; body ]
      ; cwd = None
      ; env = []
      ; stdin = Execute_input.Inherit
      ; stdout = Execute_input.Inherit
      ; stderr = Execute_input.Inherit
      }
  in
  match to_shell_ir_exn input with
  | Masc_exec.Shell_ir.Simple simple ->
    let argv =
      List.filter_map
        (function
          | Masc_exec.Shell_ir.Lit (value, _) -> Some value
          | Masc_exec.Shell_ir.Concat _ | Masc_exec.Shell_ir.Var _ -> None)
        simple.args
    in
    Alcotest.(check (list string))
      "gh argv preserved"
      [ "pr"; "create"; "--body"; body ]
      argv
  | Masc_exec.Shell_ir.Pipeline _ ->
    Alcotest.fail "multiline gh body must not create Shell_ir.Pipeline"
;;

let test_cwd_not_absolute () =
  let input =
    Execute_input.Exec
      { executable = "ls"
      ; argv = []
      ; cwd = Some "relative/path"
      ; env = []
      ; stdin = Execute_input.Inherit
      ; stdout = Execute_input.Inherit
      ; stderr = Execute_input.Inherit
      }
  in
  Alcotest.(check bool)
    "Cwd_not_absolute: relative cwd rejected"
    false
    (typed_ok input)
;;

let test_env_key_invalid () =
  let input =
    Execute_input.Exec
      { executable = "ls"
      ; argv = []
      ; cwd = None
      ; env = [ "FOO BAR", "value" ]
      ; stdin = Execute_input.Inherit
      ; stdout = Execute_input.Inherit
      ; stderr = Execute_input.Inherit
      }
  in
  Alcotest.(check bool)
    "Env_key_invalid: env key with space rejected"
    false
    (typed_ok input)
;;

(* RFC-0198 Phase A: redirection-shape argv tokens.  Validation must
   reject these with the typed [Argv_contains_shell_redirection] error
   so the caller (LLM) receives a typed alternative instead of the
   runtime "unknown primary" failure observed in fleet (2026-05-27
   18:56 KST find: 2>/dev/null primary error). *)
let expect_redirection_rejected ~token input =
  match Execute_input.validate  input with
  | Error (Execute_input.Argv_contains_shell_redirection { token = t; _ }) ->
    Alcotest.(check string) "rejected token text" token t
  | Error other ->
    Alcotest.failf
      "expected Argv_contains_shell_redirection for %S, got %a"
      token
      Execute_input.pp_validation_error
      other
  | Ok () -> Alcotest.failf "expected %S to be rejected" token
;;

let test_shell_redirection_token_rejected () =
  (* Each fixture sends [find] (allowlisted, evidence shape from
     fleet log) with a redirection-shape token at argv[N].  Every
     shape must surface as a typed-rejection. *)
  List.iter
    (fun (token, argv) ->
      let input =
        Execute_input.Exec
          { executable = "find"
          ; argv
          ; cwd = None
          ; env = []
          ; stdin = Execute_input.Inherit
          ; stdout = Execute_input.Inherit
          ; stderr = Execute_input.Inherit
          }
      in
      expect_redirection_rejected ~token input)
    [ "2>/dev/null", [ "."; "-name"; "*.ml"; "2>/dev/null" ]
    ; ">", [ "."; "-name"; "*.ml"; ">" ]
    ; ">>", [ "."; "-name"; "*.ml"; ">>" ]
    ; "2>", [ "."; "-name"; "*.ml"; "2>" ]
    ; "2>&1", [ "."; "-name"; "*.ml"; "2>&1" ]
    ; ">&2", [ "."; "-name"; "*.ml"; ">&2" ]
    ; "<", [ "."; "-name"; "*.ml"; "<" ]
    ; "0<", [ "."; "-name"; "*.ml"; "0<" ]
    ; "<&0", [ "."; "-name"; "*.ml"; "<&0" ]
    ; "&1", [ "."; "-name"; "*.ml"; "&1" ]
    ; ">>/tmp/out", [ "."; "-name"; "*.ml"; ">>/tmp/out" ]
    ; ">./relative.log", [ "."; "-name"; "*.ml"; ">./relative.log" ]
    ]
;;

(* Regression guard: tokens that *contain* shell metacharacters as
   payload data must remain allowed.  RFC-0091 PR-1's design constraint
   (.mli §"Design constraints") explicitly accepts these as literal
   execve arguments. *)
let test_legitimate_metachar_still_allowed () =
  List.iter
    (fun (rationale, argv) ->
      let input =
        Execute_input.Exec
          { executable = "find"
          ; argv
          ; cwd = None
          ; env = []
          ; stdin = Execute_input.Inherit
          ; stdout = Execute_input.Inherit
          ; stderr = Execute_input.Inherit
          }
      in
      match Execute_input.validate  input with
      | Ok () -> ()
      | Error err ->
        Alcotest.failf
          "regression: %s argv=%s wrongly rejected: %a"
          rationale
          (String.concat " " argv)
          Execute_input.pp_validation_error
          err)
    [ "find-glob literal '*.ml'", [ "."; "-name"; "*.ml" ]
    ; "find-name with literal '$HOME'", [ "."; "-name"; "$HOME" ]
    ; "find-name with literal semicolon", [ "."; "-name"; ";abc" ]
    ; "find-name with literal pipe", [ "."; "-name"; "|abc" ]
    ; "find-name with literal '>' inside payload", [ "."; "-name"; "a>b" ]
    ; "find-name with literal '<' inside payload", [ "."; "-name"; "a<b" ]
    ; "find-name with literal '&' inside payload", [ "."; "-name"; "a&b" ]
    ; "find-name with '>foo' (no leading fd, but path payload-looking)", [ "."; "-name"; "X>foo" ]
    ; "ampersand by itself is execve-literal", [ "."; "-name"; "&" ]
    ; "newline is execve-literal payload", [ "."; "-name"; "foo\nbar" ]
    ; "carriage return is execve-literal payload", [ "."; "-name"; "foo\rbar" ]
    ]
;;

let contains_substring haystack needle =
  let hlen = String.length haystack in
  let nlen = String.length needle in
  if nlen = 0
  then true
  else if nlen > hlen
  then false
  else
    let rec scan i =
      if i + nlen > hlen
      then false
      else if String.sub haystack i nlen = needle
      then true
      else scan (i + 1)
    in
    scan 0
;;

let test_redirection_rejected_emits_typed_alternative () =
  (* The error message must steer the caller toward typed alternatives
     (Phase B redirect fields or the public Execute.pipeline shape), not toward
     stale internal constructor names. *)
  let input =
    Execute_input.Exec
      { executable = "find"
      ; argv = [ "."; "-name"; "*.ml"; "2>/dev/null" ]
      ; cwd = None
      ; env = []
      ; stdin = Execute_input.Inherit
      ; stdout = Execute_input.Inherit
      ; stderr = Execute_input.Inherit
      }
  in
  match Execute_input.validate  input with
  | Error (Execute_input.Argv_contains_shell_redirection _ as err) ->
    let msg = Format.asprintf "%a" Execute_input.pp_validation_error err in
    Alcotest.(check bool)
      "error mentions stderr discard shape"
      true
      (contains_substring msg "stderr={discard:true}");
    Alcotest.(check bool)
      "error mentions Phase B RFC marker"
      true
      (contains_substring msg "RFC-0198")
  | _ -> Alcotest.fail "expected Argv_contains_shell_redirection"
;;

let test_validation_error_alternatives () =
  let check_alts ~name err expected =
    let actual = Execute_input.validation_error_alternatives err in
    Alcotest.(check (list string)) name expected actual
  in
  check_alts
    ~name:"Argv_contains_shell_redirection alternatives"
    (Execute_input.Argv_contains_shell_redirection
       { executable = "find"; index = 3; token = "2>/dev/null" })
    [ "stderr:{discard:true}"; "stdout:{discard:true}"; "Execute.pipeline" ];
  check_alts
    ~name:"Argv_contains_shell_metachar alternatives"
    (Execute_input.Argv_contains_shell_metachar
       { executable = "find"; index = 3; token = "foo\nbar" })
    [];
  check_alts
    ~name:"Argv_contains_shell_pipeline_operator alternatives"
    (Execute_input.Argv_contains_shell_pipeline_operator
       { executable = "tail"; index = 3; token = "|" })
    [ "Execute.pipeline" ];
  check_alts
    ~name:"Empty_executable has no alternatives"
    (Execute_input.Empty_executable { argv = [ "ls" ] })
    [];
  check_alts
    ~name:"Executable_repeated_in_argv0 has no alternatives"
    (Execute_input.Executable_repeated_in_argv0
       { executable = "cat"; argv = [ "cat"; "file" ] })
    [];
  check_alts
    ~name:"Cwd_not_absolute has no alternatives"
    (Execute_input.Cwd_not_absolute "relative")
    []
;;

(* RFC-0198 Phase B: typed [stdin]/[stdout]/[stderr] redirect fields. *)

let mk_exec_with_redirects
      ?(executable = "rg")
      ?(argv = [ "pattern" ])
      ?(cwd = Some "/tmp")
      ?(env = [])
      ?(stdin = Execute_input.Inherit)
      ?(stdout = Execute_input.Inherit)
      ?(stderr = Execute_input.Inherit)
      ()
  =
  Execute_input.Exec
    { executable; argv; cwd; env; stdin; stdout; stderr }
;;

let count_redirects ir =
  match ir with
  | Masc_exec.Shell_ir.Simple simple -> List.length simple.redirects
  | Masc_exec.Shell_ir.Pipeline _ ->
    Alcotest.fail "single Exec must not lower to Pipeline"
;;

let redirect_at ir n =
  match ir with
  | Masc_exec.Shell_ir.Simple simple -> List.nth simple.redirects n
  | _ -> Alcotest.fail "expected Simple IR"
;;

let test_redirect_defaults_inherit_emits_no_ir_entries () =
  match
    Execute_input.to_shell_ir
            (mk_exec_with_redirects ())
  with
  | Ok ir ->
    Alcotest.(check int)
      "defaults emit zero redirect IR entries"
      0
      (count_redirects ir)
  | Error err ->
    Alcotest.failf
      "default redirects should validate, got %a"
      Execute_input.pp_validation_error
      err
;;

let test_redirect_discard_combinations () =
  let cases =
    [ "stderr_discard_only", Execute_input.Inherit, Execute_input.Inherit, Execute_input.Discard, 1
    ; "stdout_discard_only", Execute_input.Inherit, Execute_input.Discard, Execute_input.Inherit, 1
    ; "stdin_discard_only",  Execute_input.Discard, Execute_input.Inherit, Execute_input.Inherit, 1
    ; "stdout_stderr_discard", Execute_input.Inherit, Execute_input.Discard, Execute_input.Discard, 2
    ; "all_three_discard", Execute_input.Discard, Execute_input.Discard, Execute_input.Discard, 3
    ]
  in
  List.iter
    (fun (name, stdin, stdout, stderr, expected_count) ->
      let input = mk_exec_with_redirects ~stdin ~stdout ~stderr () in
      match Execute_input.to_shell_ir  input with
      | Ok ir ->
        Alcotest.(check int)
          (Printf.sprintf "%s emits %d redirect IR entries" name expected_count)
          expected_count
          (count_redirects ir)
      | Error err ->
        Alcotest.failf
          "case %S: validation failed: %a"
          name
          Execute_input.pp_validation_error
          err)
    cases
;;

let test_redirect_file_absolute_path_emits_ir () =
  let input =
    mk_exec_with_redirects
      ~stdout:(Execute_input.File "/tmp/out.log")
      ()
  in
  match Execute_input.to_shell_ir  input with
  | Ok ir ->
    Alcotest.(check int) "file redirect emits 1 entry" 1 (count_redirects ir);
    (match redirect_at ir 0 with
     | Masc_exec.Redirect_scope.File { fd = 1; target; mode = Masc_exec.Redirect_scope.Write } ->
       Alcotest.(check string)
         "stdout file target path"
         "/tmp/out.log"
         (Masc_exec.Path_scope.raw target)
     | _ -> Alcotest.fail "expected fd=1 Write to /tmp/out.log")
  | Error err ->
    Alcotest.failf "should validate, got %a" Execute_input.pp_validation_error err
;;

let test_redirect_file_relative_path_rejected () =
  let input =
    mk_exec_with_redirects
      ~stderr:(Execute_input.File "relative/path.log")
      ()
  in
  match Execute_input.validate  input with
  | Error (Execute_input.Redirect_path_not_absolute { fd = 2; path }) ->
    Alcotest.(check string) "rejected relative path" "relative/path.log" path
  | Error other ->
    Alcotest.failf
      "expected Redirect_path_not_absolute, got %a"
      Execute_input.pp_validation_error
      other
  | Ok () -> Alcotest.fail "relative redirect path should be rejected"
;;

let test_redirect_stderr_discard_equivalent_to_dev_null_redirect () =
  (* Equivalence with Bash.parse_string "rg pattern 2>/dev/null":
     both must produce a single redirect targeting /dev/null on fd=2
     with Write mode. *)
  let input = mk_exec_with_redirects ~stderr:Execute_input.Discard () in
  match Execute_input.to_shell_ir  input with
  | Ok ir ->
    (match redirect_at ir 0 with
     | Masc_exec.Redirect_scope.File { fd = 2; target; mode = Masc_exec.Redirect_scope.Write } ->
       Alcotest.(check string)
         "discard_stderr targets /dev/null"
         "/dev/null"
         (Masc_exec.Path_scope.raw target)
     | _ -> Alcotest.fail "expected fd=2 Write to /dev/null")
  | Error err ->
    Alcotest.failf "should validate, got %a" Execute_input.pp_validation_error err
;;

let test_of_json_parses_discard_stderr_shorthand () =
  let json =
    `Assoc
      [ "executable", `String "rg"
      ; "argv", `List [ `String "pattern" ]
      ; "cwd", `String "/tmp"
      ; "stderr", `Assoc [ "discard", `Bool true ]
      ]
  in
  let input = parse_json_exn json in
  match input with
  | Execute_input.Exec { stderr = Execute_input.Discard; _ } -> ()
  | _ -> Alcotest.fail "of_json must produce stderr=Discard"
;;

let test_of_json_rejects_redirect_with_both_discard_and_file () =
  let json =
    `Assoc
      [ "executable", `String "rg"
      ; "argv", `List [ `String "pattern" ]
      ; "cwd", `String "/tmp"
      ; ( "stderr"
        , `Assoc
            [ "discard", `Bool true; "file", `String "/tmp/out.log" ] )
      ]
  in
  match Execute_input.of_json json with
  | Ok _ -> Alcotest.fail "of_json must reject conflicting discard+file"
  | Error _ -> ()
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
          "empty_executable_with_argv_hints_rewrite"
          `Quick
          test_empty_executable_with_argv_hints_rewrite
      ; Alcotest.test_case
          "duplicate_executable_argv0_rejected"
          `Quick
          test_duplicate_executable_argv0_rejected
      ; Alcotest.test_case
          "unvalidated_path_preserves_argv_in_error"
          `Quick
          test_unvalidated_path_preserves_argv_in_error
      ; Alcotest.test_case "of_json_exec" `Quick test_of_json_exec
      ; Alcotest.test_case
          "of_json_rejects_argv_without_executable"
          `Quick
          test_of_json_rejects_argv_without_executable
      ; Alcotest.test_case
          "of_json_preserves_duplicate_executable_argv0"
          `Quick
          test_of_json_preserves_duplicate_executable_argv0
      ; Alcotest.test_case
          "of_json_rejects_empty_argv_without_executable"
          `Quick
          test_of_json_rejects_empty_argv_without_executable
      ; Alcotest.test_case
          "of_json_rejects_empty_pipeline_with_executable"
          `Quick
          test_of_json_rejects_empty_pipeline_with_executable
      ; Alcotest.test_case
          "of_json_keeps_empty_exec_for_validation"
          `Quick
          test_of_json_keeps_empty_exec_for_validation
      ; Alcotest.test_case "of_json_pipeline" `Quick test_of_json_pipeline
      ; Alcotest.test_case
          "of_json_keeps_empty_pipeline_stage_for_validation"
          `Quick
          test_of_json_keeps_empty_pipeline_stage_for_validation
      ; Alcotest.test_case
          "of_json_pipeline_preserves_duplicate_stage_argv0"
          `Quick
          test_of_json_pipeline_preserves_duplicate_stage_argv0
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
          "of_json_rejects_exec_and_pipeline_together"
          `Quick
          test_of_json_rejects_exec_and_pipeline_together
      ; Alcotest.test_case
          "of_json_rejects_pipeline_with_redirect"
          `Quick
          test_of_json_rejects_pipeline_with_redirect
      ; Alcotest.test_case
          "of_json_rejects_stages_alias"
          `Quick
          test_of_json_rejects_stages_alias
      ; Alcotest.test_case
          "pipeline_lowers_to_shell_ir_pipeline"
          `Quick
          test_pipeline_lowers_to_shell_ir_pipeline
      ; Alcotest.test_case
          "exec_lowering_rejects_duplicate_executable_argv"
          `Quick
          test_exec_lowering_rejects_duplicate_executable_argv
      ; Alcotest.test_case
          "pipeline_lowers_with_injected_docker_sandbox"
          `Quick
          test_pipeline_lowers_with_injected_docker_sandbox
      ; Alcotest.test_case
          "pipe_character_in_exec_argv_is_literal"
          `Quick
          test_pipe_character_in_exec_argv_is_literal
      ; Alcotest.test_case
          "standalone_pipe_operator_in_exec_argv_rejected"
          `Quick
          test_standalone_pipe_operator_in_exec_argv_rejected
      ; Alcotest.test_case
          "gh_multiline_body_lowers_to_literal_argv"
          `Quick
          test_gh_multiline_body_lowers_to_literal_argv
      ; Alcotest.test_case "cwd_not_absolute" `Quick test_cwd_not_absolute
      ; Alcotest.test_case "env_key_invalid" `Quick test_env_key_invalid
      ; Alcotest.test_case
          "rfc_0198_shell_redirection_token_rejected"
          `Quick
          test_shell_redirection_token_rejected
      ; Alcotest.test_case
          "rfc_0198_legitimate_metachar_still_allowed"
          `Quick
          test_legitimate_metachar_still_allowed
      ; Alcotest.test_case
          "rfc_0198_redirection_rejected_emits_typed_alternative"
          `Quick
          test_redirection_rejected_emits_typed_alternative
      ; Alcotest.test_case
          "rfc_0198_validation_error_alternatives_ssot"
          `Quick
          test_validation_error_alternatives
      ; Alcotest.test_case
          "rfc_0198_phaseb_defaults_inherit_emits_no_ir_entries"
          `Quick
          test_redirect_defaults_inherit_emits_no_ir_entries
      ; Alcotest.test_case
          "rfc_0198_phaseb_discard_combinations"
          `Quick
          test_redirect_discard_combinations
      ; Alcotest.test_case
          "rfc_0198_phaseb_file_absolute_path_emits_ir"
          `Quick
          test_redirect_file_absolute_path_emits_ir
      ; Alcotest.test_case
          "rfc_0198_phaseb_file_relative_path_rejected"
          `Quick
          test_redirect_file_relative_path_rejected
      ; Alcotest.test_case
          "rfc_0198_phaseb_stderr_discard_equivalent_to_dev_null"
          `Quick
          test_redirect_stderr_discard_equivalent_to_dev_null_redirect
      ; Alcotest.test_case
          "rfc_0198_phaseb_of_json_parses_discard_stderr"
          `Quick
          test_of_json_parses_discard_stderr_shorthand
      ; Alcotest.test_case
          "rfc_0198_phaseb_of_json_rejects_discard_and_file"
          `Quick
          test_of_json_rejects_redirect_with_both_discard_and_file
      ])
;;

let () = Alcotest.run "Keeper_tool_execute_typed_input typed" [ suite ]
