(** Pure-function unit tests for [Keeper_alerting_path].
    Covers the deterministic helpers that don't touch the filesystem. *)

open Masc_mcp
module KAP = Keeper_alerting_path

let check_string_list label expected actual =
  Alcotest.(check (list string)) label expected actual

let check_bool label expected actual =
  Alcotest.(check bool) label expected actual

let check_string label expected actual =
  Alcotest.(check string) label expected actual

(* ── split_relative_components ───────────────────────────────────────── *)

let test_split_simple () =
  check_string_list "a/b/c" ["a"; "b"; "c"] (KAP.split_relative_components "a/b/c")

let test_split_drops_dot () =
  check_string_list "a/./b/c" ["a"; "b"; "c"]
    (KAP.split_relative_components "a/./b/c")

let test_split_drops_empty () =
  check_string_list "//a//b//" ["a"; "b"]
    (KAP.split_relative_components "//a//b//")

let test_split_preserves_dotdot () =
  check_string_list "a/../b" ["a"; ".."; "b"]
    (KAP.split_relative_components "a/../b")

let test_split_empty_string () =
  check_string_list "empty" [] (KAP.split_relative_components "")

let test_split_only_slashes () =
  check_string_list "///" [] (KAP.split_relative_components "///")

let test_split_only_dots () =
  check_string_list "./././" [] (KAP.split_relative_components "./././")

(* ── has_parent_component ────────────────────────────────────────────── *)

let test_has_parent_no_dotdot () =
  check_bool "[a;b;c] has no parent" false
    (KAP.has_parent_component ["a"; "b"; "c"])

let test_has_parent_with_dotdot () =
  check_bool "[a;..;b] has parent" true
    (KAP.has_parent_component ["a"; ".."; "b"])

let test_has_parent_only_dotdot () =
  check_bool "[..] has parent" true
    (KAP.has_parent_component [".."])

let test_has_parent_empty () =
  check_bool "[] has no parent" false
    (KAP.has_parent_component [])

let test_has_parent_dotdot_at_end () =
  check_bool "[a;b;..] has parent" true
    (KAP.has_parent_component ["a"; "b"; ".."])

(* ── join_path_components ────────────────────────────────────────────── *)

let test_join_empty () =
  check_string "[] joins to ." "." (KAP.join_path_components [])

let test_join_single () =
  check_string "[\"a\"] joins to a" "a" (KAP.join_path_components ["a"])

let test_join_multiple () =
  check_string "[a;b;c] joins to a/b/c" "a/b/c"
    (KAP.join_path_components ["a"; "b"; "c"])

(* ── starts_with ─────────────────────────────────────────────────────── *)

let test_starts_with_match () =
  check_bool "/foo starts with /" true
    (KAP.starts_with ~prefix:"/" "/foo")

let test_starts_with_full_match () =
  check_bool "abc starts with abc" true
    (KAP.starts_with ~prefix:"abc" "abc")

let test_starts_with_no_match () =
  check_bool "abc does not start with xyz" false
    (KAP.starts_with ~prefix:"xyz" "abc")

let test_starts_with_empty_prefix () =
  check_bool "anything starts with empty" true
    (KAP.starts_with ~prefix:"" "anything")

(* ── runner ──────────────────────────────────────────────────────────── *)

let () =
  Alcotest.run "Keeper_alerting_path"
    [
      ( "split_relative_components",
        [
          Alcotest.test_case "simple a/b/c" `Quick test_split_simple;
          Alcotest.test_case "drops './'" `Quick test_split_drops_dot;
          Alcotest.test_case "drops '//'" `Quick test_split_drops_empty;
          Alcotest.test_case "preserves '..'" `Quick test_split_preserves_dotdot;
          Alcotest.test_case "empty string" `Quick test_split_empty_string;
          Alcotest.test_case "only slashes" `Quick test_split_only_slashes;
          Alcotest.test_case "only dots" `Quick test_split_only_dots;
        ] );
      ( "has_parent_component",
        [
          Alcotest.test_case "no '..'" `Quick test_has_parent_no_dotdot;
          Alcotest.test_case "middle '..'" `Quick test_has_parent_with_dotdot;
          Alcotest.test_case "only '..'" `Quick test_has_parent_only_dotdot;
          Alcotest.test_case "empty list" `Quick test_has_parent_empty;
          Alcotest.test_case "trailing '..'" `Quick test_has_parent_dotdot_at_end;
        ] );
      ( "join_path_components",
        [
          Alcotest.test_case "empty -> '.'" `Quick test_join_empty;
          Alcotest.test_case "single component" `Quick test_join_single;
          Alcotest.test_case "multiple components" `Quick test_join_multiple;
        ] );
      ( "starts_with",
        [
          Alcotest.test_case "prefix match" `Quick test_starts_with_match;
          Alcotest.test_case "exact match" `Quick test_starts_with_full_match;
          Alcotest.test_case "no match" `Quick test_starts_with_no_match;
          Alcotest.test_case "empty prefix" `Quick test_starts_with_empty_prefix;
        ] );
    ]
