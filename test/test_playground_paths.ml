(** Unit tests for Playground_paths — the SSOT for
    [.masc/playground/<keeper>/...] layout helpers. *)

open Alcotest
(* masc_config library is [wrapped = false], so Playground_paths is a
   top-level module once we link against it. *)
module PP = Playground_paths

let test_sanitize_allows_safe_chars () =
  check string "alphanumerics pass through"
    "beta_1.2-test"
    (PP.sanitize_keeper_name "beta_1.2-test");
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
    ".masc/playground/beta/"
    (PP.bundle_root "beta");
  check string "bundle root sanitizes name"
    ".masc/playground/a_b/"
    (PP.bundle_root "a/b")

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

(* Canonical/short name normalization — keeper-X-agent strips to X *)

let test_strip_canonical_to_short () =
  check string "canonical stripped to short"
    "omicron-improver"
    (PP.sanitize_keeper_name "keeper-omicron-improver-agent");
  check string "short stays short"
    "omicron-improver"
    (PP.sanitize_keeper_name "omicron-improver");
  check string "beta canonical"
    "beta"
    (PP.sanitize_keeper_name "keeper-beta-agent");
  check string "alpha canonical"
    "alpha"
    (PP.sanitize_keeper_name "keeper-alpha-agent")

let test_canonical_short_path_identity () =
  check string "bundle_root identity"
    (PP.bundle_root "beta")
    (PP.bundle_root "keeper-beta-agent")

let test_strip_edge_cases () =
  check string "keeper-agent not stripped (inner would be empty)"
    "keeper-agent"
    (PP.sanitize_keeper_name "keeper-agent");
  check string "single-char inner name"
    "x"
    (PP.sanitize_keeper_name "keeper-x-agent");
  check string "idempotent"
    (PP.sanitize_keeper_name "omicron-improver")
    (PP.sanitize_keeper_name
       (PP.sanitize_keeper_name "keeper-omicron-improver-agent"));
  check string "different keepers stay different"
    "alpha"
    (PP.sanitize_keeper_name "keeper-alpha-agent");
  check bool "alpha != beta after normalize"
    true
    (PP.sanitize_keeper_name "keeper-alpha-agent"
     <> PP.sanitize_keeper_name "keeper-beta-agent")

let test_strip_no_traversal () =
  let result = PP.sanitize_keeper_name "keeper-../../etc-agent" in
  check bool "no slash in result" true
    (not (String.contains result '/'));
  check bool "no backslash in result" true
    (not (String.contains result '\\'))

let test_parse_playground_repo_path () =
  let base_path = "/tmp/masc-base" in
  let parse rel =
    PP.parse_playground_repo_path
      ~base_path
      ~abs_path:(Filename.concat base_path rel)
  in
  check (option (pair string string)) "local sandbox path"
    (Some ("masc", "lib/foo.ml"))
    (parse ".masc/playground/alpha/repos/masc/lib/foo.ml");
  check (option (pair string string)) "docker sandbox path"
    (Some ("masc", "lib/foo.ml"))
    (parse ".masc/playground/docker/alpha/repos/masc/lib/foo.ml");
  check (option (pair string string)) "keeper named repos"
    (Some ("masc", "lib/foo.ml"))
    (parse ".masc/playground/repos/repos/masc/lib/foo.ml");
  check (option (pair string string)) "docker keeper named repos"
    (Some ("masc", "lib/foo.ml"))
    (parse ".masc/playground/docker/repos/repos/masc/lib/foo.ml");
  check (option (pair string string)) "nested repo-local pattern is not sandbox"
    None
    (parse "workspace/repo/.masc/playground/alpha/repos/masc/lib/foo.ml")

let test_parse_playground_file_path () =
  let base_path = "/tmp/masc-base" in
  let parse rel =
    PP.parse_playground_file_path
      ~base_path
      ~abs_path:(Filename.concat base_path rel)
  in
  let parsed keeper_name relative_path =
    Some PP.{ keeper_name; relative_path }
  in
  check bool "local playground artifact"
    true
    (parse ".masc/playground/omega/artifact.txt"
     = parsed "omega" "artifact.txt");
  check bool "docker playground artifact"
    true
    (parse ".masc/playground/docker/omega/artifact.txt"
     = parsed "omega" "artifact.txt");
  check bool "nested artifact"
    true
    (parse ".masc/playground/docker/omega/scratch/report.txt"
     = parsed "omega" "scratch/report.txt");
  check bool "outside playground rejected"
    true
    (parse "workspace/report.txt" = None);
  check bool "dot-dot segment rejected"
    true
    (parse ".masc/playground/omega/../other/secret.txt" = None);
  check bool "bundle root alone rejected"
    true
    (parse ".masc/playground/omega" = None)

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
      ]);
      ("security", [
        test_case "no path escape" `Quick test_no_path_escape;
      ]);
      ("canonical_normalize", [
        test_case "canonical stripped to short" `Quick test_strip_canonical_to_short;
        test_case "both forms produce identical paths" `Quick test_canonical_short_path_identity;
        test_case "edge cases" `Quick test_strip_edge_cases;
        test_case "strip does not create traversal" `Quick test_strip_no_traversal;
      ]);
      ("parse", [
        test_case "parse playground repo path" `Quick test_parse_playground_repo_path;
        test_case "parse playground file path" `Quick test_parse_playground_file_path;
      ]);
    ]
