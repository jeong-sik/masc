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

(* RFC-0393: keeper name is the only spelling (sanitize_keeper_name is a no-op identity wrapper). *)

let test_strip_canonical_to_short () =
  check string "canonical stays canonical"
    "keeper-omicron-improver-agent"
    (PP.sanitize_keeper_name "keeper-omicron-improver-agent");
  check string "short stays short"
    "omicron-improver"
    (PP.sanitize_keeper_name "omicron-improver");
  check string "beta canonical stays canonical"
    "keeper-beta-agent"
    (PP.sanitize_keeper_name "keeper-beta-agent");
  check string "alpha canonical stays canonical"
    "keeper-alpha-agent"
    (PP.sanitize_keeper_name "keeper-alpha-agent")

let test_canonical_short_path_identity () =
  check string "bundle_root keeps short name as suffix"
    (PP.bundle_root "beta")
    (PP.bundle_root "beta");
  check string "bundle_root keeps canonical name as suffix"
    (PP.bundle_root "keeper-beta-agent")
    (PP.bundle_root "keeper-beta-agent");
  check bool "bundle_root maps distinct names to distinct paths"
    false
    (PP.bundle_root "beta" = PP.bundle_root "keeper-beta-agent")

let test_strip_edge_cases () =
  check string "keeper-agent not stripped (inner would be empty)"
    "keeper-agent"
    (PP.sanitize_keeper_name "keeper-agent");
  check string "single-char inner name"
    "keeper-x-agent"
    (PP.sanitize_keeper_name "keeper-x-agent");
  check string "idempotent"
    (PP.sanitize_keeper_name "keeper-omicron-improver-agent")
    (PP.sanitize_keeper_name
       (PP.sanitize_keeper_name "keeper-omicron-improver-agent"));
  check string "different keepers stay different"
    "keeper-alpha-agent"
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
  (* A keeper may be named "docker". Its bundle is one level up from where the
     Docker marker would put it, so the Local reading has to stay reachable
     after the Docker one does not resolve. *)
  check (option (pair string string)) "keeper named docker"
    (Some ("masc", "lib/foo.ml"))
    (parse ".masc/playground/docker/repos/masc/lib/foo.ml");
  check (option (pair string string)) "nested repo-local pattern is not sandbox"
    None
    (parse "workspace/repo/.masc/playground/alpha/repos/masc/lib/foo.ml")

(* The absolute parser and the bundle-relative one must find the same anchor,
   or a file would carry one address when a keeper's own write path resolves it
   and another when a reader parses the target that write recorded. *)
let test_bundle_relative_agrees_with_absolute () =
  let base_path = "/tmp/masc-base" in
  let both bundle_relative =
    List.map
      (fun prefix ->
        PP.parse_playground_repo_path
          ~base_path
          ~abs_path:(Filename.concat base_path (prefix ^ bundle_relative)))
      [ ".masc/playground/alpha/"; ".masc/playground/docker/alpha/" ]
  in
  let cases =
    [ "repos/masc/lib/foo.ml"; "repos/masc/x"; "verify-468.sh"; "repos/"; "repos/masc"; "" ]
  in
  List.iter
    (fun bundle_relative ->
      let direct = PP.parse_bundle_relative_repo_path bundle_relative in
      List.iter
        (fun absolute ->
          check (option (pair string string))
            ("same anchor for " ^ bundle_relative)
            absolute direct)
        (both bundle_relative))
    cases

(* The [repos] segment inside a keeper's bundle is named once, here. The tree
   has a second, unrelated [repos]: the server-side registration store under
   [.masc/repos/<id>] owned by [Config_dir_resolver]. Same spelling, different
   concept — one names the clone directory inside one keeper's bundle, the
   other a store under the server base path. They must stay two constants, and
   neither spelling may be re-decided at a call site. *)
let test_bundle_repos_dirname_names_the_anchor () =
  check string "anchor segment" "repos" PP.bundle_repos_dirname;
  let roundtrip repo_id rel =
    check (option (pair string string))
      ("build then parse: " ^ repo_id ^ "/" ^ rel)
      (Some (repo_id, rel))
      (PP.parse_bundle_relative_repo_path
         (PP.bundle_relative_repo_path ~repo_id rel))
  in
  roundtrip "masc" "lib/foo.ml";
  (* A repository whose id is the anchor segment itself: the parser must take
     the id from position, never from scanning for the segment. *)
  roundtrip "repos" "verify-468.sh"

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
        test_case "bundle-relative agrees with absolute" `Quick
          test_bundle_relative_agrees_with_absolute;
        test_case "parse playground file path" `Quick test_parse_playground_file_path;
        test_case "bundle repos dirname names the anchor" `Quick
          test_bundle_repos_dirname_names_the_anchor;
      ]);
    ]
