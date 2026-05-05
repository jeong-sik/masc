(** Pure-function unit tests for [Keeper_alerting_path] root /
    allowed-norms boundary checks + rejection formatter.

    Audit P2 follow-up — extends #12847's coverage from 4 small
    helpers to the security-boundary functions:

    - [is_within_root_norm] (line 62)
    - [is_within_allowed_norms] (line 149)
    - [playground_root_of_allowed] (line 186)
    - [raw_looks_like_playground_subdir] (line 200)
    - [format_path_rejection] (line 206)

    These are the LLM-facing boundary classifiers; a regression
    here either leaks host paths into LLM context (audit Tier A3
    redaction violation) or trips false-positive rejection loops
    that burn turns. *)

open Masc_mcp
module KAP = Keeper_alerting_path

let check_bool label expected actual =
  Alcotest.(check bool) label expected actual

let check_string label expected actual =
  Alcotest.(check string) label expected actual

let check_string_opt label expected actual =
  Alcotest.(check (option string)) label expected actual

(* ── is_within_root_norm ─────────────────────────────────────── *)
(* Note: the impl normalises [path] via Fs_compat.realpath before
   the prefix check, so absolute paths that don't actually exist
   will not match.  Use roots that exist (e.g. /tmp) for these
   tests. *)

let test_within_root_exact_match () =
  let root = Filename.get_temp_dir_name () in
  check_bool "exact match → within" true
    (KAP.is_within_root_norm ~root_norm:root root)

let test_within_root_subdir_match () =
  let root = Filename.get_temp_dir_name () in
  let sub = Filename.concat root "x" in
  check_bool "subdir → within" true
    (KAP.is_within_root_norm ~root_norm:root sub)

let test_within_root_sibling_no_match () =
  (* root_norm = "/tmp/aa", path = "/tmp/aa-sneaky" — sibling
     directory, must NOT match.  This is the prefix-confusion
     scenario from audit §1.2. *)
  check_bool "sibling with shared byte prefix → not within" false
    (KAP.is_within_root_norm
       ~root_norm:"/tmp/aa" "/tmp/aa-sneaky")

let test_within_root_outside_no_match () =
  let root = Filename.get_temp_dir_name () in
  check_bool "outside root → not within" false
    (KAP.is_within_root_norm ~root_norm:root "/etc/passwd")

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
  (* "repository/" is not a playground subdir even though it
     shares the byte prefix "repos" — the check uses
     prefix:"repos/" so the trailing '/' is required. *)
  check_bool "'repository/' prefix mismatch (no trailing /)"
    false
    (KAP.raw_looks_like_playground_subdir "repository/foo")

(* ── format_path_rejection: redaction guarantees ─────────────── *)

let test_format_rejection_includes_raw () =
  let msg =
    KAP.format_path_rejection
      ~raw:"src/foo.ml" ~resolved:"/abs/proj/src/foo.ml"
      ~allowed_norms:[]
  in
  check_bool "rejection mentions raw path" true
    (Astring.String.is_infix ~affix:"src/foo.ml" msg);
  check_bool "rejection prefix is path_outside_sandbox" true
    (Astring.String.is_prefix ~affix:"path_outside_sandbox:" msg)

let test_format_rejection_relative_hint () =
  let msg =
    KAP.format_path_rejection
      ~raw:"src/foo.ml" ~resolved:"/abs/proj/src/foo.ml"
      ~allowed_norms:[]
  in
  (* relative raw + resolved differs → relative-hint suffix
     present *)
  check_bool "relative hint emitted" true
    (Astring.String.is_infix
       ~affix:"sandbox boundary" msg)

let test_format_rejection_absolute_no_relative_hint () =
  let msg =
    KAP.format_path_rejection
      ~raw:"/etc/passwd" ~resolved:"/etc/passwd"
      ~allowed_norms:[]
  in
  (* Absolute raw + resolved=raw → no relative-hint suffix. *)
  check_bool "no relative hint for absolute" false
    (Astring.String.is_infix
       ~affix:"sandbox boundary" msg)

let test_format_rejection_playground_hint_when_match () =
  let msg =
    KAP.format_path_rejection
      ~raw:"repos/proj"
      ~resolved:"repos/proj"
      ~allowed_norms:
        [ "/abs/.masc/playground/k1" ]
  in
  (* raw_looks_like_playground_subdir + playground root present
     → emit playground rewrite suggestion. *)
  check_bool "playground hint emitted" true
    (Astring.String.is_infix
       ~affix:"keeper_context_status" msg)

let test_format_rejection_no_playground_hint_for_other () =
  let msg =
    KAP.format_path_rejection
      ~raw:"src/foo.ml" ~resolved:"src/foo.ml"
      ~allowed_norms:
        [ "/abs/.masc/playground/k1" ]
  in
  (* "src/" doesn't trigger playground heuristic. *)
  check_bool "no playground hint for non-repos/non-mind raw" false
    (Astring.String.is_infix
       ~affix:"keeper_context_status" msg)

let test_format_rejection_does_not_leak_allowed_norms () =
  (* Audit Tier A3 redaction guarantee: allowed_norms must NOT
     appear verbatim in the rejection message — they often
     contain host-absolute paths.  Pin this. *)
  let secret_path = "/host/absolute/playground/secret_keeper" in
  let msg =
    KAP.format_path_rejection
      ~raw:"src/foo.ml" ~resolved:"src/foo.ml"
      ~allowed_norms:[ secret_path ]
  in
  check_bool "rejection does NOT leak allowed_norms verbatim" false
    (Astring.String.is_infix ~affix:secret_path msg)

(* ── runner ──────────────────────────────────────────────────── *)

let () =
  Alcotest.run "Keeper_alerting_path_norms"
    [
      ( "is_within_root_norm",
        [
          Alcotest.test_case "exact match" `Quick
            test_within_root_exact_match;
          Alcotest.test_case "subdir match" `Quick
            test_within_root_subdir_match;
          Alcotest.test_case "sibling shared-prefix rejected"
            `Quick test_within_root_sibling_no_match;
          Alcotest.test_case "outside root rejected" `Quick
            test_within_root_outside_no_match;
        ] );
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
          Alcotest.test_case "repository/ rejected (no trailing /)"
            `Quick test_raw_looks_repos_typo_rejected;
        ] );
      ( "format_path_rejection",
        [
          Alcotest.test_case "includes raw + standard prefix"
            `Quick test_format_rejection_includes_raw;
          Alcotest.test_case "relative raw → relative hint"
            `Quick test_format_rejection_relative_hint;
          Alcotest.test_case "absolute raw → no relative hint"
            `Quick test_format_rejection_absolute_no_relative_hint;
          Alcotest.test_case
            "playground hint when raw + playground root match"
            `Quick test_format_rejection_playground_hint_when_match;
          Alcotest.test_case
            "no playground hint for unrelated raw" `Quick
            test_format_rejection_no_playground_hint_for_other;
          Alcotest.test_case
            "Tier A3: does not leak allowed_norms verbatim"
            `Quick test_format_rejection_does_not_leak_allowed_norms;
        ] );
    ]
[@@@warning "-32-27"]
let _ = check_string  (* silence unused-helper warning *)
