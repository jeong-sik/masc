(** P0-X Layer B predicate-level unit tests for
    [Keeper_shell_bash_cross_repo_discovery].

    These tests exercise the three pure [string -> bool] predicates plus
    the [classify_repo_wide_discovery] disjunction directly, with no
    Eio/config bootstrap. Layer A integration coverage lives in
    [test_keeper_shell_bash_cross_host_probe.ml]; this file pins the
    predicate boundary so future regressions in the substring rules
    surface in a fast, deterministic unit test. *)

module Discovery = Masc_mcp.Keeper_shell_bash_cross_repo_discovery

let check_true label actual =
  Alcotest.(check bool) label true actual

let check_false label actual =
  Alcotest.(check bool) label false actual

(* Pattern #1: worktree discovery. Requires both [find repos] (or
   [find ./repos]) AND a [.worktrees] / [ worktrees] token. *)

let test_worktree_discovery_positive_canonical () =
  check_true
    "find repos -maxdepth 4 -type d -name .worktrees -> worktree_discovery"
    (Discovery.command_looks_like_worktree_discovery
       "find repos -maxdepth 4 -type d -name .worktrees")

let test_worktree_discovery_negative_no_worktrees_token () =
  check_false
    "find . -maxdepth 4 (no .worktrees keyword) -> not worktree_discovery"
    (Discovery.command_looks_like_worktree_discovery
       "find . -maxdepth 4 -type d")

let test_worktree_discovery_negative_absolute_tmp_path () =
  check_false
    "find /tmp/foo -type d -> not worktree_discovery (no [find repos])"
    (Discovery.command_looks_like_worktree_discovery
       "find /tmp/foo -type d")

(* Pattern #2: cross-repo grep. Requires both [rg ]/[grep ] AND a
   leading-space [ repos/] (or [ ./repos/]) path token. *)

let test_cross_repo_grep_positive_rg () =
  check_true
    "rg -l \"current_task\" repos/ -> cross_repo_grep"
    (Discovery.command_looks_like_cross_repo_grep
       "rg -l \"current_task\" repos/")

let test_cross_repo_grep_negative_scoped_src_path () =
  check_false
    "grep \"TODO\" src/foo.ts -> not cross_repo_grep (path is src/, not repos/)"
    (Discovery.command_looks_like_cross_repo_grep
       "grep \"TODO\" src/foo.ts")

(* Pattern #3: cross-host probe. Requires [find /home] or [find /Users]
   AND any directory-walk flag ([-type d], [-name], or [-maxdepth]).
   Already exercised end-to-end by Team BB's Layer A integration test;
   mirrored here at the predicate boundary for fast regression. *)

let test_cross_host_probe_positive_home () =
  check_true
    "find /home/user -type d -> cross_host_probe"
    (Discovery.command_looks_like_cross_host_probe
       "find /home/user -type d")

let test_cross_host_probe_positive_users_maxdepth () =
  check_true
    "find /Users/dancer -maxdepth 2 -> cross_host_probe"
    (Discovery.command_looks_like_cross_host_probe
       "find /Users/dancer -maxdepth 2")

let test_cross_host_probe_negative_relative_repos_foo () =
  check_false
    "find repos/foo -type d -> not cross_host_probe (path is relative)"
    (Discovery.command_looks_like_cross_host_probe
       "find repos/foo -type d")

(* Disjunction + classifier: most-specific-first ordering. *)

let test_aggregate_disjunction_unrelated_command () =
  check_false
    "ls -la -> not repo_wide_discovery (no signature matches)"
    (Discovery.command_looks_like_repo_wide_discovery "ls -la")

let test_classify_worktree_wins_over_others () =
  (* Same command exercises worktree_discovery; classifier must return
     [Worktree_discovery] (the most-specific match), not fall through to
     [Cross_repo_grep] or [Cross_host_probe]. *)
  let result =
    Discovery.classify_repo_wide_discovery
      "find repos -maxdepth 4 -type d -name .worktrees"
  in
  match result with
  | Some Discovery.Worktree_discovery -> ()
  | Some Discovery.Cross_repo_grep ->
      Alcotest.fail "classifier picked Cross_repo_grep instead of Worktree_discovery"
  | Some Discovery.Cross_host_probe ->
      Alcotest.fail "classifier picked Cross_host_probe instead of Worktree_discovery"
  | None ->
      Alcotest.fail "classifier returned None for canonical worktree-discovery cmd"

let () =
  Alcotest.run
    "keeper_shell_bash_cross_repo_discovery"
    [
      ( "Pattern #1 worktree discovery predicate",
        [
          Alcotest.test_case
            "canonical [find repos ... .worktrees] matches"
            `Quick
            test_worktree_discovery_positive_canonical;
          Alcotest.test_case
            "[find . -maxdepth 4] without .worktrees does not match"
            `Quick
            test_worktree_discovery_negative_no_worktrees_token;
          Alcotest.test_case
            "[find /tmp/foo -type d] does not match (no [find repos])"
            `Quick
            test_worktree_discovery_negative_absolute_tmp_path;
        ] );
      ( "Pattern #2 cross-repo grep predicate",
        [
          Alcotest.test_case
            "[rg -l ... repos/] matches"
            `Quick
            test_cross_repo_grep_positive_rg;
          Alcotest.test_case
            "[grep TODO src/foo.ts] does not match (not repos/ root)"
            `Quick
            test_cross_repo_grep_negative_scoped_src_path;
        ] );
      ( "Pattern #3 cross-host probe predicate",
        [
          Alcotest.test_case
            "[find /home/user -type d] matches"
            `Quick
            test_cross_host_probe_positive_home;
          Alcotest.test_case
            "[find /Users/dancer -maxdepth 2] matches"
            `Quick
            test_cross_host_probe_positive_users_maxdepth;
          Alcotest.test_case
            "[find repos/foo -type d] does not match (relative path)"
            `Quick
            test_cross_host_probe_negative_relative_repos_foo;
        ] );
      ( "Aggregate disjunction + classifier",
        [
          Alcotest.test_case
            "[ls -la] does not match any signature"
            `Quick
            test_aggregate_disjunction_unrelated_command;
          Alcotest.test_case
            "classifier returns Worktree_discovery for canonical worktree cmd"
            `Quick
            test_classify_worktree_wins_over_others;
        ] );
    ]
