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

open Masc_mcp
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
  (* tree is a tool_workspace_inspect host op — positional arg is always a path. *)
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
    ]
