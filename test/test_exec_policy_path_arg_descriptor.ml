(** Shell IR Adjacent Surfaces Plan §P11 — descriptor coverage for
    path-bearing argv tokens in [Exec_policy].

    Pins the descriptor surface that [Exec_policy.validate_shell_ir_paths]
    consults *before* the [looks_like_path_token] heuristic. The intent
    is twofold:

    - Document the closed set: which path flags and which positional-
      path commands the policy knows about.
    - Document the *intentional* exclusions ([git], [gh]) so a future
      refactor that "just adds gh" silently does not bypass Shell IR
      executable/risk classification.

    Behavior-preserving. Failure here means the descriptor surface
    drifted relative to its mli contract. *)

open Masc
module D = Exec_policy_path_arg_descriptor

let test_is_path_flag_closed_set () =
  List.iter
    (fun flag ->
      Alcotest.(check bool) ("is_path_flag " ^ flag) true (D.is_path_flag flag))
    [ "-C"; "--git-dir"; "--work-tree"; "--exec-path" ];
  List.iter
    (fun non_flag ->
      Alcotest.(check bool)
        ("not is_path_flag " ^ non_flag) false (D.is_path_flag non_flag))
    [ ""; "-c"; "--Git-Dir"; "--cwd"; "-D"; "--workdir"; "/tmp" ]

let test_path_flag_requires_existing_dir_subset () =
  Alcotest.(check bool) "-C requires existing dir" true
    (D.path_flag_requires_existing_dir "-C");
  Alcotest.(check bool) "--work-tree requires existing dir" true
    (D.path_flag_requires_existing_dir "--work-tree");
  (* --git-dir and --exec-path point at directories that may be
     created later, so they MUST NOT require existing dir at policy
     check time. *)
  Alcotest.(check bool) "--git-dir does not require existing dir" false
    (D.path_flag_requires_existing_dir "--git-dir");
  Alcotest.(check bool) "--exec-path does not require existing dir" false
    (D.path_flag_requires_existing_dir "--exec-path")

let test_path_value_of_flagged_token_inline_forms () =
  Alcotest.(check (option string)) "--git-dir=/repo/.git" (Some "/repo/.git")
    (D.path_value_of_flagged_token "--git-dir=/repo/.git");
  Alcotest.(check (option string)) "--work-tree=/tmp/wt" (Some "/tmp/wt")
    (D.path_value_of_flagged_token "--work-tree=/tmp/wt");
  Alcotest.(check (option string)) "--exec-path=/usr/libexec/git-core"
    (Some "/usr/libexec/git-core")
    (D.path_value_of_flagged_token "--exec-path=/usr/libexec/git-core");
  Alcotest.(check (option string)) "non-inline flag returns None" None
    (D.path_value_of_flagged_token "--git-dir");
  Alcotest.(check (option string)) "unknown inline flag returns None" None
    (D.path_value_of_flagged_token "--cwd=/tmp");
  Alcotest.(check (option string)) "positional path returns None" None
    (D.path_value_of_flagged_token "/etc/hosts")

let test_inline_path_flag_requires_existing_dir () =
  Alcotest.(check bool) "--work-tree=/tmp requires existing dir" true
    (D.inline_path_flag_requires_existing_dir "--work-tree=/tmp");
  Alcotest.(check bool) "--git-dir=/repo/.git does not require existing dir"
    false
    (D.inline_path_flag_requires_existing_dir "--git-dir=/repo/.git");
  Alcotest.(check bool) "unknown inline flag does not require existing dir"
    false
    (D.inline_path_flag_requires_existing_dir "--cwd=/tmp")

let test_command_materializes_path_arg_corpus_membership () =
  List.iter
    (fun command ->
      Alcotest.(check bool)
        (command ^ " materializes path arg") true
        (D.command_materializes_path_arg command))
    D.path_arg_command_corpus;
  (* tree is a tool_search_files host op — positional arg is always a path. *)
  Alcotest.(check bool) "tree materializes path arg" true
    (D.command_materializes_path_arg "tree")

let test_command_materializes_path_arg_exclusions () =
  (* Intentional exclusions — these commands have their own typed
     surfaces and must NOT be classified as positional-path
     materializers, otherwise the descriptor would silently consume
     refs/revisions/issue-numbers as paths and fail validation
     incorrectly. *)
  List.iter
    (fun command ->
      Alcotest.(check bool)
        (command ^ " is not materializer") false
        (D.command_materializes_path_arg command))
    [ "git"; "gh"; "echo"; "true"; "false"; "env"; "opam"; "" ]

let test_corpus_and_predicate_are_in_sync () =
  (* The exported [path_arg_command_corpus] must be exactly the
     positive set of [command_materializes_path_arg]. Adding a name to
     one without the other would drift the SSOT. *)
  let predicate_positive_for_corpus =
    List.for_all D.command_materializes_path_arg D.path_arg_command_corpus
  in
  Alcotest.(check bool) "every corpus entry returns true" true
    predicate_positive_for_corpus;
  (* Spot-check a known *out-of-corpus* name returns false. *)
  Alcotest.(check bool) "a non-corpus name returns false" false
    (D.command_materializes_path_arg "made-up-command-12345")

let test_rg_context_flags_are_not_path_args () =
  let values =
    Exec_policy.path_argument_values "rg"
      [ "capacity"; "repos/masc"; "-n"; "-C"; "3" ]
  in
  Alcotest.(check bool) "search path remains" true
    (List.mem "repos/masc" values);
  Alcotest.(check bool) "context flag skipped" false (List.mem "-C" values);
  Alcotest.(check bool) "context count skipped" false (List.mem "3" values)

let test_grep_context_flags_are_not_path_args () =
  let values =
    Exec_policy.path_argument_values "grep"
      [ "-R"; "-C"; "3"; "capacity"; "repos/masc" ]
  in
  Alcotest.(check bool) "grep search path remains" true
    (List.mem "repos/masc" values);
  Alcotest.(check bool) "grep context flag skipped" false
    (List.mem "-C" values);
  Alcotest.(check bool) "grep context count skipped" false
    (List.mem "3" values)

let test_sandbox_backend_fails_loud () =
  let simple : Masc_exec.Shell_ir.simple =
    { bin = Masc_exec.Exec_program.of_known Masc_exec.Exec_program.Ls
    ; args = []
    ; env = []
    ; cwd = None
    ; redirects = []
    ; sandbox = Masc_exec.Sandbox_target.host ()
    }
  in
  let safe_ir =
    Typed_capabilities.Safe_IR (Masc_exec.Shell_ir.Simple simple)
  in
  Eio_main.run @@ fun env ->
  match Sandbox_backend.run safe_ir env with
  | Error error ->
      Alcotest.(check string)
        "unsupported backend is explicit"
        "masc.exec_policy Sandbox_backend.run is disabled; use \
         Masc.Keeper_sandbox_runner/Keeper_sandbox_docker"
        (Sandbox_backend.error_message error)
  | Ok result ->
      Alcotest.failf "unexpected sandbox success: exit_code=%d stdout=%S"
        result.exit_code result.stdout

let () =
  Alcotest.run "exec_policy_path_arg_descriptor"
    [ ( "separated flag form"
      , [ Alcotest.test_case "closed set" `Quick test_is_path_flag_closed_set
        ; Alcotest.test_case "requires existing dir subset" `Quick
            test_path_flag_requires_existing_dir_subset
        ] )
    ; ( "inline flag form"
      , [ Alcotest.test_case "value extraction" `Quick
            test_path_value_of_flagged_token_inline_forms
        ; Alcotest.test_case "existing-dir gate" `Quick
            test_inline_path_flag_requires_existing_dir
        ] )
    ; ( "positional-path commands"
      , [ Alcotest.test_case "corpus membership" `Quick
            test_command_materializes_path_arg_corpus_membership
        ; Alcotest.test_case "intentional exclusions" `Quick
            test_command_materializes_path_arg_exclusions
        ; Alcotest.test_case "corpus ⇔ predicate in sync" `Quick
            test_corpus_and_predicate_are_in_sync
        ] )
    ; ( "path arg extraction"
      , [ Alcotest.test_case "rg context flags are not paths" `Quick
            test_rg_context_flags_are_not_path_args
        ; Alcotest.test_case "grep context flags are not paths" `Quick
            test_grep_context_flags_are_not_path_args
        ] )
    ; ( "sandbox backend"
      , [ Alcotest.test_case "fails loud instead of fake success" `Quick
            test_sandbox_backend_fails_loud
        ] )
    ]
