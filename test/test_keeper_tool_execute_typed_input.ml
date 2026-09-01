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

let mk_stage ?(stdin = Execute_input.Inherit_input)
      ?(stdout = Execute_input.Inherit_output)
      ?(stderr = Execute_input.Inherit_output) argv
  : Execute_input.exec_stage
  =
  { argv; stdin; stdout; stderr }
;;

let mk_program ?cwd ?(env = []) ?timeout_sec head tail
  : Execute_input.execute_input
  =
  { source = Staged { program = { head; tail }; next = [] }; cwd; env; timeout_sec }
;;

let mk_exec executable argv = mk_program (mk_stage (executable :: argv)) []
;;

(* Every staged assertion below wants the same thing: the stages, or a clear
   failure when the input turned out to be a script. Stated once. *)
let staged_exn (input : Execute_input.execute_input) =
  match input.Execute_input.source with
  | Execute_input.Staged { program = { head; tail }; _ } -> head :: tail
  | Execute_input.Script _ -> Alcotest.fail "expected the staged form"
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
  ; { name = "repeated_program_argument"
    ; sample_cmd = "cat cat README.md"
    ; typed = mk_exec "cat" [ "cat"; "README.md" ]
    ; expect_typed = true
    ; rationale =
        "typed Execute preserves caller-authored arguments; the first argument \
         may intentionally equal the program token"
    }
  ; { name = "unknown_executable"
    ; sample_cmd = "unknown_cmd foo"
    ; typed = mk_exec "unknown_cmd" [ "foo" ]
    ; expect_typed = true
    ; rationale =
        "structural validation allows any executable string; external-effect \
         authorization belongs to the non-hierarchical Gate"
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
         serialization; typed schema rejects it as an objective boundary error"
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



let test_pipeline_stage_program_check () =
  let input =
    mk_program (mk_stage ([ "rg"; "pattern" ])) [ mk_stage ([ "unknown_cmd" ]) ]
  in
  Alcotest.(check bool)
    "pipeline: structural validation does not reject unknown executables"
    true
    (typed_ok input)
;;

let test_empty_program_is_rejected () =
  match Execute_input.validate  (mk_exec "" [ "ls"; "-la" ]) with
  | Error Execute_input.Empty_program -> ()
  | Error error ->
    Alcotest.failf
      "expected Empty_program, got %a"
      Execute_input.pp_validation_error
      error
  | Ok () -> Alcotest.fail "empty argv[0] should not be accepted"
;;

(* Regression: validate-bypass paths (to_shell_ir_unvalidated /
   shell_simple) must preserve argv so the helpful "argv[0] looks like
   the command name" hint is reachable. Before the fix shell_bin
   fabricated [argv = []], which collapsed the diagnostic into the
   generic catch-all and kept the LLM in a self-correction deadlock.
   The regression was originally observed on a typed input inspected before
   lowering. Product-specific pre-dispatch inspection has since been removed;
   this test keeps the structural argv-preservation contract only. *)
let test_unvalidated_path_rejects_empty_program () =
  let input = mk_exec "" [ "opaque-cli"; "subcommand"; "--state"; "open" ] in
  match Execute_input.to_shell_ir_unvalidated  input with
  | Error Execute_input.Empty_program -> ()
  | Error error ->
    Alcotest.failf
      "expected Empty_program, got %a"
      Execute_input.pp_validation_error
      error
  | Ok _ ->
    Alcotest.fail "empty argv[0] should not produce a Shell IR"
;;

let test_program_whitespace_is_preserved () =
  let input = mk_exec " ls " [ "-la" ] in
  match Execute_input.to_shell_ir input with
  | Ok (Masc_exec.Shell_ir.Simple simple) ->
    Alcotest.(check string)
      "program is opaque caller-authored data"
      " ls "
      (Masc_exec.Exec_program.to_string simple.bin)
  | Ok (Masc_exec.Shell_ir.Pipeline _ | Masc_exec.Shell_ir.Sequence _) -> Alcotest.fail "expected simple process"
  | Error error ->
    Alcotest.failf
      "opaque whitespace program was rejected: %a"
      Execute_input.pp_validation_error
      error
;;

let validation_error_text error = Format.asprintf "%a" Execute_input.pp_validation_error error


let test_of_json_exec () =
  let input =
    parse_json_exn
      (`Assoc
          [ "argv", `List [ `String "rg"; `String "pattern"; `String "lib/" ]
          ; "cwd", `String "/tmp"
          ; "env", `Assoc [ "LC_ALL", `String "C" ]
          ])
  in
  match input with
  | { Execute_input.source =
        Staged { program = { head = { argv; _ }; tail = [] }; _ }
    ; cwd
    ; env
    ; _
    } ->
    Alcotest.(check (list string)) "argv" [ "rg"; "pattern"; "lib/" ] argv;
    Alcotest.(check (option string)) "cwd" (Some "/tmp") cwd;
    Alcotest.(check (list (pair string string))) "env" [ "LC_ALL", "C" ] env
  | { Execute_input.source = Staged { program = { tail = _ :: _; _ }; _ }; _ } ->
    Alcotest.fail "expected a single-stage program"
  | { Execute_input.source = Script _; _ } ->
    Alcotest.fail "expected the staged form"
;;

let test_of_json_timeout_is_optional_and_preserved () =
  let without_timeout =
    parse_json_exn (`Assoc [ "argv", `List [ `String "sleep" ] ])
  in
  let with_timeout =
    parse_json_exn
      (`Assoc
        [ "argv", `List [ `String "sleep" ]; "timeout_sec", `Float 12.5
        ])
  in
  let timeout = function
    | { Execute_input.timeout_sec; _ } ->
      timeout_sec
  in
  Alcotest.(check (option (float 0.0)))
    "a caller who named no budget is recorded as having named none"
    None
    (timeout without_timeout);
  Alcotest.(check (option (float 0.0)))
    "explicit timeout is preserved"
    (Some 12.5)
    (timeout with_timeout)
;;

(* The parsed record above says what the caller wrote. This says what the call
   actually runs under: absence is resolved once, here, so nothing downstream
   is handed [None] and left to decide that it means forever. *)
let test_absent_timeout_resolves_to_the_default () =
  let without_timeout =
    parse_json_exn (`Assoc [ "argv", `List [ `String "sleep" ] ])
  in
  let with_timeout =
    parse_json_exn
      (`Assoc [ "argv", `List [ `String "sleep" ]; "timeout_sec", `Float 12.5 ])
  in
  Alcotest.(check (float 0.0))
    "an unnamed budget becomes the default rather than forever"
    Keeper_tool_execute_input.default_timeout_sec
    (Keeper_tool_execute_input.typed_input_timeout_sec without_timeout);
  Alcotest.(check (float 0.0))
    "a named budget is what runs"
    12.5
    (Keeper_tool_execute_input.typed_input_timeout_sec with_timeout);
  Alcotest.(check bool)
    "the default sits inside the range callers already ask for"
    true
    (Keeper_tool_execute_input.default_timeout_sec > 0.
     && Keeper_tool_execute_input.default_timeout_sec <= 900.);
  (* A run stopped at 600s exits 124, which Process_eio documents as
     indistinguishable from a program that exits 124 by itself. The result can
     only say which limit stopped it if the number arrives with its source. *)
  Alcotest.(check bool)
    "an unnamed budget is marked as one the caller did not choose"
    true
    (match Keeper_tool_execute_input.typed_input_timeout_budget without_timeout with
     | Keeper_tool_execute_input.Default seconds ->
       Float.equal seconds Keeper_tool_execute_input.default_timeout_sec
     | Keeper_tool_execute_input.Named_by_caller _ -> false);
  Alcotest.(check bool)
    "a named budget is marked as the caller's own"
    true
    (match Keeper_tool_execute_input.typed_input_timeout_budget with_timeout with
     | Keeper_tool_execute_input.Named_by_caller seconds -> Float.equal seconds 12.5
     | Keeper_tool_execute_input.Default _ -> false)
;;

let test_of_json_rejects_invalid_explicit_timeout () =
  List.iter
    (fun timeout ->
      let message =
        parse_json_error
          (`Assoc
            [ "argv", `List [ `String "sleep" ]; "timeout_sec", timeout
            ])
      in
      Alcotest.(check bool)
        "invalid timeout is rejected explicitly"
        true
        (String_util.contains_substring_ci
           message
           "finite and greater than zero"))
    [ `Float 0.0; `Float (-1.0) ]
;;

let test_of_json_accepts_single_argv_ssot () =
  let input =
    parse_json_exn
      (`Assoc
          [ "argv", `List [ `String "git"; `String "status"; `String "--short" ]
          ; "cwd", `String "/tmp"
          ; "env", `Assoc [ "LC_ALL", `String "C" ]
          ])
  in
  match input with
  | { Execute_input.source = Staged { program = { head = { argv; _ }; tail = [] }; _ }; _ } ->
    Alcotest.(check (list string))
      "one argv owns program and arguments"
      [ "git"; "status"; "--short" ]
      argv
  | { Execute_input.source = Staged { program = { tail = _ :: _; _ }; _ }; _ } | { Execute_input.source = Script _; _ } ->
    Alcotest.fail "expected a single-stage program"
;;

let test_of_json_rejects_retired_executable_field () =
  let msg =
    parse_json_error
      (`Assoc
        [ "executable", `String "cat"
        ; "argv", `List [ `String "cat"; `String "README.md" ]
        ])
  in
  Alcotest.(check bool)
    "retired duplicate command field is explicit"
    true
    (String_util.contains_substring_ci msg "$.executable is not a supported")
;;

let test_of_json_preserves_repeated_argument () =
  let input =
    parse_json_exn
      (`Assoc
          [ "argv"
          , `List
              [ `String "cat"; `String "cat"; `String "repos/masc/README.md" ]
          ])
  in
  match input with
  | { Execute_input.source = Staged { program = { head = { argv; _ }; tail = [] }; _ }; _ } ->
    Alcotest.(check (list string))
      "argv remains caller-authored"
      [ "cat"; "cat"; "repos/masc/README.md" ]
      argv
  | { Execute_input.source = Staged { program = { tail = _ :: _; _ }; _ }; _ } | { Execute_input.source = Script _; _ } ->
    Alcotest.fail "expected a single-stage program"
;;

let test_of_json_keeps_empty_argv_for_typed_validation () =
  let input = parse_json_exn (`Assoc [ "argv", `List [] ]) in
  match Execute_input.validate input with
  | Error Execute_input.Empty_argv -> ()
  | Error error ->
    Alcotest.failf
      "expected Empty_argv, got %a"
      Execute_input.pp_validation_error
      error
  | Ok () -> Alcotest.fail "empty process vector must be rejected"
;;

let test_of_json_rejects_argv_and_pipeline () =
  let msg =
    parse_json_error
      (`Assoc
          [ "argv", `List [ `String "echo"; `String "hello" ]
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
          [ "argv", `List [ `String ""; `String "gh"; `String "pr"; `String "list" ]
          ; "cwd", `String "/tmp"
          ])
  in
  match input with
  | { Execute_input.source = Staged { program = { head = { argv; _ }; tail = [] }; _ }; cwd; env; _ } ->
    Alcotest.(check (list string))
      "argv0 command remains caller-authored"
      [ ""; "gh"; "pr"; "list" ]
      argv;
    Alcotest.(check (option string)) "cwd" (Some "/tmp") cwd;
    Alcotest.(check (list (pair string string))) "env" [] env
  | { Execute_input.source = Staged { program = { tail = _ :: _; _ }; _ }; _ } | { Execute_input.source = Script _; _ } ->
    Alcotest.fail "expected a single-stage program"
;;

let test_of_json_pipeline () =
  let input =
    parse_json_exn
      (`Assoc
          [ ( "pipeline"
            , `List
                [ `Assoc
                    [ "argv", `List [ `String "printf"; `String "hello" ] ]
                ; `Assoc
                    [ "argv", `List [ `String "wc"; `String "-c" ] ]
                ] )
          ; "cwd", `String "/tmp"
          ])
  in
  let stages = staged_exn input in
  Alcotest.(check int) "stage count" 2 (List.length stages);
  Alcotest.(check (option string)) "cwd" (Some "/tmp") input.Execute_input.cwd;
  Alcotest.(check (list (pair string string))) "env" [] input.Execute_input.env;
  (match stages with
   | [ first; second ] ->
     Alcotest.(check (list string)) "first argv" [ "printf"; "hello" ] first.argv;
     Alcotest.(check (list string)) "second argv" [ "wc"; "-c" ] second.argv
   | _ -> Alcotest.fail "expected exactly two stages")
;;

let test_of_json_pipeline_preserves_duplicate_stage_argv0 () =
  let input =
    parse_json_exn
      (`Assoc
          [ ( "pipeline"
            , `List
                [ `Assoc
                    [ "argv"
                    , `List [ `String "printf"; `String "printf"; `String "hello" ]
                    ]
                ; `Assoc
                    [ "argv", `List [ `String "wc"; `String "wc"; `String "-c" ] ]
                ] )
          ])
  in
  let stages = staged_exn input in
  (match stages with
     | [ first; second ] ->
       Alcotest.(check (list string))
         "first argv remains caller-authored"
         [ "printf"; "printf"; "hello" ]
         first.argv;
       Alcotest.(check (list string))
         "second argv remains caller-authored"
         [ "wc"; "wc"; "-c" ]
         second.argv
     | _ -> Alcotest.fail "expected exactly two stages")
;;

let test_of_json_keeps_empty_pipeline_stage_for_validation () =
  let input =
    parse_json_exn
      (`Assoc
          [ ( "pipeline"
            , `List
                [ `Assoc
                    [ "argv"
                    , `List
                        [ `String ""; `String "rg"; `String "--files"; `String "lib" ]
                    ]
                ; `Assoc
                    [ "argv", `List [ `String "head"; `String "-20" ] ]
                ] )
          ; "cwd", `String "/tmp"
          ])
  in
  let stages = staged_exn input in
  Alcotest.(check (option string)) "cwd" (Some "/tmp") input.Execute_input.cwd;
  Alcotest.(check (list (pair string string))) "env" [] input.Execute_input.env;
  (match stages with
     | [ first; second ] ->
       Alcotest.(check (list string))
         "first argv0 command remains caller-authored"
         [ ""; "rg"; "--files"; "lib" ]
         first.argv;
       Alcotest.(check (list string)) "second argv" [ "head"; "-20" ] second.argv
     | _ -> Alcotest.fail "expected exactly two stages")
;;

(* RFC execute-boundary-is-the-sandbox §4. The shell form is a shell: the text
   goes to [sh -c] whole, rather than being taken apart into an IR whose stages
   this process spawns. The pipe below used to become a two-stage
   [Shell_ir.Pipeline]; it is now one argument to one shell, which is what
   [argv:["bash";"-c";...]] has always produced for the same line. *)
let test_script_goes_to_a_shell_whole () =
  let input = parse_json_exn (`Assoc [ "script", `String "cat a.txt | wc -l" ]) in
  match input.Execute_input.source with
  | Execute_input.Script { shell; text } ->
    Alcotest.(check string) "carried verbatim" "cat a.txt | wc -l" text;
    Alcotest.(check string) "sh unless the caller says otherwise" "sh" shell;
    (match Execute_input.to_shell_ir input with
     | Ok (Masc_exec.Shell_ir.Simple simple) ->
       Alcotest.(check string)
         "the program is the shell"
         "sh"
         (Masc_exec.Exec_program.to_string simple.Masc_exec.Shell_ir.bin);
       Alcotest.(check (list string))
         "the line is one argument"
         [ "-c"; "cat a.txt | wc -l" ]
         (List.map Masc_exec.Exec_dispatch.resolve_arg simple.Masc_exec.Shell_ir.args)
     | Ok _ -> Alcotest.fail "the shell form lowers to one Simple"
     | Error e ->
       Alcotest.failf "%a" Execute_input.pp_validation_error e)
  | Execute_input.Staged _ -> Alcotest.fail "expected the script form"
;;

(* §4.1, one door: the same text through either field produces the same child,
   and the costume keeps the shell its argv named. *)
let test_an_argv_shaped_shell_normalises_to_the_script_form () =
  let line = "ls *.ml && echo $(pwd)" in
  let via_costume =
    parse_json_exn
      (`Assoc [ "argv", `List [ `String "bash"; `String "-c"; `String line ] ])
  in
  let via_script =
    parse_json_exn (`Assoc [ "script", `String line; "shell", `String "bash" ])
  in
  let argv_of input =
    match Execute_input.to_shell_ir input with
    | Ok (Masc_exec.Shell_ir.Simple simple) ->
      Masc_exec.Exec_program.to_string simple.Masc_exec.Shell_ir.bin
      :: List.map Masc_exec.Exec_dispatch.resolve_arg simple.Masc_exec.Shell_ir.args
    | Ok _ -> Alcotest.fail "expected one Simple"
    | Error e -> Alcotest.failf "%a" Execute_input.pp_validation_error e
  in
  Alcotest.(check (list string))
    "the costume and the field produce the same child"
    (argv_of via_script)
    (argv_of via_costume);
  Alcotest.(check (list string))
    "and it is the shell the caller named"
    [ "bash"; "-c"; line ]
    (argv_of via_costume)
;;

(* An unknown shell is a program name, so the closed list is the answer. *)
let test_an_unknown_shell_is_refused () =
  match
    Execute_input.of_json
      (`Assoc [ "script", `String "true"; "shell", `String "python3" ])
  with
  | Ok _ -> Alcotest.fail "python3 is not a shell this tool runs"
  | Error message ->
    Alcotest.(check bool)
      "the message names what is allowed"
      true
      (Astring.String.is_infix ~affix:"sh, bash, zsh, dash, ksh" message)
;;

let test_script_carries_cwd_to_the_shell () =
  let input =
    parse_json_exn
      (`Assoc
        [ "script", `String "cat a.txt | wc -l"; "cwd", `String "/tmp" ])
  in
  match Execute_input.to_shell_ir input with
  | Ok (Masc_exec.Shell_ir.Simple simple) ->
    Alcotest.(check bool)
      "the shell is started in the call's cwd"
      true
      (Option.is_some simple.Masc_exec.Shell_ir.cwd)
  | Ok _ -> Alcotest.fail "the shell form lowers to one Simple"
  | Error e -> Alcotest.failf "%a" Execute_input.pp_validation_error e
;;

(* 83% of the shell escapes measured over 2026-08-21..23 used a logic
   operator. The IR still has [Sequence] and [argv]/[then] still build it; what
   changed is that the shell form no longer takes the operator apart, because
   the shell it runs is what reads it. *)
let test_the_shell_reads_its_own_operators () =
  List.iter
    (fun line ->
       let input = parse_json_exn (`Assoc [ "script", `String line ]) in
       match Execute_input.to_shell_ir input with
       | Ok (Masc_exec.Shell_ir.Simple simple) ->
         Alcotest.(check (list string))
           (Printf.sprintf "%S goes to the shell whole" line)
           [ "-c"; line ]
           (List.map
              Masc_exec.Exec_dispatch.resolve_arg
              simple.Masc_exec.Shell_ir.args)
       | Ok _ ->
         Alcotest.failf "%S must not be taken apart into stages" line
       | Error e -> Alcotest.failf "%a" Execute_input.pp_validation_error e)
    [ "test -w /tmp && echo ok"; "grep x f || echo none"; "a; b" ]
;;

(* RFC execute-boundary-is-the-sandbox. A construct outside the subset used to
   be refused by name; it now runs, and the name reaches the caller as advice
   instead. Both halves matter: the script has to execute, and the judge still
   has to say what is in it. *)
let test_a_construct_outside_the_subset_runs_and_is_still_named () =
  let input = parse_json_exn (`Assoc [ "script", `String "cat $(echo foo)" ]) in
  (match Execute_input.to_shell_ir input with
   | Ok (Masc_exec.Shell_ir.Simple _) -> ()
   | Ok _ -> Alcotest.fail "the shell form lowers to one Simple"
   | Error e ->
     Alcotest.failf
       "command substitution is a shell's job, not a refusal: %a"
       Execute_input.pp_validation_error
       e);
  match
    Execute_input.hidden_script_findings
      ~sandbox:(Masc_exec.Sandbox_target.host ())
      input
  with
  | [ (_, Keeper_tooling.Shell_costume.Outside_the_subset (Masc_exec_command_gate.Shell_command_gate.Unsupported_construct `Cmd_subst)) ] -> ()
  | findings ->
    Alcotest.failf
      "the judge must still name it; got %d finding(s)"
      (List.length findings)
;;

(* The sentence a caller acts on names the construct their script contains.

   sangsu sent this on 2026-08-30 and was told the script "uses a redirection,
   which this tool does not run. use the stdin field". Every redirect in it is
   one the subset takes; the [$?] is what the lexer stopped on. The script runs
   now, so nobody is sent to rewrite four working redirects — but the advice
   that rides back still has to name the expansion rather than the redirect. *)
let test_the_advice_names_the_construct_the_script_contains () =
  let script =
    "echo cmd=build > ev.txt && git rev-parse HEAD >> ev.txt 2>&1; dune build \
     >> ev.txt 2>&1; echo exit=$? >> ev.txt"
  in
  let input = parse_json_exn (`Assoc [ "script", `String script ]) in
  (match Execute_input.to_shell_ir input with
   | Ok _ -> ()
   | Error e ->
     Alcotest.failf
       "this script runs; it is not the tool's business to refuse it: %a"
       Execute_input.pp_validation_error
       e);
  match
    Execute_input.hidden_script_findings
      ~sandbox:(Masc_exec.Sandbox_target.host ())
      input
  with
  | [ (_, Keeper_tooling.Shell_costume.Outside_the_subset (Masc_exec_command_gate.Shell_command_gate.Unsupported_construct `Redirect)) ] ->
    Alcotest.fail
      "the redirects in this script are all ones the subset takes; naming one \
       sends the caller to rewrite working code"
  | [ (_, Keeper_tooling.Shell_costume.Outside_the_subset (Masc_exec_command_gate.Shell_command_gate.Unsupported_construct `Param_expansion)) ] ->
    let msg =
      Keeper_tooling.Subset_rewrite.to_string
        (Keeper_tooling.Subset_rewrite.of_reason
           (Masc_exec_command_gate.Shell_command_gate.Unsupported_construct
              `Param_expansion))
    in
    Alcotest.(check bool)
      (Printf.sprintf "does not send an expansion to the stdin field: %S" msg)
      false
      (String_util.contains_substring_ci msg "stdin")
  | findings ->
    Alcotest.failf
      "expected the expansion to be named; got %d finding(s)"
      (List.length findings)
;;

(* A separated list carries a redirect often enough that naming the redirect
   was the classifier's usual answer. Measured over the 548 command lines the
   runtime produced 2026-08-21..23, all 31 refusals reported as a redirect
   were this. *)
(* [;] was the largest live escape and the one construct [Shell_ir.connector]
   deliberately cannot say. It is not a refusal any more and it is not a
   [Sequence] either: the shell that runs the line is what reads the
   separator. *)
let test_a_separator_goes_to_the_shell () =
  let line = "ls docs 2>/dev/null; echo done" in
  let input = parse_json_exn (`Assoc [ "script", `String line ]) in
  match Execute_input.to_shell_ir input with
  | Ok (Masc_exec.Shell_ir.Simple simple) ->
    Alcotest.(check (list string))
      "the separator stays inside the line"
      [ "-c"; line ]
      (List.map
         Masc_exec.Exec_dispatch.resolve_arg
         simple.Masc_exec.Shell_ir.args)
  | Ok _ -> Alcotest.fail "the shell form lowers to one Simple"
  | Error e ->
    Alcotest.failf
      "a separated list is a shell's business: %a"
      Execute_input.pp_validation_error
      e
;;

let script_description () =
  let rec find = function
    | `Assoc fields ->
      (match List.assoc_opt "script" fields with
       | Some (`Assoc script_fields) ->
         (match List.assoc_opt "description" script_fields with
          | Some (`String description) -> Some description
          | Some _ | None -> None)
       | Some _ | None ->
         List.fold_left
           (fun found (_, value) ->
              match found with Some _ -> found | None -> find value)
           None
           fields)
    | `List items ->
      List.fold_left
        (fun found value ->
           match found with Some _ -> found | None -> find value)
        None
        items
    | _ -> None
  in
  match find Tool_shard_types.tool_execute_schema.input_schema with
  | Some description -> description
  | None -> Alcotest.fail "the execute schema has no script description"
;;

let test_the_script_description_matches_what_the_parser_does () =
  let description = script_description () in
  let mentions sub = String_util.contains_substring description sub in
  Alcotest.(check bool)
    "the description offers ';' as something read as structure"
    true
    (mentions "';'")
;;

let test_script_and_argv_together_are_refused () =
  let msg =
    parse_json_error
      (`Assoc
        [ "script", `String "ls"
        ; "argv", `List [ `String "ls" ]
        ])
  in
  Alcotest.(check bool)
    "one call names one form"
    true
    (String_util.contains_substring_ci msg "one form")
;;

let test_of_json_rejects_cmd_string_only () =
  let msg =
    parse_json_error (`Assoc [ "cmd", `String "rg pattern lib/" ])
  in
  (* [cmd] is still not a field. What changed is why: the shell form exists
     now and is named [script], so the refusal points at it. *)
  Alcotest.(check bool)
    "the refusal names the field that does exist"
    true
    (String_util.contains_substring_ci msg "script")
;;

let test_of_json_rejects_cmd_string_with_argv () =
  let msg =
    parse_json_error
      (`Assoc
        [ "cmd", `String "rg pattern lib/"
        ; "argv", `List [ `String "rg"; `String "pattern"; `String "lib/" ]
        ])
  in
  (* [cmd] is still not a field. What changed is why: the shell form exists
     now and is named [script], so the refusal points at it. *)
  Alcotest.(check bool)
    "the refusal names the field that does exist"
    true
    (String_util.contains_substring_ci msg "script")
;;

let test_of_json_rejects_non_string_argv () =
  let msg =
    parse_json_error
      (`Assoc
          [ "argv", `List [ `String "echo"; `Int 1 ] ])
  in
  Alcotest.(check bool)
    "error mentions argv[1]"
    true
    (String_util.contains_substring_ci msg "$.argv[1]")
;;

let test_of_json_rejects_exec_and_pipeline_together () =
  let msg =
    parse_json_error
      (`Assoc
          [ "argv", `List [ `String "echo"; `String "hello" ]
          ; "pipeline", `List [ `Assoc [ "argv", `List [ `String "wc" ] ] ]
          ])
  in
  Alcotest.(check bool)
    "error mentions mutual exclusion"
    true
    (String_util.contains_substring_ci msg "mutually exclusive")
;;

(* The redirect used to be dropped on the way in, so of_json rejected the
   combination rather than lose it silently. Stages own their redirections
   now, and a top-level one describes the program's own ends the way a shell
   does: stdin feeds the first stage, stdout and stderr come off the last. *)
let test_of_json_stage_redirect_beats_the_top_level_one () =
  let input =
    parse_json_exn
      (`Assoc
          [ ( "pipeline"
            , `List
                [ `Assoc [ "argv", `List [ `String "printf"; `String "x" ] ]
                ; `Assoc
                    [ "argv", `List [ `String "wc" ]
                    ; "stdout", `Assoc [ "truncate", `String "/tmp/stage.log" ]
                    ]
                ] )
          ; "stdout", `Assoc [ "truncate", `String "/tmp/program.log" ]
          ])
  in
  match staged_exn input with
  | _ :: [ last ] ->
    (match last.stdout with
     | Execute_input.Truncate_file { path } ->
       Alcotest.(check string)
         "an explicit stage redirect is not overwritten"
         "/tmp/stage.log"
         path
     | _ -> Alcotest.fail "expected the stage's own file redirect")
  | _ -> Alcotest.fail "expected a two-stage program"
;;

let test_of_json_pipeline_carries_the_top_level_redirect () =
  let input =
    parse_json_exn
      (`Assoc
          [ ( "pipeline"
            , `List
                [ `Assoc [ "argv", `List [ `String "printf"; `String "x" ] ]
                ; `Assoc [ "argv", `List [ `String "wc" ] ]
                ] )
          ; "stdout", `Assoc [ "truncate", `String "/tmp/out.log" ]
          ])
  in
  match staged_exn input with
  | head :: [ last ] ->
    Alcotest.(check bool)
      "first stage keeps the pipe"
      true
      (head.stdout = Execute_input.Inherit_output);
    (match last.stdout with
     | Execute_input.Truncate_file { path } ->
       Alcotest.(check string) "last stage takes the redirect" "/tmp/out.log" path
     | _ -> Alcotest.fail "expected the top-level redirect on the last stage")
  | _ -> Alcotest.fail "expected a two-stage program"
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

let test_repeated_first_argument_preserved () =
  let input = mk_exec "git" [ "git"; "status"; "--short" ] in
  Alcotest.(check bool)
    "validate accepts caller-authored argv"
    true
    (typed_ok input);
  match Execute_input.to_shell_ir input with
  | Ok (Masc_exec.Shell_ir.Simple simple) ->
    Alcotest.(check (pair string (list string)))
      "lowered IR preserves repeated first argument"
      ("git", [ "git"; "status"; "--short" ])
      (shell_simple_tuple simple)
  | Ok (Masc_exec.Shell_ir.Pipeline _ | Masc_exec.Shell_ir.Sequence _) ->
    Alcotest.fail "single Exec must not lower to Pipeline"
  | Error err ->
    Alcotest.failf
      "to_shell_ir should preserve repeated first argument, got %a"
      Execute_input.pp_validation_error
      err
;;

let test_pipeline_lowers_to_shell_ir_pipeline () =
  let input =
    mk_program ?cwd:(Some "/tmp") ~env:([ "LC_ALL", "C" ]) (mk_stage ([ "echo"; "hello world" ])) [ mk_stage ([ "tr"; "a-z"; "A-Z" ]) ]
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

let test_exec_lowering_preserves_repeated_argument () =
  let input =
    mk_program (mk_stage ([ "git"; "git"; "status" ])) []
  in
  match Execute_input.to_shell_ir input with
  | Ok (Masc_exec.Shell_ir.Simple simple) ->
    Alcotest.(check (pair string (list string)))
      "lowered IR preserves caller-authored argv"
      ("git", [ "git"; "status" ])
      (shell_simple_tuple simple)
  | Ok (Masc_exec.Shell_ir.Pipeline _ | Masc_exec.Shell_ir.Sequence _) ->
    Alcotest.fail "single Exec must not lower to Pipeline"
  | Error error ->
    Alcotest.failf
      "duplicated argv[0] should remain caller-authored, got %a"
      Execute_input.pp_validation_error
      error
;;

let test_exec_lowering_preserves_argument_equal_to_program () =
  let input =
    mk_program (mk_stage ([ "echo"; "echo" ])) []
  in
  match Execute_input.to_shell_ir input with
  | Ok (Masc_exec.Shell_ir.Simple simple) ->
    Alcotest.(check (pair string (list string)))
      "single argv equal to executable remains an argument"
      ("echo", [ "echo" ])
      (shell_simple_tuple simple)
  | Ok (Masc_exec.Shell_ir.Pipeline _ | Masc_exec.Shell_ir.Sequence _) ->
    Alcotest.fail "single Exec must not lower to Pipeline"
  | Error error ->
    Alcotest.failf
      "single argv equal to executable should remain valid, got %a"
      Execute_input.pp_validation_error
      error
;;

let test_pipeline_lowering_preserves_argument_equal_to_program () =
  let input =
    mk_program (mk_stage ([ "echo"; "echo" ])) [ mk_stage ([ "wc"; "-c" ]) ]
  in
  match Execute_input.to_shell_ir input with
  | Ok
      (Masc_exec.Shell_ir.Pipeline
        [ Masc_exec.Shell_ir.Simple first; Masc_exec.Shell_ir.Simple second ]) ->
    Alcotest.(check (pair string (list string)))
      "first stage preserves single argv equal to executable"
      ("echo", [ "echo" ])
      (shell_simple_tuple first);
    Alcotest.(check (pair string (list string)))
      "second stage unchanged"
      ("wc", [ "-c" ])
      (shell_simple_tuple second)
  | Ok other ->
    Alcotest.failf "expected Shell_ir.Pipeline, got %a" Masc_exec.Shell_ir.pp other
  | Error error ->
    Alcotest.failf
      "pipeline with single argv equal to executable should remain valid, got %a"
      Execute_input.pp_validation_error
      error
;;

let test_pipeline_lowering_preserves_duplicate_stage_argv () =
  let input =
    mk_program (mk_stage ([ "printf"; "printf"; "hello" ])) [ mk_stage ([ "wc"; "wc"; "-c" ]) ]
  in
  match Execute_input.to_shell_ir input with
  | Ok
      (Masc_exec.Shell_ir.Pipeline
        [ Masc_exec.Shell_ir.Simple first; Masc_exec.Shell_ir.Simple second ]) ->
    Alcotest.(check (pair string (list string)))
      "first stage preserves caller-authored argv"
      ("printf", [ "printf"; "hello" ])
      (shell_simple_tuple first);
    Alcotest.(check (pair string (list string)))
      "second stage preserves caller-authored argv"
      ("wc", [ "wc"; "-c" ])
      (shell_simple_tuple second)
  | Ok other ->
    Alcotest.failf "expected Shell_ir.Pipeline, got %a" Masc_exec.Shell_ir.pp other
  | Error error ->
    Alcotest.failf
      "pipeline duplicated argv[0] should remain caller-authored, got %a"
      Execute_input.pp_validation_error
      error
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
  | Masc_exec.Sandbox_target.Host | Micro_vm _ | Ssh _ | Delegated _ ->
    Alcotest.fail (label ^ ": expected Docker sandbox")
  | Docker { image; _ } -> Alcotest.(check string) (label ^ " image") "typed-docker" image
;;

let test_pipeline_lowers_with_injected_docker_sandbox () =
  let input =
    mk_program ?cwd:(Some "/tmp") (mk_stage ([ "echo"; "hello" ])) [ mk_stage ([ "wc"; "-c" ]) ]
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
    mk_program (mk_stage ([ "echo"; "foo|bar" ])) []
  in
  match to_shell_ir_exn input with
  | Masc_exec.Shell_ir.Simple simple ->
    Alcotest.(check (pair string (list string)))
      "pipe char remains argv data"
      ("echo", [ "foo|bar" ])
      (shell_simple_tuple simple)
  | Masc_exec.Shell_ir.Pipeline _ | Masc_exec.Shell_ir.Sequence _ ->
    Alcotest.fail "literal pipe argv token must not create Shell_ir.Pipeline"
;;

let test_standalone_pipe_operator_in_exec_argv_is_literal () =
  let check_case ~name argv =
    let input =
      mk_program (mk_stage ("tail" :: argv)) []
    in
    match Execute_input.to_shell_ir input with
    | Ok (Masc_exec.Shell_ir.Simple simple) ->
      Alcotest.(check (pair string (list string)))
        name
        ("tail", argv)
        (shell_simple_tuple simple)
    | Ok (Masc_exec.Shell_ir.Pipeline _ | Masc_exec.Shell_ir.Sequence _) ->
      Alcotest.failf "%s: literal argv must not create a pipeline" name
    | Error other ->
      Alcotest.failf
        "%s: literal argv was rejected: %a"
        name
        Execute_input.pp_validation_error
        other
  in
  check_case
    ~name:"tail_pipe_head_log_shape"
    [ "-n"; "200"; "/tmp/keeper.log"; "|"; "head"; "-80" ];
  check_case
    ~name:"stderr_pipe_operator"
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
    mk_program (mk_stage ([ "gh"; "pr"; "create"; "--body"; body ])) []
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
  | Masc_exec.Shell_ir.Pipeline _ | Masc_exec.Shell_ir.Sequence _ ->
    Alcotest.fail "multiline gh body must not create Shell_ir.Pipeline"
;;

let test_cwd_not_absolute () =
  let input =
    mk_program ?cwd:(Some "relative/path") (mk_stage ([ "ls" ])) []
  in
  Alcotest.(check bool)
    "Cwd_not_absolute: relative cwd rejected"
    false
    (typed_ok input)
;;

let test_env_key_invalid () =
  let input =
    mk_program ~env:([ "FOO BAR", "value" ]) (mk_stage ([ "ls" ])) []
  in
  Alcotest.(check bool)
    "Env_key_invalid: env key with space rejected"
    false
    (typed_ok input)
;;

let test_shell_redirection_looking_tokens_are_literal () =
  List.iter
    (fun (token, argv) ->
      let input =
        mk_program (mk_stage ("find" :: argv)) []
      in
      match Execute_input.to_shell_ir input with
      | Ok (Masc_exec.Shell_ir.Simple simple) ->
        Alcotest.(check (pair string (list string)))
          ("literal token " ^ token)
          ("find", argv)
          (shell_simple_tuple simple)
      | Ok (Masc_exec.Shell_ir.Pipeline _ | Masc_exec.Shell_ir.Sequence _) ->
        Alcotest.fail "literal argv must not create a pipeline"
      | Error error ->
        Alcotest.failf
          "literal token %S was rejected: %a"
          token
          Execute_input.pp_validation_error
          error)
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

(* Every non-NUL token is literal execve data, regardless of whether it
   resembles shell syntax. *)
let test_legitimate_metachar_still_allowed () =
  List.iter
    (fun (rationale, argv) ->
      let input =
        mk_program (mk_stage ("find" :: argv)) []
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

(* Typed [stdin]/[stdout]/[stderr] redirect fields. *)

let mk_exec_with_redirects
      ?(executable = "rg")
      ?(argv = [ "pattern" ])
      ?(cwd = Some "/tmp")
      ?(env = [])
      ?(timeout_sec = None)
      ?(stdin = Execute_input.Inherit_input)
      ?(stdout = Execute_input.Inherit_output)
      ?(stderr = Execute_input.Inherit_output)
      ()
  =
  mk_program
    ?cwd
    ~env
    ?timeout_sec
    (mk_stage ~stdin ~stdout ~stderr (executable :: argv))
    []
;;

(* The four shapes the IR carries must all be reachable from a Keeper call,
   and a stage must keep its redirections inside a pipeline. Before the
   program type these were two separate forms and the parser rejected the
   combination outright. *)
let stage_redirects ir n =
  match ir with
  | Masc_exec.Shell_ir.Pipeline stages ->
    (match List.nth_opt stages n with
     | Some (Masc_exec.Shell_ir.Simple simple) -> simple.redirects
     | Some (Masc_exec.Shell_ir.Pipeline _ | Masc_exec.Shell_ir.Sequence _) ->
       Alcotest.fail "a pipeline stage must lower to Simple"
     | None -> Alcotest.failf "pipeline has no stage %d" n)
  | Masc_exec.Shell_ir.Simple _ | Masc_exec.Shell_ir.Sequence _ ->
    Alcotest.fail "expected a pipeline"
;;

let test_pipeline_stage_keeps_its_own_redirect () =
  let input =
    mk_program
      (mk_stage [ "rg"; "pattern" ])
      [ mk_stage
          ~stdout:(Execute_input.Truncate_file { path = "/tmp/out.log" })
          [ "head"; "-20" ]
      ]
  in
  match Execute_input.to_shell_ir input with
  | Ok ir ->
    Alcotest.(check int) "first stage has no redirect" 0 (List.length (stage_redirects ir 0));
    (match stage_redirects ir 1 with
     | [ Masc_exec.Redirect_scope.File { fd; mode = Masc_exec.Redirect_scope.Write; _ } ]
       ->
       Alcotest.(check int) "second stage redirects fd 1" 1 fd
     | other ->
       Alcotest.failf "expected one write redirect on the tail stage, got %d" (List.length other))
  | Error e ->
    Alcotest.failf
      "piping and redirecting in one call must lower: %a"
      Execute_input.pp_validation_error
      e
;;

let test_append_reaches_the_ir () =
  let input =
    mk_program
      (mk_stage
         ~stdout:(Execute_input.Append_file { path = "/tmp/run.log" })
         [ "echo"; "line" ])
      []
  in
  match Execute_input.to_shell_ir input with
  | Ok (Masc_exec.Shell_ir.Simple simple) ->
    (match simple.redirects with
     | [ Masc_exec.Redirect_scope.File { mode = Masc_exec.Redirect_scope.Append; _ } ] ->
       ()
     | _ -> Alcotest.fail "expected a single Append redirect")
  | Ok (Masc_exec.Shell_ir.Pipeline _ | Masc_exec.Shell_ir.Sequence _) ->
    Alcotest.fail "a one-stage program must not lower to Pipeline"
  | Error e ->
    Alcotest.failf "append must lower: %a" Execute_input.pp_validation_error e
;;

let test_fd_duplication_reaches_the_ir () =
  let input = mk_program (mk_stage ~stderr:(Execute_input.Output_to_fd 1) [ "make" ]) [] in
  match Execute_input.to_shell_ir input with
  | Ok (Masc_exec.Shell_ir.Simple simple) ->
    (match simple.redirects with
     | [ Masc_exec.Redirect_scope.Fd_to_fd { src; dst } ] ->
       Alcotest.(check (pair int int)) "2>&1" (2, 1) (src, dst)
     | _ -> Alcotest.fail "expected a single Fd_to_fd redirect")
  | Ok (Masc_exec.Shell_ir.Pipeline _ | Masc_exec.Shell_ir.Sequence _) ->
    Alcotest.fail "a one-stage program must not lower to Pipeline"
  | Error e ->
    Alcotest.failf "fd duplication must lower: %a" Execute_input.pp_validation_error e
;;

let test_fd_outside_the_stage_is_rejected () =
  let input = mk_program (mk_stage ~stderr:(Execute_input.Output_to_fd 7) [ "make" ]) [] in
  Alcotest.(check bool)
    "a stage may only duplicate 0, 1 or 2"
    false
    (typed_ok input)
;;

let test_json_pipeline_with_stage_redirect_parses () =
  let json =
    `Assoc
      [ ( "pipeline"
        , `List
            [ `Assoc [ "argv", `List [ `String "rg"; `String "pattern" ] ]
            ; `Assoc
                [ "argv", `List [ `String "head"; `String "-20" ]
                ; ( "stdout"
                  , `Assoc [ "append", `String "/tmp/out.log" ] )
                ]
            ] )
      ]
  in
  match Execute_input.of_json json with
  | Ok { source = Staged { program = { head = _; tail = [ tail_stage ] }; _ }; _ } ->
    (match tail_stage.stdout with
     | Execute_input.Append_file { path } ->
       Alcotest.(check string) "append target" "/tmp/out.log" path
     | _ -> Alcotest.fail "expected an appending file redirect on the tail stage")
  | Ok _ -> Alcotest.fail "expected a two-stage program"
  | Error msg -> Alcotest.failf "pipeline with a stage redirect must parse: %s" msg
;;

let count_redirects ir =
  match ir with
  | Masc_exec.Shell_ir.Simple simple -> List.length simple.redirects
  | Masc_exec.Shell_ir.Pipeline _ | Masc_exec.Shell_ir.Sequence _ ->
    Alcotest.fail "a one-stage program must not lower to Pipeline"
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
    let inherit_in = Execute_input.Inherit_input in
    let inherit_out = Execute_input.Inherit_output in
    let empty_in = Execute_input.Empty_input in
    let drop_out = Execute_input.Discard_output in
    [ "stderr_discard_only", inherit_in, inherit_out, drop_out, 1
    ; "stdout_discard_only", inherit_in, drop_out, inherit_out, 1
    ; "stdin_discard_only", empty_in, inherit_out, inherit_out, 1
    ; "stdout_stderr_discard", inherit_in, drop_out, drop_out, 2
    ; "all_three_discard", empty_in, drop_out, drop_out, 3
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
      ~stdout:(Execute_input.Truncate_file { path = "/tmp/out.log" })
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
         (Masc_exec.Path_scope.raw (Masc_exec.Redirect_scope.target_as_written target))
     | _ -> Alcotest.fail "expected fd=1 Write to /tmp/out.log")
  | Error err ->
    Alcotest.failf "should validate, got %a" Execute_input.pp_validation_error err
;;

let test_redirect_file_relative_path_rejected () =
  let input =
    mk_exec_with_redirects
      ~stderr:(Execute_input.Truncate_file { path = "relative/path.log" })
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
  let input = mk_exec_with_redirects ~stderr:Execute_input.Discard_output () in
  match Execute_input.to_shell_ir  input with
  | Ok ir ->
    (match redirect_at ir 0 with
     | Masc_exec.Redirect_scope.File { fd = 2; target; mode = Masc_exec.Redirect_scope.Write } ->
       Alcotest.(check string)
         "discard_stderr targets /dev/null"
         "/dev/null"
         (Masc_exec.Path_scope.raw (Masc_exec.Redirect_scope.target_as_written target))
     | _ -> Alcotest.fail "expected fd=2 Write to /dev/null")
  | Error err ->
    Alcotest.failf "should validate, got %a" Execute_input.pp_validation_error err
;;

let test_of_json_parses_discard_stderr_shorthand () =
  let json =
    `Assoc
      [ "argv", `List [ `String "rg"; `String "pattern" ]
      ; "cwd", `String "/tmp"
      ; "stderr", `Assoc [ "discard", `Bool true ]
      ]
  in
  let input = parse_json_exn json in
  match input with
  | { Execute_input.source = Staged { program = { head = { stderr = Execute_input.Discard_output; _ }; _ }; _ }; _ } ->
    ()
  | _ -> Alcotest.fail "of_json must produce stderr=Discard"
;;

let test_of_json_rejects_redirect_with_both_discard_and_file () =
  let json =
    `Assoc
      [ "argv", `List [ `String "rg"; `String "pattern" ]
      ; "cwd", `String "/tmp"
      ; ( "stderr"
        , `Assoc
            [ "discard", `Bool true; "truncate", `String "/tmp/out.log" ] )
      ]
  in
  match Execute_input.of_json json with
  | Ok _ -> Alcotest.fail "of_json must reject conflicting discard+truncate"
  | Error _ -> ()
;;

(* A write mode is not a safe guess: a model that meant ">>" and got ">"
   loses the file's contents with no error anywhere. So a file sink has to
   name which one it is. *)
let test_of_json_rejects_an_output_file_without_a_write_mode () =
  let json =
    `Assoc
      [ "argv", `List [ `String "rg"; `String "pattern" ]
      ; "stdout", `Assoc [ "file", `String "/tmp/out.log" ]
      ]
  in
  match Execute_input.of_json json with
  | Ok _ -> Alcotest.fail "an output file must say truncate or append"
  | Error _ -> ()
;;

(* stdin has no write mode to honour, so naming one is an error rather than a
   field that parses and is then dropped. *)
let test_of_json_rejects_a_write_mode_on_stdin () =
  let json =
    `Assoc
      [ "argv", `List [ `String "rg"; `String "pattern" ]
      ; "stdin", `Assoc [ "append", `String "/tmp/in.log" ]
      ]
  in
  match Execute_input.of_json json with
  | Ok _ -> Alcotest.fail "stdin must reject a write mode"
  | Error _ -> ()
;;

(* The same object with a second key is rejected outright: a redirect that
   parses while one of its keys goes unread is the silent drop this shape
   exists to remove. *)
let test_of_json_rejects_a_redirect_carrying_an_extra_key () =
  let json =
    `Assoc
      [ "argv", `List [ `String "rg"; `String "pattern" ]
      ; "stdin", `Assoc [ "file", `String "/tmp/in.log"; "append", `Bool true ]
      ]
  in
  match Execute_input.of_json json with
  | Ok _ -> Alcotest.fail "a redirect must name exactly one shape"
  | Error _ -> ()
;;

let test_truncate_and_append_reach_different_ir_modes () =
  let mode_of sink =
    let input = mk_exec_with_redirects ~stdout:sink () in
    match Execute_input.to_shell_ir input with
    | Ok ir ->
      (match redirect_at ir 0 with
       | Masc_exec.Redirect_scope.File { mode; _ } -> mode
       | _ -> Alcotest.fail "expected a file redirect")
    | Error err ->
      Alcotest.failf "validation failed: %a" Execute_input.pp_validation_error err
  in
  Alcotest.(check bool)
    "truncate lowers to Write"
    true
    (mode_of (Execute_input.Truncate_file { path = "/tmp/out.log" })
     = Masc_exec.Redirect_scope.Write);
  Alcotest.(check bool)
    "append lowers to Append"
    true
    (mode_of (Execute_input.Append_file { path = "/tmp/out.log" })
     = Masc_exec.Redirect_scope.Append)
;;

(* The dispatcher merges captured output, so descriptor 0 is not something a
   stream can be sent into. Accepting it produced a fabricated exit 1 with the
   process never spawned. *)
let test_fd_zero_is_not_a_duplication_target () =
  let input = mk_program (mk_stage ~stderr:(Execute_input.Output_to_fd 0) [ "make" ]) [] in
  match Execute_input.validate input with
  | Ok () -> Alcotest.fail "descriptor 0 must not be a duplication target"
  | Error (Execute_input.Redirect_fd_unknown { fd; target }) ->
    Alcotest.(check int) "the reported stream" 2 fd;
    Alcotest.(check int) "the reported target" 0 target
  | Error err ->
    Alcotest.failf "expected Redirect_fd_unknown, got %a" Execute_input.pp_validation_error err
;;

(* stdin has no duplication to offer for the same reason, so the key is not
   part of its shape at all. *)
let test_of_json_rejects_fd_on_stdin () =
  let json =
    `Assoc [ "argv", `List [ `String "cat" ]; "stdin", `Assoc [ "fd", `Int 1 ] ]
  in
  match Execute_input.of_json json with
  | Ok _ -> Alcotest.fail "stdin must not accept a duplication target"
  | Error _ -> ()
;;

(* {"discard": false} names no shape. Reading it as "not redirected" made an
   explicit declaration indistinguishable from an absent key, and the
   program-level redirect then overwrote it. *)
let test_of_json_rejects_discard_false () =
  let json =
    `Assoc
      [ "argv", `List [ `String "make" ]; "stderr", `Assoc [ "discard", `Bool false ] ]
  in
  match Execute_input.of_json json with
  | Ok _ -> Alcotest.fail "{discard:false} names nothing and must be rejected"
  | Error _ -> ()
;;

(* Keepers write `a && b` as a literal argv token today, where nothing reads
   it. This is the shape that does run. *)
let test_of_json_parses_a_conditional_continuation () =
  let json =
    `Assoc
      [ "argv", `List [ `String "test"; `String "-w"; `String "/tmp" ]
      ; ( "then"
        , `List
            [ `Assoc
                [ "on", `String "success"
                ; "argv", `List [ `String "echo"; `String "writable" ]
                ]
            ] )
      ]
  in
  match Execute_input.of_json json with
  | Ok { source =
           Staged
             { program = { head = { argv = first; _ }; tail = [] }
             ; next =
                 [ ( Execute_input.And_then
                   , { head = { argv = second; _ }; tail = [] } )
                 ]
             }
       ; _
       } ->
    Alcotest.(check (list string)) "the first program" [ "test"; "-w"; "/tmp" ] first;
    Alcotest.(check (list string)) "the guarded one" [ "echo"; "writable" ] second
  | Ok _ -> Alcotest.fail "expected one program guarded on success"
  | Error msg -> Alcotest.failf "a conditional continuation must parse: %s" msg
;;

let test_of_json_rejects_an_unknown_guard () =
  let json =
    `Assoc
      [ "argv", `List [ `String "true" ]
      ; "then", `List [ `Assoc [ "on", `String "maybe"; "argv", `List [ `String "true" ] ] ]
      ]
  in
  match Execute_input.of_json json with
  | Ok _ -> Alcotest.fail "a guard must be success or failure"
  | Error _ -> ()
;;

let test_of_json_requires_a_guard_on_every_continuation () =
  let json =
    `Assoc
      [ "argv", `List [ `String "true" ]
      ; "then", `List [ `Assoc [ "argv", `List [ `String "true" ] ] ]
      ]
  in
  match Execute_input.of_json json with
  | Ok _ -> Alcotest.fail "a continuation without a guard must be rejected"
  | Error _ -> ()
;;

let test_a_continuation_lowers_to_a_sequence () =
  let json =
    `Assoc
      [ "argv", `List [ `String "true" ]
      ; ( "then"
        , `List
            [ `Assoc [ "on", `String "failure"; "argv", `List [ `String "echo" ] ] ] )
      ]
  in
  match Execute_input.of_json json with
  | Error msg -> Alcotest.failf "must parse: %s" msg
  | Ok input ->
    (match Execute_input.to_shell_ir input with
     | Ok (Masc_exec.Shell_ir.Sequence { tail = [ (Masc_exec.Shell_ir.Or_if, _) ]; _ }) ->
       ()
     | Ok _ -> Alcotest.fail "expected a sequence guarded on failure"
     | Error err ->
       Alcotest.failf "lowering failed: %a" Execute_input.pp_validation_error err)
;;

(* Measured on the live log: 60 calls ran cd as a program and 56 came back
   successful with empty output. The keeper had asked for a git log, a git
   status, a build; it got an empty answer that reads like a real one. *)
let test_cd_as_a_program_is_refused () =
  let input =
    mk_program (mk_stage [ "cd"; "/tmp"; "&&"; "git"; "log" ]) []
  in
  match Execute_input.validate input with
  | Ok () -> Alcotest.fail "cd runs and exits before the real command"
  | Error (Execute_input.Directory_change_is_not_a_program { requested }) ->
    Alcotest.(check bool)
      "the message quotes what was asked for"
      true
      (String.length requested > 0)
  | Error err ->
    Alcotest.failf
      "expected Directory_change_is_not_a_program, got %a"
      Execute_input.pp_validation_error
      err
;;

(* An absolute path to it is the same program. *)
let test_cd_by_absolute_path_is_refused () =
  let input = mk_program (mk_stage [ "/usr/bin/cd"; "/tmp" ]) [] in
  match Execute_input.validate input with
  | Ok () -> Alcotest.fail "the path does not change what cd does"
  | Error (Execute_input.Directory_change_is_not_a_program _) -> ()
  | Error err ->
    Alcotest.failf "expected the cd rejection, got %a" Execute_input.pp_validation_error err
;;

(* A program whose name merely contains those letters is untouched. *)
let test_a_program_named_like_cd_still_runs () =
  let input = mk_program (mk_stage [ "cdparanoia"; "--version" ]) [] in
  match Execute_input.validate input with
  | Ok () -> ()
  | Error err ->
    Alcotest.failf "cdparanoia is a program: %a" Execute_input.pp_validation_error err
;;

(* RFC execute-subset-dispositions step 1.  A script inside argv is counted as
   nothing at all on this path, and these pin that it is now counted. *)
let host = Masc_exec.Sandbox_target.host ()

let findings_of json =
  List.map
    (fun (shell, finding) ->
       shell, Keeper_tooling.Shell_costume.finding_tag finding)
    (Execute_input.hidden_script_findings ~sandbox:host (parse_json_exn json))
;;

let test_hidden_script_findings_sees_the_costume () =
  match
    findings_of
      (`Assoc
          [ "argv", `List [ `String "sh"; `String "-c"; `String "ls {a,b}.txt" ] ])
  with
  | [ ("sh", "glob_brace") ] -> ()
  | other ->
    Alcotest.failf
      "expected one sh/glob_brace finding, got [%s]"
      (String.concat "; " (List.map (fun (s, f) -> s ^ "/" ^ f) other))
;;

let test_hidden_script_findings_walks_every_stage () =
  (* Each stage of a pipeline owns its own argv, so a costume in the tail is as
     invisible as one in the head. *)
  match
    findings_of
      (`Assoc
          [ ( "pipeline"
            , `List
                [ `Assoc [ "argv", `List [ `String "cat"; `String "f" ] ]
                ; `Assoc
                    [ ( "argv"
                      , `List [ `String "bash"; `String "-c"; `String "sleep 5 &" ] )
                    ]
                ] )
          ])
  with
  | [ ("bash", "background") ] -> ()
  | other ->
    Alcotest.failf
      "expected one bash/background finding, got [%s]"
      (String.concat "; " (List.map (fun (s, f) -> s ^ "/" ^ f) other))
;;

let test_hidden_script_findings_ignores_what_hides_nothing () =
  (* An ordinary program is not a costume. *)
  Alcotest.(check int)
    "plain argv"
    0
    (List.length (findings_of (`Assoc [ "argv", `List [ `String "rg"; `String "x" ] ])))
;;

(* RFC execute-boundary-is-the-sandbox §6. A script source used to yield
   nothing here, on the grounds that it had already crossed the gate. It no
   longer crosses one — it goes to a shell — so this is the only place its
   construct gets named, and the advice that rides back is the whole of what
   the judge is for. *)
let test_hidden_script_findings_judges_the_script_field () =
  Alcotest.(check (list (pair string string)))
    "the script field is judged, and the construct is named"
    [ "sh", "glob_brace" ]
    (findings_of (`Assoc [ "script", `String "ls {a,b}.txt" ]))
;;

(* A heredoc is stdin, and until [literal] existed the tool could tell a caller
   so while the stdin field had nowhere to put the bytes. *)
let test_stdin_takes_a_literal () =
  let input =
    parse_json_exn
      (`Assoc
          [ "argv", `List [ `String "cat" ]
          ; "stdin", `Assoc [ "literal", `String "line one\nline two\n" ]
          ])
  in
  match input.Execute_input.source with
  | Execute_input.Staged { program; next = [] } ->
    (match program.Execute_input.head.Execute_input.stdin with
     | Execute_input.Literal_input { bytes } ->
       Alcotest.(check string) "the bytes survive the decode" "line one\nline two\n" bytes
     | _ -> Alcotest.fail "stdin must decode to a literal")
  | _ -> Alcotest.fail "argv must decode to a single staged program"
;;

let test_stdin_literal_excludes_the_other_shapes () =
  (* One key names one source. Two would leave the decoder choosing. *)
  let msg =
    parse_json_error
      (`Assoc
          [ "argv", `List [ `String "cat" ]
          ; "stdin", `Assoc [ "literal", `String "x"; "discard", `Bool true ]
          ])
  in
  Alcotest.(check bool)
    ("the refusal names literal as an option -- got: " ^ msg)
    true
    (Astring.String.is_infix ~affix:"literal" msg)
;;

(* RFC execute-subset-dispositions §3.7 step 4. A costume whose script the IR
   can hold is lowered through the gate; everything else keeps today's path,
   because a blanket flip would refuse calls that run. *)
let lowered_bin json =
  match Execute_input.to_shell_ir_unvalidated (parse_json_exn json) with
  | Error _ -> Alcotest.fail "lowering must not fail for these inputs"
  | Ok (Masc_exec.Shell_ir.Simple simple) ->
    Masc_exec.Exec_program.to_string simple.Masc_exec.Shell_ir.bin
  | Ok (Masc_exec.Shell_ir.Sequence { head = Masc_exec.Shell_ir.Simple simple; _ }) ->
    Masc_exec.Exec_program.to_string simple.Masc_exec.Shell_ir.bin
  | Ok _ -> "<not a simple>"
;;

let costume script =
  `Assoc [ "argv", `List [ `String "sh"; `String "-c"; `String script ] ]
;;

(* RFC execute-boundary-is-the-sandbox §4.1. The costume used to be taken
   apart when the subset could represent it, so [sh -c "echo hi"] became
   [echo hi] and [sh -c "false; echo hi"] became a [Sequence]. Both are one
   shell now, whichever the argv named: the caller asked for a shell, and
   which text it happens to contain is not what decides. *)
let test_a_costume_keeps_its_shell () =
  Alcotest.(check string) "echo hi" "sh" (lowered_bin (costume "echo hi"));
  Alcotest.(check string)
    "false; echo hi"
    "sh"
    (lowered_bin (costume "false; echo hi"));
  Alcotest.(check string)
    "cat $(echo foo)"
    "sh"
    (lowered_bin (costume "cat $(echo foo)"))
;;

let test_what_the_ir_cannot_hold_keeps_todays_path () =
  (* Constructs like cmd_subst and heredoc cannot be held in IR, so they stay on the shell. *)
  Alcotest.(check string) "cmd_subst" "sh" (lowered_bin (costume "cat $(echo foo)"));
  Alcotest.(check string) "heredoc" "sh" (lowered_bin (costume "cat <<'EOF'\nx\nEOF"))
;;

let test_a_script_that_names_a_variable_keeps_todays_path () =
  (* [resolve_arg] answers a variable from this process's environment, and a
     shell answers it from the child's, which Env_keeper_scrub has filtered.
     Lowering would change the value, toward the unfiltered one. *)
  Alcotest.(check string) "echo $HOME" "sh" (lowered_bin (costume "echo $HOME"));
  Alcotest.(check string) "braced" "sh" (lowered_bin (costume "echo ${HOME}"))
;;

let test_a_stage_with_its_own_streams_keeps_todays_path () =
  (* Merging the stage's redirects with the script's is a different question. *)
  Alcotest.(check string)
    "stdin declared"
    "sh"
    (lowered_bin
       (`Assoc
           [ "argv", `List [ `String "sh"; `String "-c"; `String "echo hi" ]
           ; "stdin", `Assoc [ "discard", `Bool true ]
           ]))
;;

let test_an_ordinary_program_is_untouched () =
  Alcotest.(check string)
    "rg"
    "rg"
    (lowered_bin (`Assoc [ "argv", `List [ `String "rg"; `String "pattern" ] ]))
;;

(* The tap hands back the typed finding, because a caller that wants to tell
   the writer what to do needs the reason and not its name. *)
let test_a_finding_carries_its_rewrite () =
  let module Costume = Keeper_tooling.Shell_costume in
  let module Rewrite = Keeper_tooling.Subset_rewrite in
  match
    Execute_input.hidden_script_findings
      ~sandbox:host
      (parse_json_exn
         (`Assoc
             [ "argv", `List [ `String "sh"; `String "-c"; `String "cat $(echo foo)" ] ]))
  with
  | [ (_, Costume.Outside_the_subset reason) ] ->
    let advice = Rewrite.to_string (Rewrite.of_reason reason) in
    Alcotest.(check bool)
      ("the advice is produced -- got: " ^ advice)
      true
      (String.length advice > 0)
  | other ->
    Alcotest.failf
      "expected one outside-the-subset finding, got %d"
      (List.length other)
;;

let test_a_representable_costume_has_nothing_to_say () =
  let module Costume = Keeper_tooling.Shell_costume in
  match
    Execute_input.hidden_script_findings
      ~sandbox:host
      (parse_json_exn
         (`Assoc [ "argv", `List [ `String "sh"; `String "-c"; `String "echo hi" ] ]))
  with
  | [ (_, Costume.Representable) ] -> ()
  | _ -> Alcotest.fail "a representable costume has no rewrite to offer"
;;

let suite =
  ("typed tool_execute argv schema",
    List.map
      (fun c -> Alcotest.test_case c.name `Quick (test_case c))
    cases
    @ [ Alcotest.test_case
          "cd_as_a_program_is_refused"
          `Quick
          test_cd_as_a_program_is_refused
      ; Alcotest.test_case
          "cd_by_absolute_path_is_refused"
          `Quick
          test_cd_by_absolute_path_is_refused
      ; Alcotest.test_case
          "a_program_named_like_cd_still_runs"
          `Quick
          test_a_program_named_like_cd_still_runs
      ; Alcotest.test_case
          "conditional_continuation_parses"
          `Quick
          test_of_json_parses_a_conditional_continuation
      ; Alcotest.test_case
          "unknown_guard_is_rejected"
          `Quick
          test_of_json_rejects_an_unknown_guard
      ; Alcotest.test_case
          "continuation_requires_a_guard"
          `Quick
          test_of_json_requires_a_guard_on_every_continuation
      ; Alcotest.test_case
          "continuation_lowers_to_a_sequence"
          `Quick
          test_a_continuation_lowers_to_a_sequence
      ; Alcotest.test_case
          "fd_zero_is_not_a_duplication_target"
          `Quick
          test_fd_zero_is_not_a_duplication_target
      ; Alcotest.test_case
          "fd_on_stdin_is_rejected"
          `Quick
          test_of_json_rejects_fd_on_stdin
      ; Alcotest.test_case
          "discard_false_is_rejected"
          `Quick
          test_of_json_rejects_discard_false
      ; Alcotest.test_case
          "output_file_without_a_write_mode_is_rejected"
          `Quick
          test_of_json_rejects_an_output_file_without_a_write_mode
      ; Alcotest.test_case
          "write_mode_on_stdin_is_rejected"
          `Quick
          test_of_json_rejects_a_write_mode_on_stdin
      ; Alcotest.test_case
          "redirect_with_an_extra_key_is_rejected"
          `Quick
          test_of_json_rejects_a_redirect_carrying_an_extra_key
      ; Alcotest.test_case
          "truncate_and_append_reach_different_ir_modes"
          `Quick
          test_truncate_and_append_reach_different_ir_modes
      ; Alcotest.test_case
          "pipeline_stage_keeps_its_own_redirect"
          `Quick
          test_pipeline_stage_keeps_its_own_redirect
      ; Alcotest.test_case "append_reaches_the_ir" `Quick test_append_reaches_the_ir
      ; Alcotest.test_case
          "fd_duplication_reaches_the_ir"
          `Quick
          test_fd_duplication_reaches_the_ir
      ; Alcotest.test_case
          "fd_outside_the_stage_is_rejected"
          `Quick
          test_fd_outside_the_stage_is_rejected
      ; Alcotest.test_case
          "json_pipeline_with_stage_redirect_parses"
          `Quick
          test_json_pipeline_with_stage_redirect_parses
      ; Alcotest.test_case
          "pipeline_stage_program_check"
          `Quick
          test_pipeline_stage_program_check
      ; Alcotest.test_case
          "empty_program_is_rejected"
          `Quick
          test_empty_program_is_rejected
      ; Alcotest.test_case
          "repeated_first_argument_preserved"
          `Quick
          test_repeated_first_argument_preserved
      ; Alcotest.test_case
          "unvalidated_path_rejects_empty_program"
          `Quick
          test_unvalidated_path_rejects_empty_program
      ; Alcotest.test_case
          "program_whitespace_is_preserved"
          `Quick
          test_program_whitespace_is_preserved
      ; Alcotest.test_case "of_json_exec" `Quick test_of_json_exec
      ; Alcotest.test_case
          "of_json_timeout_is_optional_and_preserved"
          `Quick
          test_of_json_timeout_is_optional_and_preserved
      ; Alcotest.test_case
          "the_script_description_matches_what_the_parser_does"
          `Quick
          test_the_script_description_matches_what_the_parser_does
      ; Alcotest.test_case
          "absent_timeout_resolves_to_the_default"
          `Quick
          test_absent_timeout_resolves_to_the_default
      ; Alcotest.test_case
          "of_json_rejects_invalid_explicit_timeout"
          `Quick
          test_of_json_rejects_invalid_explicit_timeout
      ; Alcotest.test_case
          "of_json_accepts_single_argv_ssot"
          `Quick
          test_of_json_accepts_single_argv_ssot
      ; Alcotest.test_case
          "of_json_rejects_retired_executable_field"
          `Quick
          test_of_json_rejects_retired_executable_field
      ; Alcotest.test_case
          "of_json_preserves_repeated_argument"
          `Quick
          test_of_json_preserves_repeated_argument
      ; Alcotest.test_case
          "of_json_keeps_empty_argv_for_typed_validation"
          `Quick
          test_of_json_keeps_empty_argv_for_typed_validation
      ; Alcotest.test_case
          "of_json_rejects_argv_and_pipeline"
          `Quick
          test_of_json_rejects_argv_and_pipeline
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
          "script_goes_to_a_shell_whole"
          `Quick
          test_script_goes_to_a_shell_whole
      ; Alcotest.test_case
          "an_argv_shaped_shell_normalises_to_the_script_form"
          `Quick
          test_an_argv_shaped_shell_normalises_to_the_script_form
      ; Alcotest.test_case
          "an_unknown_shell_is_refused"
          `Quick
          test_an_unknown_shell_is_refused
      ; Alcotest.test_case
          "script_carries_cwd_to_the_shell"
          `Quick
          test_script_carries_cwd_to_the_shell
      ; Alcotest.test_case
          "the_shell_reads_its_own_operators"
          `Quick
          test_the_shell_reads_its_own_operators
      ; Alcotest.test_case
          "a_construct_outside_the_subset_runs_and_is_still_named"
          `Quick
          test_a_construct_outside_the_subset_runs_and_is_still_named
      ; Alcotest.test_case
          "the_advice_names_the_construct_the_script_contains"
          `Quick
          test_the_advice_names_the_construct_the_script_contains
      ; Alcotest.test_case
          "a_separator_goes_to_the_shell"
          `Quick
          test_a_separator_goes_to_the_shell
      ; Alcotest.test_case
          "script_and_argv_together_are_refused"
          `Quick
          test_script_and_argv_together_are_refused      ; Alcotest.test_case
          "of_json_rejects_cmd_string_only"
          `Quick
          test_of_json_rejects_cmd_string_only
      ; Alcotest.test_case
          "of_json_rejects_cmd_string_with_argv"
          `Quick
          test_of_json_rejects_cmd_string_with_argv
      ; Alcotest.test_case
          "of_json_rejects_non_string_argv"
          `Quick
          test_of_json_rejects_non_string_argv
      ; Alcotest.test_case
          "of_json_rejects_exec_and_pipeline_together"
          `Quick
          test_of_json_rejects_exec_and_pipeline_together
      ; Alcotest.test_case
          "of_json_pipeline_carries_the_top_level_redirect"
          `Quick
          test_of_json_pipeline_carries_the_top_level_redirect
      ; Alcotest.test_case
          "of_json_stage_redirect_beats_the_top_level_one"
          `Quick
          test_of_json_stage_redirect_beats_the_top_level_one
      ; Alcotest.test_case
          "of_json_rejects_stages_alias"
          `Quick
          test_of_json_rejects_stages_alias
      ; Alcotest.test_case
          "pipeline_lowers_to_shell_ir_pipeline"
          `Quick
          test_pipeline_lowers_to_shell_ir_pipeline
      ; Alcotest.test_case
          "exec_lowering_preserves_repeated_argument"
          `Quick
          test_exec_lowering_preserves_repeated_argument
      ; Alcotest.test_case
          "exec_lowering_preserves_argument_equal_to_program"
          `Quick
          test_exec_lowering_preserves_argument_equal_to_program
      ; Alcotest.test_case
          "pipeline_lowering_preserves_argument_equal_to_program"
          `Quick
          test_pipeline_lowering_preserves_argument_equal_to_program
      ; Alcotest.test_case
          "pipeline_lowering_preserves_duplicate_stage_argv"
          `Quick
          test_pipeline_lowering_preserves_duplicate_stage_argv
      ; Alcotest.test_case
          "pipeline_lowers_with_injected_docker_sandbox"
          `Quick
          test_pipeline_lowers_with_injected_docker_sandbox
      ; Alcotest.test_case
          "pipe_character_in_exec_argv_is_literal"
          `Quick
          test_pipe_character_in_exec_argv_is_literal
      ; Alcotest.test_case
          "standalone_pipe_operator_in_exec_argv_is_literal"
          `Quick
          test_standalone_pipe_operator_in_exec_argv_is_literal
      ; Alcotest.test_case
          "gh_multiline_body_lowers_to_literal_argv"
          `Quick
          test_gh_multiline_body_lowers_to_literal_argv
      ; Alcotest.test_case "cwd_not_absolute" `Quick test_cwd_not_absolute
      ; Alcotest.test_case "env_key_invalid" `Quick test_env_key_invalid
      ; Alcotest.test_case
          "shell_redirection_looking_tokens_are_literal"
          `Quick
          test_shell_redirection_looking_tokens_are_literal
      ; Alcotest.test_case
          "rfc_0198_legitimate_metachar_still_allowed"
          `Quick
          test_legitimate_metachar_still_allowed
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
      ; Alcotest.test_case
          "hidden_script_findings sees the costume"
          `Quick
          test_hidden_script_findings_sees_the_costume
      ; Alcotest.test_case
          "hidden_script_findings walks every stage"
          `Quick
          test_hidden_script_findings_walks_every_stage
      ; Alcotest.test_case
          "hidden_script_findings ignores what hides nothing"
          `Quick
          test_hidden_script_findings_ignores_what_hides_nothing
      ; Alcotest.test_case
          "hidden_script_findings_judges_the_script_field"
          `Quick
          test_hidden_script_findings_judges_the_script_field
      ; Alcotest.test_case "stdin takes a literal" `Quick test_stdin_takes_a_literal
      ; Alcotest.test_case
          "stdin literal excludes the other shapes"
          `Quick
          test_stdin_literal_excludes_the_other_shapes
      ; Alcotest.test_case
          "a representable costume is lowered"
          `Quick
          test_a_costume_keeps_its_shell
      ; Alcotest.test_case
          "what the IR cannot hold keeps today's path"
          `Quick
          test_what_the_ir_cannot_hold_keeps_todays_path
      ; Alcotest.test_case
          "a script that names a variable keeps today's path"
          `Quick
          test_a_script_that_names_a_variable_keeps_todays_path
      ; Alcotest.test_case
          "a stage with its own streams keeps today's path"
          `Quick
          test_a_stage_with_its_own_streams_keeps_todays_path
      ; Alcotest.test_case
          "an ordinary program is untouched"
          `Quick
          test_an_ordinary_program_is_untouched
      ; Alcotest.test_case
          "a finding carries its rewrite"
          `Quick
          test_a_finding_carries_its_rewrite
      ; Alcotest.test_case
          "a representable costume has nothing to say"
          `Quick
          test_a_representable_costume_has_nothing_to_say
      ])
;;

let () = Alcotest.run "Keeper_tool_execute_typed_input typed" [ suite ]
