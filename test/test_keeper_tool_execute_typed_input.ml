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

let mk_argv ?cwd ?timeout_sec argv : Execute_input.execute_input =
  { source = Argv argv; cwd; timeout_sec }
;;

let mk_exec executable argv = mk_argv (executable :: argv)
;;

(* Every argv assertion below wants the same thing: the vector, or a clear
   failure when the input turned out to be a script. Stated once. *)

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
          ])
  in
  match input with
  | { Execute_input.source =
        Argv argv
    ; cwd
    ; _
    } ->
    Alcotest.(check (list string)) "argv" [ "rg"; "pattern"; "lib/" ] argv;
    Alcotest.(check (option string)) "cwd" (Some "/tmp") cwd
  | { Execute_input.source = Script _; _ } ->
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
          ])
  in
  match input with
  | { Execute_input.source = Argv argv; _ } ->
    Alcotest.(check (list string))
      "one argv owns program and arguments"
      [ "git"; "status"; "--short" ]
      argv
  | { Execute_input.source = Script _; _ } ->
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
  | { Execute_input.source = Argv argv; _ } ->
    Alcotest.(check (list string))
      "argv remains caller-authored"
      [ "cat"; "cat"; "repos/masc/README.md" ]
      argv
  | { Execute_input.source = Script _; _ } ->
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

let test_of_json_rejects_argv_and_script () =
  let msg =
    parse_json_error
      (`Assoc
          [ "argv", `List [ `String "echo"; `String "hello" ]
          ; "script", `String "echo hello"
          ])
  in
  Alcotest.(check bool)
    "error names both forms"
    true
    (String_util.contains_substring_ci msg "one form")
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
  | { Execute_input.source = Argv argv; cwd; _ } ->
    Alcotest.(check (list string))
      "argv0 command remains caller-authored"
      [ ""; "gh"; "pr"; "list" ]
      argv;
    Alcotest.(check (option string)) "cwd" (Some "/tmp") cwd
  | { Execute_input.source = Script _; _ } ->
    Alcotest.fail "expected a single-stage program"
;;

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
  | Execute_input.Argv _ -> Alcotest.fail "expected the script form"
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

let test_exec_lowering_preserves_repeated_argument () =
  let input =
    mk_argv [ "git"; "git"; "status" ]
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
    mk_argv [ "echo"; "echo" ]
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

let test_pipe_character_in_exec_argv_is_literal () =
  let input =
    mk_argv [ "echo"; "foo|bar" ]
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
      mk_argv "tail" :: argv
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
    mk_argv [ "gh"; "pr"; "create"; "--body"; body ]
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
    mk_argv ~cwd:"relative/path" [ "ls" ]
  in
  Alcotest.(check bool)
    "Cwd_not_absolute: relative cwd rejected"
    false
    (typed_ok input)
;;

let test_shell_redirection_looking_tokens_are_literal () =
  List.iter
    (fun (token, argv) ->
      let input =
        mk_argv "find" :: argv
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
        mk_argv "find" :: argv
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


let redirect_at ir n =
  match ir with
  | Masc_exec.Shell_ir.Simple simple -> List.nth simple.redirects n
  | _ -> Alcotest.fail "expected Simple IR"
;;

let test_cd_as_a_program_is_refused () =
  let input =
    mk_argv [ "cd"; "/tmp"; "&&"; "git"; "log" ]
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
  let input = mk_argv [ "/usr/bin/cd"; "/tmp" ] in
  match Execute_input.validate input with
  | Ok () -> Alcotest.fail "the path does not change what cd does"
  | Error (Execute_input.Directory_change_is_not_a_program _) -> ()
  | Error err ->
    Alcotest.failf "expected the cd rejection, got %a" Execute_input.pp_validation_error err
;;

(* A program whose name merely contains those letters is untouched. *)
let test_a_program_named_like_cd_still_runs () =
  let input = mk_argv [ "cdparanoia"; "--version" ] in
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

let test_hidden_script_findings_reads_the_argv_costume () =
  (* A shell hidden in argv is what this finds; a line the caller means as a
     line is written as a script and judged there. *)
  match
    findings_of
      (`Assoc
          [ ( "argv"
            , `List [ `String "bash"; `String "-c"; `String "sleep 5 &" ] )
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

let lowered_bin json =
  match Execute_input.to_shell_ir_unvalidated (parse_json_exn json) with
  | Error _ -> Alcotest.fail "lowering must not fail for these inputs"
  | Ok (Masc_exec.Shell_ir.Simple simple) ->
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
          "of_json_rejects_argv_and_script"
          `Quick
          test_of_json_rejects_argv_and_script
      ; Alcotest.test_case
          "of_json_keeps_empty_exec_for_validation"
          `Quick
          test_of_json_keeps_empty_exec_for_validation



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
          "of_json_rejects_stages_alias"
          `Quick
          test_of_json_rejects_stages_alias

      ; Alcotest.test_case
          "exec_lowering_preserves_repeated_argument"
          `Quick
          test_exec_lowering_preserves_repeated_argument
      ; Alcotest.test_case
          "exec_lowering_preserves_argument_equal_to_program"
          `Quick
          test_exec_lowering_preserves_argument_equal_to_program



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
      ; Alcotest.test_case
          "shell_redirection_looking_tokens_are_literal"
          `Quick
          test_shell_redirection_looking_tokens_are_literal
      ; Alcotest.test_case
          "rfc_0198_legitimate_metachar_still_allowed"
          `Quick
          test_legitimate_metachar_still_allowed







      ; Alcotest.test_case
          "hidden_script_findings sees the costume"
          `Quick
          test_hidden_script_findings_sees_the_costume
      ; Alcotest.test_case
          "hidden_script_findings walks every stage"
          `Quick
          test_hidden_script_findings_reads_the_argv_costume
      ; Alcotest.test_case
          "hidden_script_findings ignores what hides nothing"
          `Quick
          test_hidden_script_findings_ignores_what_hides_nothing
      ; Alcotest.test_case
          "hidden_script_findings_judges_the_script_field"
          `Quick
          test_hidden_script_findings_judges_the_script_field


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
