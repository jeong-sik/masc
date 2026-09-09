(* Command-substitution execution tests (RFC
   shell-ir-typed-command-substitution §2.3): the child's stdout becomes
   exactly one argv element of the parent — no re-split, no glob — trailing
   newlines stripped, child stderr joining the parent's, child exit status
   deciding nothing.

   Plain asserts, like the neighboring dispatch tests. *)

open Masc_exec

let fail msg = raise (Failure msg)

let lit s = Shell_ir.Lit (s, Shell_ir.default_meta)

let bin s =
  match Exec_program.of_string s with
  | Ok bin -> bin
  | Error (`Unknown name) -> fail ("unknown exec program: " ^ name)

let simple executable args =
  { Shell_ir.bin = bin executable
  ; args = List.map lit args
  ; env = []
  ; cwd = None
  ; redirects = []
  ; sandbox = Sandbox_target.host ()
  }

let parse source =
  match Masc_exec_bash_parser.Bash.parse_string source with
  | Parsed.Parsed ir -> ir
  | _ -> fail ("expected parse: " ^ source)

let with_process_env f =
  Eio_main.run @@ fun env ->
  Process_eio.init
    ~cwd_default:(Eio.Stdenv.cwd env)
    ~proc_mgr:(Eio.Stdenv.process_mgr env)
    ~clock:(Eio.Stdenv.clock env);
  f ()

let dispatch ?timeout_sec source =
  with_process_env (fun () ->
    Exec_dispatch.dispatch ?timeout_sec (parse source))

let contains_sub s sub =
  let n = String.length s and m = String.length sub in
  let rec go i = i + m <= n && (String.sub s i m = sub || go (i + 1)) in
  go 0

let test_roundtrip () =
  let result = dispatch "echo $(echo hi)" in
  assert (result.Exec_dispatch.status = Unix.WEXITED 0);
  assert (result.stdout = "hi\n")

let test_strips_trailing_newlines () =
  (* bash strips the trailing newlines; echo then adds exactly one back. *)
  let result = dispatch "echo $(printf 'a\\n\\n')" in
  assert (result.Exec_dispatch.status = Unix.WEXITED 0);
  assert (result.stdout = "a\n")

let test_one_argv_element_no_resplit () =
  (* printf '%s|' prints each argv element followed by '|' — a re-split of
     the substitution would print "a|b|" instead of "a b|". *)
  let result = dispatch "printf '%s|' $(printf 'a b')" in
  assert (result.Exec_dispatch.status = Unix.WEXITED 0);
  assert (result.stdout = "a b|")

let test_child_failure_does_not_fail_parent () =
  (* RFC §2.3.2: the child's exit status decides nothing. *)
  let result = dispatch "echo $(false)" in
  assert (result.Exec_dispatch.status = Unix.WEXITED 0);
  assert (result.stdout = "\n")

let test_child_stderr_joins_parent () =
  let result = dispatch "echo $(ls /nonexistent-masc-test-dir)" in
  assert (result.Exec_dispatch.status = Unix.WEXITED 0);
  assert (result.stdout = "\n");
  assert (result.stderr <> "")

let test_env_assignment_value () =
  let result = dispatch "MASC_SUBST_T=$(echo ok) printenv MASC_SUBST_T" in
  assert (result.Exec_dispatch.status = Unix.WEXITED 0);
  assert (result.stdout = "ok\n")

let test_sequence_and_pipeline () =
  let result = dispatch "echo $(echo a) && echo b" in
  assert (result.Exec_dispatch.status = Unix.WEXITED 0);
  assert (result.stdout = "a\nb\n");
  (* A Subst-bearing stage declines the native pipeline runner and takes
     the chain fallback, where dispatch_simple evaluates the stage. *)
  let result = dispatch "echo $(echo hi) | cat" in
  assert (result.Exec_dispatch.status = Unix.WEXITED 0);
  assert (result.stdout = "hi\n")

let test_nested () =
  let result = dispatch "echo $(echo $(echo deep))" in
  assert (result.Exec_dispatch.status = Unix.WEXITED 0);
  assert (result.stdout = "deep\n")

let test_substitution_timeout_budget () =
  (* The child rides the parent's budget; when sleep outruns it, nothing is
     left for the parent, which answers its own timeout rather than
     spawning (the budget is debited across children and parent alike). *)
  let result = dispatch ~timeout_sec:0.2 "echo $(sleep 5)" in
  assert (result.Exec_dispatch.status = Process_eio.timed_out_status);
  assert (result.stdout = "");
  assert (contains_sub result.stderr "timeout")

let test_substitution_inherits_delegated_target () =
  (* A spy runner stands in for the delegated target: the child must reach
     it (inheritance), and the parent's argv must hold the child's stdout
     as exactly one element. *)
  let calls = ref [] in
  let runner ~on_stdout_chunk:_ ~on_stderr_chunk:_ ~stdin_content:_ ~argv
      ~env:_ ~cwd:_ =
    calls := argv :: !calls;
    Sandbox_target.Ran
      { output_files = None
      ; status = Unix.WEXITED 0
      ; stdout = String.concat "," argv
      ; stderr = ""
      }
  in
  let target = Sandbox_target.delegated ~caller:runner () in
  let stage =
    { (simple "echo" []) with
      Shell_ir.args =
        [ Shell_ir.Subst (Shell_ir.Simple (simple "printf" [ "inner" ])) ]
    ; sandbox = target
    }
  in
  let result = Exec_dispatch.dispatch_simple stage in
  match List.rev !calls with
  | [ [ "printf"; "inner" ]; [ "echo"; "printf,inner" ] ] ->
    assert (result.Exec_dispatch.stdout = "echo,printf,inner")
  | _ -> fail "spy calls wrong: child must run first, parent second"

let test_with_sandbox_rewrites_subst_children () =
  let own = Sandbox_target.delegated ~caller:(fun ~on_stdout_chunk:_ ~on_stderr_chunk:_ ~stdin_content:_ ~argv:_ ~env:_ ~cwd:_ ->
    Sandbox_target.Ran
      { output_files = None; status = Unix.WEXITED 0; stdout = ""; stderr = "" })
    ()
  in
  let target = Sandbox_target.delegated ~caller:(fun ~on_stdout_chunk:_ ~on_stderr_chunk:_ ~stdin_content:_ ~argv:_ ~env:_ ~cwd:_ ->
    Sandbox_target.Ran
      { output_files = None; status = Unix.WEXITED 0; stdout = ""; stderr = "" })
    ()
  in
  let stage =
    { (simple "echo" []) with
      Shell_ir.args =
        [ Shell_ir.Subst (Shell_ir.Simple (simple "date" []))
        ; Shell_ir.Subst
            (Shell_ir.Simple
               { (simple "date" []) with Shell_ir.sandbox = own })
        ]
    }
  in
  match Shell_ir.with_sandbox target (Shell_ir.Simple stage) with
  | Shell_ir.Simple s ->
    (match s.sandbox, s.args with
     | ( Sandbox_target.Delegated _
       , [ Shell_ir.Subst (Shell_ir.Simple rewritten)
         ; Shell_ir.Subst (Shell_ir.Simple kept) ] ) ->
       (match rewritten.sandbox with
        | Sandbox_target.Delegated _ -> ()
        | _ -> fail "subst child must inherit the target");
       (* A Delegated child keeps its own target, physically unchanged. *)
       assert (kept.sandbox == own)
     | _ -> fail "with_sandbox must rewrite stage and subst children")
  | _ -> fail "with_sandbox must preserve the Simple shape"

let () =
  test_roundtrip ();
  test_strips_trailing_newlines ();
  test_one_argv_element_no_resplit ();
  test_child_failure_does_not_fail_parent ();
  test_child_stderr_joins_parent ();
  test_env_assignment_value ();
  test_sequence_and_pipeline ();
  test_nested ();
  test_substitution_timeout_budget ();
  test_substitution_inherits_delegated_target ();
  test_with_sandbox_rewrites_subst_children ();
  print_endline "test_shell_ir_subst_exec: all tests passed"
