(** Write attribution by git remote, behind MASC_KEEPER_ATTRIBUTION_BY_GIT.

    The default path reverse-parses [.masc/playground/<keeper>/repos/<id>/<rel>]
    to recover which repository a keeper wrote to. That only answers for paths
    matching the layout the system used to prescribe; a checkout the keeper put
    anywhere else falls through to [Base_unresolved].

    The flagged path asks git instead. These cases pin what it must and must
    not do — in particular that it stays inside keeper playgrounds, because one
    caller passes the workspace base path once per turn. *)

open Alcotest
open Repo_manager_types

let rec rm_rf path =
  if Sys.file_exists path
  then
    if Sys.is_directory path
    then (
      Sys.readdir path |> Array.iter (fun name -> rm_rf (Filename.concat path name));
      Unix.rmdir path)
    else Sys.remove path
;;

let with_temp_base_dir f =
  let path = Filename.temp_file "attribution-by-git" "" in
  Sys.remove path;
  Unix.mkdir path 0o755;
  Fun.protect ~finally:(fun () -> rm_rf path) (fun () -> f path)
;;

let with_flag value f =
  let key = "MASC_KEEPER_ATTRIBUTION_BY_GIT" in
  let previous = Sys.getenv_opt key in
  Unix.putenv key (if value then "true" else "false");
  Fun.protect
    ~finally:(fun () ->
      match previous with
      | Some v -> Unix.putenv key v
      | None -> Unix.putenv key "false")
    f
;;

let git_or_fail ~cwd args =
  match Repo_git.run_git ~cwd args with
  | Ok lines -> lines
  | Error error -> failf "git %s failed: %s" (String.concat " " args) error
;;

let write_file path contents =
  Fs_compat.mkdir_p (Filename.dirname path);
  let oc = open_out path in
  Fun.protect ~finally:(fun () -> close_out_noerr oc) (fun () -> output_string oc contents)
;;

(** A real checkout: git needs to answer rev-parse and remote get-url. *)
let make_checkout ~origin dir =
  Fs_compat.mkdir_p dir;
  ignore (git_or_fail ~cwd:dir [ "init"; "-b"; "fixture" ]);
  ignore (git_or_fail ~cwd:dir [ "remote"; "add"; "origin"; origin ])
;;

let seed_catalog ~base_dir repos =
  match Repo_store.save_all ~base_path:base_dir repos with
  | Ok () -> ()
  | Error e -> failf "failed to seed catalog: %s" e
;;

let repo ~id ~url ~local_path =
  { id
  ; name = id
  ; url
  ; local_path
  ; aliases = []
  ; default_branch = "main"
  ; keepers = []
  ; status = Active
  ; auto_sync = false
  ; sync_interval = 0
  ; created_at = Int64.zero
  ; updated_at = Int64.zero
  }
;;

let partition_label = function
  | Agent_observation.By_url slug -> "by_url:" ^ slug
  | Agent_observation.No_canonical_url -> "no_canonical_url"
  | Agent_observation.Unmatched -> "unmatched"
  | Agent_observation.Base_unresolved -> "base_unresolved"
  | Agent_observation.Legacy_default -> "legacy_default"
;;

let resolve ~base_dir ~file_path =
  Masc.Keeper_tool_filesystem_runtime.resolve_partition_for_write
    ~base_dir
    ~kind:"region"
    ~file_path
;;

let playground_checkout ~base_dir ~keeper ~rel =
  Filename.concat
    base_dir
    (Filename.concat (Filename.concat ".masc/playground" keeper) rel)
;;

(* ------------------------------------------------------------------ *)

(* A checkout outside repos/ is invisible to the reverse-parse. Measured live:
   code-reviewer/.masc/repos/vp-tempo-cli, kidsnote/.tmp/task136-fix. *)
let test_finds_checkout_the_reverse_parse_cannot_see () =
  with_temp_base_dir (fun base_dir ->
    let checkout = playground_checkout ~base_dir ~keeper:"tester" ~rel:"work/masc" in
    make_checkout ~origin:"https://github.com/owner/masc.git" checkout;
    let file = Filename.concat checkout "lib/foo.ml" in
    write_file file "let x = 1\n";
    with_flag false (fun () ->
      let partition, _ = resolve ~base_dir ~file_path:file in
      check string "unflagged path cannot attribute it" "base_unresolved"
        (partition_label partition));
    with_flag true (fun () ->
      let partition, rel = resolve ~base_dir ~file_path:file in
      check string "git attributes it by origin"
        "by_url:github.com_owner_masc"
        (partition_label partition);
      check string "path is relative to the checkout root" "lib/foo.ml" rel))
;;

(* The legacy layout must keep working — this is what makes the flag safe to
   turn on without moving anything. *)
let test_legacy_repos_layout_still_attributes () =
  with_temp_base_dir (fun base_dir ->
    let checkout = playground_checkout ~base_dir ~keeper:"tester" ~rel:"repos/masc" in
    make_checkout ~origin:"https://github.com/owner/masc.git" checkout;
    let file = Filename.concat checkout "lib/foo.ml" in
    write_file file "let x = 1\n";
    seed_catalog
      ~base_dir
      [ repo ~id:"masc" ~url:"https://github.com/owner/masc.git" ~local_path:checkout ];
    with_flag true (fun () ->
      let partition, rel = resolve ~base_dir ~file_path:file in
      check string "same bucket as the reverse-parse would give"
        "by_url:github.com_owner_masc"
        (partition_label partition);
      check string "relative path" "lib/foo.ml" rel))
;;

(* keeper_agent_run.ml passes config.base_path once per turn. Running
   worktree_root on that resolves to whatever repository contains the base
   path, which would silently re-bucket every turn event. *)
let test_paths_outside_a_playground_are_left_alone () =
  with_temp_base_dir (fun base_dir ->
    (* Make the base path itself a checkout, which is the situation that makes
       this dangerous: a masc workspace sitting inside a git repository. *)
    make_checkout ~origin:"https://github.com/owner/outer.git" base_dir;
    with_flag true (fun () ->
      let partition, _ = resolve ~base_dir ~file_path:base_dir in
      check bool "the containing repository is not adopted" false
        (String.equal (partition_label partition) "by_url:github.com_owner_outer")))
;;

(* A checkout cloned from another local checkout has a filesystem path as its
   origin. canonical_url_of_remote rejects it, but the catalog can still name
   it. Measured live: code-reviewer/repos/masc/review-pr-28304. *)
let test_local_path_origin_falls_back_to_the_catalog () =
  with_temp_base_dir (fun base_dir ->
    let upstream = Filename.concat base_dir "operator/masc" in
    make_checkout ~origin:"https://github.com/owner/masc.git" upstream;
    seed_catalog
      ~base_dir
      [ repo ~id:"masc" ~url:"https://github.com/owner/masc.git" ~local_path:upstream ];
    let checkout =
      playground_checkout ~base_dir ~keeper:"tester" ~rel:"repos/masc-review"
    in
    make_checkout ~origin:upstream checkout;
    let file = Filename.concat checkout "lib/foo.ml" in
    write_file file "let x = 1\n";
    with_flag true (fun () ->
      let partition, _ = resolve ~base_dir ~file_path:file in
      check string "local-path origin resolves through the catalog"
        "by_url:github.com_owner_masc"
        (partition_label partition)))
;;

(* Not a checkout at all: git has no answer, and the reverse-parse would be
   guessing at a layout the system no longer creates. *)
let test_non_checkout_inside_a_playground_is_unresolved () =
  with_temp_base_dir (fun base_dir ->
    let dir = playground_checkout ~base_dir ~keeper:"tester" ~rel:"notes" in
    let file = Filename.concat dir "todo.md" in
    write_file file "- item\n";
    with_flag true (fun () ->
      let partition, _ = resolve ~base_dir ~file_path:file in
      check string "reported, not bucketed" "base_unresolved"
        (partition_label partition)))
;;

let () =
  run
    "keeper_attribution_by_git"
    [ ( "measurement"
      , [ test_case "finds a checkout the reverse-parse cannot see" `Quick
            test_finds_checkout_the_reverse_parse_cannot_see
        ; test_case "legacy repos/ layout still attributes" `Quick
            test_legacy_repos_layout_still_attributes
        ; test_case "local-path origin falls back to the catalog" `Quick
            test_local_path_origin_falls_back_to_the_catalog
        ] )
    ; ( "boundaries"
      , [ test_case "paths outside a playground are left alone" `Quick
            test_paths_outside_a_playground_are_left_alone
        ; test_case "non-checkout inside a playground is unresolved" `Quick
            test_non_checkout_inside_a_playground_is_unresolved
        ] )
    ]
;;
