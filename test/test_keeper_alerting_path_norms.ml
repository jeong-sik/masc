(** Pure-function unit tests for [Keeper_alerting_path] root /
    allowed-norms boundary checks + rejection formatter.

    Audit P2 follow-up — extends #12847's coverage from 4 small
    helpers to the {b pure} security-boundary classifiers:

    - [is_within_allowed_norms]
    - [playground_root_of_allowed]
    - [raw_looks_like_playground_subdir]

    [is_within_root_norm] is intentionally NOT covered here:
    it normalizes its [path] argument via [Fs_compat.realpath]
    which has filesystem semantics (especially with [/tmp] being
    a symlink to [/private/tmp] on macOS), and platform-portable
    coverage requires creating real fixture directories.  That
    belongs in an integration test, not this pure-function suite.

    These are the LLM-facing boundary classifiers; a regression
    here either leaks host paths into LLM context (audit Tier A3
    redaction violation) or trips false-positive rejection loops
    that burn turns. *)

open Masc
module KAP = Keeper_alerting_path

let check_bool label expected actual =
  Alcotest.(check bool) label expected actual

let check_string_opt label expected actual =
  Alcotest.(check (option string)) label expected actual

(* ── is_within_allowed_norms ─────────────────────────────────── *)
(* This helper does NOT normalise its [target_norm] argument; it
   compares strings directly.  Tests pass pre-normalised inputs. *)

let test_allowed_exact_match () =
  check_bool "exact match in list → within" true
    (KAP.is_within_allowed_norms
       ~target_norm:"/abs/playground/k1"
       [ "/abs/playground/k1"; "/abs/decision_audit" ])

let test_allowed_subdir_match () =
  check_bool "subdir of allowed entry → within" true
    (KAP.is_within_allowed_norms
       ~target_norm:"/abs/playground/k1/file.txt"
       [ "/abs/playground/k1" ])

let test_allowed_empty_list_rejects () =
  check_bool "empty allowed list → not within" false
    (KAP.is_within_allowed_norms
       ~target_norm:"/abs/playground/k1" [])

let test_allowed_sibling_prefix_rejects () =
  (* Same prefix-confusion class — `/abs/p/k1-evil` shares a
     byte prefix with `/abs/p/k1` but is a sibling. *)
  check_bool "sibling with shared byte prefix → not within" false
    (KAP.is_within_allowed_norms
       ~target_norm:"/abs/p/k1-evil"
       [ "/abs/p/k1" ])

let test_allowed_unrelated_rejects () =
  check_bool "unrelated path → not within" false
    (KAP.is_within_allowed_norms
       ~target_norm:"/etc/passwd"
       [ "/abs/playground/k1"; "/abs/decision_audit" ])

(* ── playground_root_of_allowed ──────────────────────────────── *)

let test_playground_root_first_match () =
  (* The marker is "/" ^ Common.masc_dirname ^ "/playground/" =
     "/.masc/playground/" by default.  An absolute path
     containing this substring must match. *)
  check_string_opt "first .masc/playground/ entry returned"
    (Some "/abs/.masc/playground/k1")
    (KAP.playground_root_of_allowed
       [ "/abs/decision_audit"; "/abs/.masc/playground/k1" ])

let test_playground_root_none_when_absent () =
  check_string_opt "no .masc/playground/ → None"
    None
    (KAP.playground_root_of_allowed
       [ "/abs/decision_audit"; "/abs/.worktrees/x" ])

let test_playground_root_empty_list () =
  check_string_opt "empty list → None"
    None (KAP.playground_root_of_allowed [])

(* ── raw_looks_like_playground_subdir ────────────────────────── *)

let test_raw_looks_repos_prefix () =
  check_bool "repos/ prefix" true
    (KAP.raw_looks_like_playground_subdir "repos/proj/main.ml")

let test_raw_looks_mind_prefix () =
  check_bool "mind/ prefix" true
    (KAP.raw_looks_like_playground_subdir "mind/notes.md")

let test_raw_looks_repos_bare () =
  check_bool "bare 'repos'" true
    (KAP.raw_looks_like_playground_subdir "repos")

let test_raw_looks_mind_bare () =
  check_bool "bare 'mind'" true
    (KAP.raw_looks_like_playground_subdir "mind")

let test_raw_looks_other_rejected () =
  check_bool "src/foo.ml → no" false
    (KAP.raw_looks_like_playground_subdir "src/foo.ml")

let test_raw_looks_empty_rejected () =
  check_bool "empty string → no" false
    (KAP.raw_looks_like_playground_subdir "")

let test_raw_looks_repos_typo_rejected () =
  (* "repository/foo" shares the byte prefix "repos" with the
     writable shape "repos/..." but the [starts_with] check uses
     the literal prefix "repos/" — "repository/foo" does NOT
     start with "repos/" (the byte at position 5 is 'i', not
     '/'), so the sibling-typo case is correctly rejected. *)
  check_bool
    "'repository/foo' does not start with 'repos/' (sibling typo)"
    false
    (KAP.raw_looks_like_playground_subdir "repository/foo")

(* ── normalize_path_for_check_stripped ──────────────────────── *)

let test_normalize_path_for_check_stripped_removes_trailing_slash () =
  let cwd = Sys.getcwd () in
  let raw = cwd ^ "/" in
  check_bool "fixture cwd is not root" true (cwd <> "/");
  Alcotest.(check string) "normalized and stripped"
    (KAP.normalize_path_for_check cwd)
    (KAP.normalize_path_for_check_stripped raw)

(* ── is_masc_internal_state_norm ────────────────────────────── *)

let test_normalized_masc_root_blocked () =
  check_bool "normalized .masc root → internal" true
    (KAP.is_masc_internal_state_norm
       ~root_norm:"/workspace/project"
       ~target_norm:"/workspace/project/.masc")

let test_normalized_masc_config_keeper_blocked () =
  check_bool "normalized .masc/config/keepers target → internal" true
    (KAP.is_masc_internal_state_norm
       ~root_norm:"/workspace/project"
       ~target_norm:"/workspace/project/.masc/config/keepers/evil.toml")

let test_normalized_masc_sibling_allowed () =
  check_bool "sibling .masc-tools directory → not internal" false
    (KAP.is_masc_internal_state_norm
       ~root_norm:"/workspace/project"
       ~target_norm:"/workspace/project/.masc-tools/notes.md")

let test_normalized_project_file_allowed () =
  check_bool "ordinary project file → not internal" false
    (KAP.is_masc_internal_state_norm
       ~root_norm:"/workspace/project"
       ~target_norm:"/workspace/project/lib/file.ml")

(* ── runner ──────────────────────────────────────────────────── *)

let () =
  Alcotest.run "Keeper_alerting_path_norms"
    [
      ( "is_within_allowed_norms",
        [
          Alcotest.test_case "exact match" `Quick
            test_allowed_exact_match;
          Alcotest.test_case "subdir match" `Quick
            test_allowed_subdir_match;
          Alcotest.test_case "empty list rejects" `Quick
            test_allowed_empty_list_rejects;
          Alcotest.test_case "sibling prefix rejects" `Quick
            test_allowed_sibling_prefix_rejects;
          Alcotest.test_case "unrelated path rejects" `Quick
            test_allowed_unrelated_rejects;
        ] );
      ( "playground_root_of_allowed",
        [
          Alcotest.test_case "first match returned" `Quick
            test_playground_root_first_match;
          Alcotest.test_case "no match → None" `Quick
            test_playground_root_none_when_absent;
          Alcotest.test_case "empty list → None" `Quick
            test_playground_root_empty_list;
        ] );
      ( "raw_looks_like_playground_subdir",
        [
          Alcotest.test_case "repos/ prefix" `Quick
            test_raw_looks_repos_prefix;
          Alcotest.test_case "mind/ prefix" `Quick
            test_raw_looks_mind_prefix;
          Alcotest.test_case "bare 'repos'" `Quick
            test_raw_looks_repos_bare;
          Alcotest.test_case "bare 'mind'" `Quick
            test_raw_looks_mind_bare;
          Alcotest.test_case "src/ rejected" `Quick
            test_raw_looks_other_rejected;
          Alcotest.test_case "empty rejected" `Quick
            test_raw_looks_empty_rejected;
          Alcotest.test_case "'repository/foo' sibling typo rejected"
            `Quick test_raw_looks_repos_typo_rejected;
        ] );
      ( "normalize_path_for_check_stripped",
        [
          Alcotest.test_case "removes trailing slash" `Quick
            test_normalize_path_for_check_stripped_removes_trailing_slash;
        ] );
      ( "is_masc_internal_state_norm",
        [
          Alcotest.test_case "blocks .masc root" `Quick
            test_normalized_masc_root_blocked;
          Alcotest.test_case "blocks .masc keeper config" `Quick
            test_normalized_masc_config_keeper_blocked;
          Alcotest.test_case "allows .masc sibling" `Quick
            test_normalized_masc_sibling_allowed;
          Alcotest.test_case "allows project file" `Quick
            test_normalized_project_file_allowed;
        ] );
    ]
