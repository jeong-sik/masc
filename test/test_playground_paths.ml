(** Unit tests for Playground_paths — the SSOT for
    [.masc/playground/<keeper>/...] layout helpers. *)

open Alcotest
(* masc_config library is [wrapped = false], so Playground_paths is a
   top-level module once we link against it. *)
module PP = Playground_paths

let test_sanitize_allows_safe_chars () =
  check string "alphanumerics pass through"
    "cheolsu_1.2-test"
    (PP.sanitize_keeper_name "cheolsu_1.2-test");
  check string "already sanitized stays the same"
    "Abc-123_x.y"
    (PP.sanitize_keeper_name "Abc-123_x.y")

let test_sanitize_replaces_unsafe_chars () =
  check string "slash becomes underscore"
    "a_b"
    (PP.sanitize_keeper_name "a/b");
  check string "empty string becomes single underscore"
    "_"
    (PP.sanitize_keeper_name "");
  check string "single dot is replaced with underscore"
    "_"
    (PP.sanitize_keeper_name ".");
  check string "dot-dot is replaced with double underscore (no traversal)"
    "__"
    (PP.sanitize_keeper_name "..");
  check string "path traversal with slash is neutralized"
    ".._.._etc_passwd"
    (PP.sanitize_keeper_name "../../etc/passwd");
  check string "whitespace and punctuation replaced"
    "hi_there___"
    (PP.sanitize_keeper_name "hi there!?*")

let test_all_playgrounds_prefix_stable () =
  check string "canonical prefix"
    ".masc/playground" PP.all_playgrounds_prefix

let test_bundle_root_format () =
  check string "bundle root has trailing slash"
    ".masc/playground/cheolsu/"
    (PP.bundle_root "cheolsu");
  check string "bundle root sanitizes name"
    ".masc/playground/a_b/"
    (PP.bundle_root "a/b")

let test_mind_and_repos_paths () =
  check string "mind path"
    ".masc/playground/sangsu/mind/"
    (PP.mind_path "sangsu");
  check string "repos path"
    ".masc/playground/sangsu/repos/"
    (PP.repos_path "sangsu")

let test_bundle_paths_order () =
  check (list string) "bundle order: root, mind, repos"
    [ ".masc/playground/k1/";
      ".masc/playground/k1/mind/";
      ".masc/playground/k1/repos/" ]
    (PP.bundle_paths "k1")

let test_no_path_escape () =
  (* A poisoned name containing path separators must not produce a
     path that escapes the playground prefix. *)
  let bundle = PP.bundle_root "../../../etc" in
  check bool "sanitized bundle stays under prefix"
    true
    (String.length bundle >= String.length PP.all_playgrounds_prefix
     && String.sub bundle 0 (String.length PP.all_playgrounds_prefix)
        = PP.all_playgrounds_prefix);
  (* After sanitization, every non-safe char becomes '_'. "../../../etc"
     → ".._.._.._etc" which contains no "/" path separators at all, so
     the canonical "/<..>/" traversal segment cannot appear. *)
  check bool "no '/../' path segment remains in bundle"
    false
    (let re = Re.Pcre.re {|/\.\./|} |> Re.compile in
     Re.execp re bundle);
  (* And neither ".." nor "." can appear as a whole directory component. *)
  check string "dot-dot as whole name is neutralized"
    ".masc/playground/__/"
    (PP.bundle_root "..");
  check string "single dot as whole name is neutralized"
    ".masc/playground/_/"
    (PP.bundle_root ".");
  check string "empty name is neutralized"
    ".masc/playground/_/"
    (PP.bundle_root "")

let () =
  run "Playground_paths"
    [
      ("sanitize", [
        test_case "safe chars pass through" `Quick test_sanitize_allows_safe_chars;
        test_case "unsafe chars replaced" `Quick test_sanitize_replaces_unsafe_chars;
      ]);
      ("prefix", [
        test_case "all_playgrounds_prefix stable" `Quick test_all_playgrounds_prefix_stable;
      ]);
      ("paths", [
        test_case "bundle_root format" `Quick test_bundle_root_format;
        test_case "mind and repos paths" `Quick test_mind_and_repos_paths;
        test_case "bundle_paths order" `Quick test_bundle_paths_order;
      ]);
      ("security", [
        test_case "no path escape" `Quick test_no_path_escape;
      ]);
    ]
