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

let test_pipeline_substitution_stays_streaming () =
  (* PR review #34929: a substitution-bearing pipeline must stay on the
     streaming runners — declining to them would drop the whole pipeline on
     the buffered chain, where [yes] runs to completion before [head]
     starts and the run can only end as the timeout. One delivered line
     inside the budget is the streaming proof. *)
  let result = dispatch ~timeout_sec:5.0 "yes $(printf x) | head -1" in
  assert (result.Exec_dispatch.status <> Process_eio.timed_out_status);
  assert (result.stdout = "x\n")

let test_substitution_sequence_shares_deadline () =
  (* PR review #34929: one deadline spans a substitution's children. A
     sequence inside [$( )] must not hand each stage a fresh copy of the
     remaining timeout: with a 0.3s budget the first sleep spends 0.2s and
     the second is killed at the ~0.1s remainder, which the timeout
     observer reports directly. Wall-clock is the wrong gauge here —
     Process_eio waits out its own kill grace after the cut, so elapsed
     says nothing about when the child actually stopped. *)
  let observed = ref [] in
  let previous = Atomic.get Process_eio.process_timeout_observer_fn in
  Atomic.set
    Process_eio.process_timeout_observer_fn
    (fun ~program ~timeout_sec ~origin:_ ->
      if program = "sleep" then observed := timeout_sec :: !observed);
  Fun.protect
    ~finally:(fun () ->
      Atomic.set Process_eio.process_timeout_observer_fn previous)
    (fun () ->
      let result = dispatch ~timeout_sec:0.3 "echo $(sleep 0.2; sleep 0.2)" in
      assert (result.Exec_dispatch.status = Process_eio.timed_out_status);
      match !observed with
      | [ second ] ->
          (* 0.3 budget - 0.2 spent = 0.1 remainder, plus scheduling slack;
             a fresh copy of the budget would read ~0.3 *)
          if second > 0.15 then
            fail
              ("second stage saw a fresh budget instead of the remainder: "
               ^ Float.to_string second)
      | _ -> fail "expected exactly one observed child timeout")

let test_substitution_inherits_parent_cwd () =
  (* PR review #34929: a substitution child with no cwd of its own inherits
     the parent's — [eval_substitutions] hands every [Subst] child through
     [Shell_ir.with_sandbox_cwd] before dispatch, planting the parent's
     scope on stages that lack one, recursively; a child's own declared cwd
     always wins. (The rewrite is what execution reads —
     [process_spec_of_simple] passes [s.cwd] to the spawn as-is — so the IR
     shape is the contract. An executed [$(pwd)] proof is not possible
     under this harness: the test env grants Eio capabilities for its own
     sandbox cwd only, so any cwd-holding spawn is refused before the
     inheritance could show.) *)
  let parent_cwd = Path_scope.classify ~raw:"/writable/root" ~cwd:"/" in
  let child_cwd = Path_scope.classify ~raw:"/writable/child" ~cwd:"/" in
  let stage =
    { (simple "echo" []) with
      Shell_ir.cwd = Some parent_cwd
    ; Shell_ir.args =
        [ Shell_ir.Subst
            (Shell_ir.Simple { (simple "pwd" []) with Shell_ir.cwd = None })
        ; Shell_ir.Subst
            (Shell_ir.Simple { (simple "pwd" []) with Shell_ir.cwd = Some child_cwd })
        ]
    }
  in
  match
    Shell_ir.with_sandbox_cwd (Sandbox_target.host ()) (Some parent_cwd)
      (Shell_ir.Simple stage)
  with
  | Shell_ir.Simple s ->
    (match s.args with
     | [ Shell_ir.Subst (Shell_ir.Simple inherited)
       ; Shell_ir.Subst (Shell_ir.Simple own) ] ->
       (match inherited.cwd, own.cwd with
        | Some got, Some kept ->
          assert (Path_scope.raw got = Path_scope.raw parent_cwd);
          assert (Path_scope.raw kept = Path_scope.raw child_cwd)
        | _ -> fail "both children must carry a cwd after inheritance")
     | _ -> fail "args must survive the rewrite")
  | Shell_ir.Pipeline _ | Shell_ir.Sequence _ ->
    fail "with_sandbox_cwd must preserve the Simple shape"

let test_substitution_reads_parent_stdin () =
  (* PR review #34929: [$(cat)] reads the same stdin the parent is given —
     [printf '<%s>' "$(cat)"] substitutes the piped bytes instead of
     blocking on or reading an unrelated stdin. *)
  with_process_env (fun () ->
    let result =
      Exec_dispatch.dispatch ~stdin_content:"payload" (parse "printf '<%s>' \"$(cat)\"")
    in
    assert (result.Exec_dispatch.status = Unix.WEXITED 0);
    assert (result.stdout = "<payload>"))

let test_child_stderr_reaches_stream_callback () =
  (* PR review #34929: a substitution child's stderr is delivered through
     [on_output_chunk] — the child's first, the parent's own after —
     instead of being suppressed when the parent already streamed. *)
  let chunks = ref [] in
  with_process_env (fun () ->
    let result =
      Exec_dispatch.dispatch
        ~on_output_chunk:(fun chunk -> chunks := chunk :: !chunks)
        (parse "echo $(ls /nonexistent-masc-test-dir)")
    in
    assert (result.Exec_dispatch.status = Unix.WEXITED 0);
    match
      List.filter (function `Stderr _ -> true | `Stdout _ -> false) (List.rev !chunks)
    with
    | [ `Stderr text ] -> assert (text <> "")
    | _ -> fail "expected exactly one stderr chunk — the child's diagnostics")

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
  test_pipeline_substitution_stays_streaming ();
  test_substitution_sequence_shares_deadline ();
  test_substitution_inherits_parent_cwd ();
  test_substitution_reads_parent_stdin ();
  test_child_stderr_reaches_stream_callback ();
  print_endline "test_shell_ir_subst_exec: all tests passed"
