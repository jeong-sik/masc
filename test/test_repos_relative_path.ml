(** [repos_relative_path] must stay relative, and resolve to [repos_dir].

    [Repo_manager_types.repository.local_path] is stored relative:
    [Repo_store.local_path ~base_path repo] returns
    [Filename.concat base_path repo.local_path]. So the default the HTTP
    repository constructor writes into that field has to be relative too —
    handing it {!Config_dir_resolver.repos_dir}, which is absolute, would
    resolve the base path twice.

    The constructor used to build ".masc/repos/<id>" inline. The RFC-0121
    audit did not report it: .ci/path-ssot-allowlist.txt carried the pattern
    as an entry with no file anchor, and the audit matches allowlist lines as
    substrings of the whole rg output line, so that one suppressed the pattern
    everywhere it appeared. *)

open Alcotest

let test_is_relative () =
  let path = Config_dir_resolver.repos_relative_path ~id:"repo-1" in
  check string "the stored default" ".masc/repos/repo-1" path;
  check bool "not absolute" false (Filename.is_relative path = false)
;;

(* The property that matters: resolving it once lands on the managed checkout
   directory. Swapping in the absolute accessor breaks this, which is the
   mistake the relative form exists to prevent. *)
let test_resolves_onto_repos_dir () =
  let base_path = "/srv/masc-base" in
  let id = "repo-1" in
  check
    string
    "base_path + relative default == repos_dir + id"
    (Filename.concat (Config_dir_resolver.repos_dir ~base_path) id)
    (Filename.concat base_path (Config_dir_resolver.repos_relative_path ~id))
;;

(* The directory segment is named once. If repos_dir stopped agreeing with the
   relative form, a reader and a writer would disagree about where checkouts
   live. *)
let test_one_directory_name () =
  let base_path = "/srv/masc-base" in
  check
    bool
    "the relative form is a suffix of the absolute one"
    true
    (let absolute = Config_dir_resolver.repos_dir ~base_path in
     let relative = Config_dir_resolver.repos_relative_path ~id:"x" in
     let parent = Filename.dirname relative in
     String.length absolute >= String.length parent
     && String.equal
          (String.sub absolute (String.length absolute - String.length parent) (String.length parent))
          parent)
;;

let () =
  run
    "repos relative path"
    [ ( "config_dir_resolver"
      , [ test_case "stays relative" `Quick test_is_relative
        ; test_case "resolves onto repos_dir" `Quick test_resolves_onto_repos_dir
        ; test_case "one directory name" `Quick test_one_directory_name
        ] )
    ]
;;
