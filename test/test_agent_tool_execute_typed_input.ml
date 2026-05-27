(** Typed tool_execute argv schema tests.

    Exercises [Agent_tool_execute_typed_input.validate] on representative
    structured inputs and asserts only the typed-schema verdict. *)

open Masc_mcp
module Execute_input = Agent_tool_execute_typed_input

let typed_ok input =
  match Execute_input.validate ~mode:Execute_input.Dev_full input with
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
    ; sample_cmd = "grep -rn try_acquire repos/masc-mcp/lib --include=*.ml"
    ; typed =
        mk_exec
          "grep"
          [ "-rn"; "try_acquire"; "repos/masc-mcp/lib"; "--include=*.ml" ]
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
    "pipeline: non-allowlisted stage executable is rejected"
    false
    (typed_ok input)
;;

let expect_not_allowlisted ~target input =
  match Execute_input.validate ~mode:Execute_input.Dev_full input with
  | Error (Execute_input.Executable_not_allowlisted { name; _ }) ->
    Alcotest.(check string) "blocked target" target name
  | Error error ->
    Alcotest.failf
      "expected Executable_not_allowlisted %S, got %a"
      target
      Execute_input.pp_validation_error
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
    ; Execute_input.Pipeline
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
      match Execute_input.validate ~mode:Execute_input.Dev_full input with
      | Ok () -> ()
      | Error error ->
        Alcotest.failf
          "expected wrapper target to be allowed, got %a"
          Execute_input.pp_validation_error
          error)
    [ mk_exec "env" [ "git"; "status" ]
    ; mk_exec "opam" [ "exec"; "--"; "git"; "status" ]
    ; mk_exec "env" [ "opam"; "exec"; "--"; "git"; "status" ]
    ; mk_exec "opam" [ "exec"; "--"; "env"; "FOO=bar"; "git"; "status" ]
    ]
;;

let test_wrapper_exec_target_rejects_whitespace_padded_executable () =
  (* Regression: trimming applied to allowlist membership must also apply
     when dispatching wrapper-target validation. Otherwise a padded
     [executable=" env "] passes the allowlist (trimmed to "env") but
     [check_wrapper_exec_target] sees the raw " env " and falls through
     to [_ -> Ok ()], skipping the env-argv guard. *)
  List.iter
    (fun input -> expect_not_allowlisted ~target:"rm" input)
    [ mk_exec " env " [ "rm"; "-rf"; "/" ]
    ; mk_exec "env\t" [ "rm"; "-rf"; "/" ]
    ; mk_exec " opam " [ "exec"; "--"; "rm"; "-rf"; "/" ]
    ]
;;

let test_standalone_env_rejected () =
  match Execute_input.validate ~mode:Execute_input.Dev_full (mk_exec "env" []) with
  | Error (Execute_input.Empty_argv { executable = "env" }) -> ()
  | Error error ->
    Alcotest.failf
      "expected standalone env to be rejected as empty wrapper, got %a"
      Execute_input.pp_validation_error
      error
  | Ok () -> Alcotest.fail "standalone env should not be accepted"
;;

let test_empty_executable_with_argv_hints_rewrite () =
  match Execute_input.validate ~mode:Execute_input.Dev_full (mk_exec "" [ "ls"; "-la" ]) with
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
  match Execute_input.to_shell_ir_unvalidated ~mode:Execute_input.Dev_full input with
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

let check_not_allowlisted_hint ~name ~mode ~needle () =
  let msg =
    validation_error_text (Execute_input.Executable_not_allowlisted { name; mode })
  in
  Alcotest.(check bool)
    (Printf.sprintf "%s hint" name)
    true
    (String_util.contains_substring_ci msg needle)
;;

let test_not_allowlisted_hints_self_correction () =
  check_not_allowlisted_hint
    ~name:"keeper_tasks_list"
    ~mode:Execute_input.Dev_full
    ~needle:"not shell programs"
    ();
  check_not_allowlisted_hint
    ~name:"gh"
    ~mode:Execute_input.Readonly
    ~needle:"write/execute-capable"
    ();
  check_not_allowlisted_hint
    ~name:"sh"
    ~mode:Execute_input.Dev_full
    ~needle:"Shell interpreters"
    ();
  check_not_allowlisted_hint
    ~name:"chmod"
    ~mode:Execute_input.Dev_full
    ~needle:"privileged/destructive"
    ();
  check_not_allowlisted_hint
    ~name:"jq"
    ~mode:Execute_input.Dev_full
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
  | Execute_input.Exec { executable; argv; cwd; env; _ } ->
    Alcotest.(check string) "executable" "rg" executable;
    Alcotest.(check (list string)) "argv" [ "pattern"; "lib/" ] argv;
    Alcotest.(check (option string)) "cwd" (Some "/tmp") cwd;
    Alcotest.(check (list (pair string string))) "env" [ "LC_ALL", "C" ] env
  | Execute_input.Pipeline _ -> Alcotest.fail "expected Exec"
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
  match Execute_input.to_shell_ir ~mode:Execute_input.Dev_full input with
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

let test_exec_lowering_preserves_duplicate_executable_argv () =
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
  match to_shell_ir_exn input with
  | Masc_exec.Shell_ir.Simple simple ->
    Alcotest.(check (pair string (list string)))
      "duplicate executable token is caller data"
      ("git", [ "git"; "status" ])
      (shell_simple_tuple simple)
  | Masc_exec.Shell_ir.Pipeline _ ->
    Alcotest.fail "single exec input must not create Shell_ir.Pipeline"
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
      ~mode:Execute_input.Dev_full
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
  match Execute_input.validate ~mode:Execute_input.Dev_full input with
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
      match Execute_input.validate ~mode:Execute_input.Dev_full input with
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
     (Phase B redirect fields or Pipeline mode), not toward the
     deprecated "split into Pipeline stages" prose used for
     control-character rejection. *)
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
  match Execute_input.validate ~mode:Execute_input.Dev_full input with
  | Error (Execute_input.Argv_contains_shell_redirection _ as err) ->
    let msg = Format.asprintf "%a" Execute_input.pp_validation_error err in
    Alcotest.(check bool)
      "error mentions discard_stderr typed field"
      true
      (contains_substring msg "discard_stderr");
    Alcotest.(check bool)
      "error mentions Phase B RFC marker"
      true
      (contains_substring msg "RFC-0198")
  | _ -> Alcotest.fail "expected Argv_contains_shell_redirection"
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
      ~mode:Execute_input.Dev_full
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
      match Execute_input.to_shell_ir ~mode:Execute_input.Dev_full input with
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
  match Execute_input.to_shell_ir ~mode:Execute_input.Dev_full input with
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
  match Execute_input.validate ~mode:Execute_input.Dev_full input with
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
  match Execute_input.to_shell_ir ~mode:Execute_input.Dev_full input with
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

(* Issue #18892: Task-state file probe rejection.

   The prompt forbids reading task-state JSON files via shell (see
   config/prompts/keeper.world.md). Before this fix the runtime did not
   enforce the promise — keepers ran [cat .masc/backlog.json] and saw
   only a generic ENOENT. These tests pin the typed rejection so the
   contract is observable from outside the gate. *)

let expect_task_state_probe ~token ~variant input =
  match Execute_input.validate ~mode:Execute_input.Dev_full input with
  | Error
      (Execute_input.Argv_probes_task_state_file
        { token = t; matched; _ }) ->
    Alcotest.(check string) "rejected token text" token t;
    Alcotest.(check bool)
      (Printf.sprintf "matched %s variant" token)
      true
      (matched = variant)
  | Error other ->
    Alcotest.failf
      "expected Argv_probes_task_state_file for %S, got %a"
      token
      Execute_input.pp_validation_error
      other
  | Ok () -> Alcotest.failf "expected %S to be rejected" token
;;

let test_task_state_probe_paths_rejected () =
  let cases =
    [ ".masc/backlog.json", Execute_input.Backlog_json
    ; ".masc/state/backlog.json", Execute_input.State_backlog_json
    ; ".masc/goal-loop/status.json", Execute_input.Goal_loop_status_json
    ; ( "repos/masc-mcp/.masc/backlog.json"
      , Execute_input.Repo_local_backlog_json )
    ; ( "repos/masc-mcp/.masc/state/backlog.json"
      , Execute_input.Repo_local_backlog_json )
    ; ( "repos/oas/.worktrees/feature-x/.task.json"
      , Execute_input.Repo_worktree_task_json )
    ; ".task.json", Execute_input.Top_level_task_json
    ; "task.json", Execute_input.Top_level_task_json
    ; "./.masc/backlog.json", Execute_input.Backlog_json
    ]
  in
  List.iter
    (fun (token, variant) ->
      let input = mk_exec "cat" [ token ] in
      expect_task_state_probe ~token ~variant input)
    cases
;;

let test_task_state_probe_rejection_redirects_to_keeper_tasks_list () =
  let input = mk_exec "cat" [ ".masc/backlog.json" ] in
  match Execute_input.validate ~mode:Execute_input.Dev_full input with
  | Error (Execute_input.Argv_probes_task_state_file _ as err) ->
    let msg = Format.asprintf "%a" Execute_input.pp_validation_error err in
    Alcotest.(check bool)
      "error mentions keeper_tasks_list redirect"
      true
      (contains_substring msg "keeper_tasks_list");
    Alcotest.(check bool)
      "error mentions task_state_file_probe_blocked rule_id"
      true
      (contains_substring msg "task_state_file_probe_blocked")
  | _ -> Alcotest.fail "expected Argv_probes_task_state_file"
;;

let test_task_state_probe_does_not_match_random_json () =
  (* Tokens that contain "backlog" or "json" elsewhere must NOT trigger
     the gate — false positives would block legitimate work. *)
  let benign =
    [ "config/backlog.example.json"
    ; "build/output.json"
    ; "lib/keeper/keeper_task_state.ml"
    ; ".masc/personas/verifier/profile.json"
    ; "repos/masc-mcp/lib/dune"
    ]
  in
  List.iter
    (fun token ->
      let input = mk_exec "cat" [ token ] in
      match Execute_input.validate ~mode:Execute_input.Dev_full input with
      | Ok () -> ()
      | Error other ->
        Alcotest.failf
          "benign token %S unexpectedly rejected: %a"
          token
          Execute_input.pp_validation_error
          other)
    benign
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
          "wrapper_exec_target_rejects_whitespace_padded_executable"
          `Quick
          test_wrapper_exec_target_rejects_whitespace_padded_executable
      ; Alcotest.test_case
          "standalone_env_rejected"
          `Quick
          test_standalone_env_rejected
      ; Alcotest.test_case
          "empty_executable_with_argv_hints_rewrite"
          `Quick
          test_empty_executable_with_argv_hints_rewrite
      ; Alcotest.test_case
          "unvalidated_path_preserves_argv_in_error"
          `Quick
          test_unvalidated_path_preserves_argv_in_error
      ; Alcotest.test_case
          "not_allowlisted_hints_self_correction"
          `Quick
          test_not_allowlisted_hints_self_correction
      ; Alcotest.test_case "of_json_exec" `Quick test_of_json_exec
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
          "of_json_rejects_stages_alias"
          `Quick
          test_of_json_rejects_stages_alias
      ; Alcotest.test_case
          "pipeline_lowers_to_shell_ir_pipeline"
          `Quick
          test_pipeline_lowers_to_shell_ir_pipeline
      ; Alcotest.test_case
          "exec_lowering_preserves_duplicate_executable_argv"
          `Quick
          test_exec_lowering_preserves_duplicate_executable_argv
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
          "issue_18892_task_state_probe_paths_rejected"
          `Quick
          test_task_state_probe_paths_rejected
      ; Alcotest.test_case
          "issue_18892_task_state_probe_redirects_to_keeper_tasks_list"
          `Quick
          test_task_state_probe_rejection_redirects_to_keeper_tasks_list
      ; Alcotest.test_case
          "issue_18892_task_state_probe_no_false_positives"
          `Quick
          test_task_state_probe_does_not_match_random_json
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

let () = Alcotest.run "Agent_tool_execute_typed_input typed" [ suite ]
