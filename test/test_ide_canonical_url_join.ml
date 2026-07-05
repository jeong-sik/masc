(** RFC-0128 §6.3 integration test — sandbox keeper write at one
    clone of a repository joins, via canonical URL slug, with an IDE
    read at a different clone of the same upstream.

    Setup:
      base_dir/
        .masc/config/repositories.toml
          [repository.sandbox]   url=https://github.com/owner/repo
                                 local_path = base_dir/sandbox/repos/repo
          [repository.worktree]  url=git@github.com:owner/repo.git
                                 local_path = base_dir/workspace/repo
        sandbox/repos/repo/lib/foo.ml
        workspace/repo/lib/foo.ml

    Invariant: when the keeper "writes" inside the sandbox clone, the
    record must be retrievable when the IDE reads from the working
    tree clone — both must resolve to the same [By_url <slug>]
    partition. The repo URLs use different transports (HTTPS vs SSH)
    on purpose to also exercise the normalisation join test from
    {!Ide_paths.canonical_url_of_remote}. *)

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
  let path = Filename.temp_file "rfc0128-join" "" in
  Sys.remove path;
  Unix.mkdir path 0o755;
  Fun.protect ~finally:(fun () -> rm_rf path) (fun () -> f path)
;;

let rec mkdir_p path =
  if path = "" || path = "/" || (Sys.file_exists path && Sys.is_directory path)
  then ()
  else (
    mkdir_p (Filename.dirname path);
    try Unix.mkdir path 0o755 with
    | Unix.Unix_error (Unix.EEXIST, _, _) -> ())
;;

let touch path =
  mkdir_p (Filename.dirname path);
  let oc = open_out path in
  close_out oc
;;

let partition_to_string = function
  | Ide_paths.By_url slug -> "By_url " ^ slug
  | Ide_paths.No_canonical_url -> "No_canonical_url"
  | Ide_paths.Unmatched -> "Unmatched"
  | Ide_paths.Base_unresolved -> "Base_unresolved"
  | Ide_paths.Legacy_default -> "Legacy_default"
;;

let test_sandbox_write_joins_with_worktree_read () =
  with_temp_base_dir (fun base_dir ->
    (* 1. Build two clones of the same upstream. *)
    let sandbox_root = Filename.concat base_dir "sandbox/repos/repo" in
    let workspace_root = Filename.concat base_dir "workspace/repo" in
    mkdir_p sandbox_root;
    mkdir_p workspace_root;
    touch (Filename.concat sandbox_root "lib/foo.ml");
    touch (Filename.concat workspace_root "lib/foo.ml");
    (* 2. Register both in repositories.toml. Different transports on
       purpose so the canonical_url normalisation is also tested in
       the join path. *)
    let repo_https =
      { id = "sandbox"
      ; name = "sandbox"
      ; url = "https://github.com/owner/repo"
      ; local_path = sandbox_root
      ; aliases = []
      ; default_branch = "main"
      ; keepers = []
      ; status = Active
      ; auto_sync = false
      ; sync_interval = 0
      ; created_at = Int64.zero
      ; updated_at = Int64.zero
      }
    in
    let repo_ssh =
      { repo_https with
        id = "worktree"
      ; name = "worktree"
      ; url = "git@github.com:owner/repo.git"
      ; local_path = workspace_root
      }
    in
    (match Repo_store.save_all ~base_path:base_dir [ repo_https; repo_ssh ] with
     | Ok () -> ()
     | Error msg -> failf "save_all: %s" msg);
    (* 3. resolve_partition_for_write at a sandbox path. *)
    let sandbox_file = Filename.concat sandbox_root "lib/foo.ml" in
    let sandbox_partition, sandbox_rel =
      Masc.Keeper_tool_filesystem_runtime.resolve_partition_for_write
        ~base_dir
        ~kind:"region"
        ~file_path:sandbox_file
    in
    let worktree_file = Filename.concat workspace_root "lib/foo.ml" in
    let worktree_partition, worktree_rel =
      Masc.Keeper_tool_filesystem_runtime.resolve_partition_for_write
        ~base_dir
        ~kind:"region"
        ~file_path:worktree_file
    in
    (* 4. Invariant — both resolve to the same By_url slug. *)
    (match sandbox_partition, worktree_partition with
     | Ide_paths.By_url s1, Ide_paths.By_url s2 ->
       check string "join invariant — same slug" s1 s2
     | _ ->
       failf
         "expected By_url _ on both sides, got %s / %s"
         (match sandbox_partition with
          | Ide_paths.By_url s -> "By_url " ^ s
          | Ide_paths.No_canonical_url -> "No_canonical_url"
          | Ide_paths.Unmatched -> "Unmatched"
          | Ide_paths.Base_unresolved -> "Base_unresolved"
          | Ide_paths.Legacy_default -> "Legacy_default")
         (match worktree_partition with
          | Ide_paths.By_url s -> "By_url " ^ s
          | Ide_paths.No_canonical_url -> "No_canonical_url"
          | Ide_paths.Unmatched -> "Unmatched"
          | Ide_paths.Base_unresolved -> "Base_unresolved"
          | Ide_paths.Legacy_default -> "Legacy_default"));
    (* 5. rel_path is the repo-relative remainder in both cases. *)
    check string "sandbox rel_path stripped" "lib/foo.ml" sandbox_rel;
    check string "worktree rel_path stripped" "lib/foo.ml" worktree_rel)
;;

let test_unregistered_path_lands_in_base_unresolved () =
  with_temp_base_dir (fun base_dir ->
    (match Repo_store.save_all ~base_path:base_dir [] with
     | Ok () -> ()
     | Error msg -> failf "save_all: %s" msg);
    let elsewhere = Filename.concat base_dir "elsewhere/foo.ml" in
    let partition, original =
      Masc.Keeper_tool_filesystem_runtime.resolve_partition_for_write
        ~base_dir
        ~kind:"region"
        ~file_path:elsewhere
    in
    (match partition with
     | Ide_paths.Base_unresolved -> ()
     | got ->
       failf
         "expected Base_unresolved for unregistered path, got %s"
         (partition_to_string got));
    check string "rel_path passes through unchanged" elsewhere original)
;;

let test_blank_url_lands_in_no_canonical_url () =
  with_temp_base_dir (fun base_dir ->
    let local = Filename.concat base_dir "blank/repo" in
    mkdir_p local;
    let repo =
      { id = "blank"
      ; name = "blank"
      ; url = "" (* registered but no URL *)
      ; local_path = local
      ; aliases = []
      ; default_branch = "main"
      ; keepers = []
      ; status = Active
      ; auto_sync = false
      ; sync_interval = 0
      ; created_at = Int64.zero
      ; updated_at = Int64.zero
      }
    in
    (match Repo_store.save_all ~base_path:base_dir [ repo ] with
     | Ok () -> ()
     | Error msg -> failf "save_all: %s" msg);
    let file = Filename.concat local "lib/foo.ml" in
    let partition, _ =
      Masc.Keeper_tool_filesystem_runtime.resolve_partition_for_write
        ~base_dir
        ~kind:"region"
        ~file_path:file
    in
    match partition with
    | Ide_paths.No_canonical_url -> ()
    | got ->
      failf
        "expected No_canonical_url for blank-URL repo, got %s"
        (partition_to_string got))
;;

(* RFC-0128 PR-6 — sandbox playground path resolution. Keeper writes
   inside the sandbox land at [<base>/.masc/playground/<keeper>/repos/
   <repo_id>/<rel>], which is NOT a registered repo prefix. The
   resolver should still produce the same [By_url <slug>] as a write
   in the working-tree clone. *)
let test_sandbox_playground_path_joins_with_worktree () =
  with_temp_base_dir (fun base_dir ->
    (* Only register the working-tree clone; the sandbox playground
       has no entry in repositories.toml, which mirrors the real
       operating environment. *)
    let worktree = Filename.concat base_dir "workspace/repo" in
    mkdir_p worktree;
    touch (Filename.concat worktree "lib/foo.ml");
    let repo =
      { id = "masc"
      ; name = "masc"
      ; url = "https://github.com/owner/repo"
      ; local_path = worktree
      ; aliases = []
      ; default_branch = "main"
      ; keepers = []
      ; status = Active
      ; auto_sync = false
      ; sync_interval = 0
      ; created_at = Int64.zero
      ; updated_at = Int64.zero
      }
    in
    (match Repo_store.save_all ~base_path:base_dir [ repo ] with
     | Ok () -> ()
     | Error msg -> failf "save_all: %s" msg);
    let sandbox_file =
      Filename.concat
        base_dir
        ".masc/playground/sangsu/repos/masc/lib/foo.ml"
    in
    let worktree_file = Filename.concat worktree "lib/foo.ml" in
    let sandbox_partition, sandbox_rel =
      Masc.Keeper_tool_filesystem_runtime.resolve_partition_for_write
        ~base_dir
        ~kind:"region"
        ~file_path:sandbox_file
    in
    let worktree_partition, worktree_rel =
      Masc.Keeper_tool_filesystem_runtime.resolve_partition_for_write
        ~base_dir
        ~kind:"region"
        ~file_path:worktree_file
    in
    (match sandbox_partition, worktree_partition with
     | Ide_paths.By_url s1, Ide_paths.By_url s2 ->
       check string "sandbox / working-tree join via canonical_url" s1 s2
     | _ ->
       failf
         "expected By_url _ on both sides, got %s / %s"
         (match sandbox_partition with
          | Ide_paths.By_url s -> "By_url " ^ s
          | Ide_paths.No_canonical_url -> "No_canonical_url"
          | Ide_paths.Unmatched -> "Unmatched"
          | Ide_paths.Base_unresolved -> "Base_unresolved"
          | Ide_paths.Legacy_default -> "Legacy_default")
         (match worktree_partition with
          | Ide_paths.By_url s -> "By_url " ^ s
          | Ide_paths.No_canonical_url -> "No_canonical_url"
          | Ide_paths.Unmatched -> "Unmatched"
          | Ide_paths.Base_unresolved -> "Base_unresolved"
          | Ide_paths.Legacy_default -> "Legacy_default"));
    check string "sandbox rel stripped to repo-relative" "lib/foo.ml" sandbox_rel;
    check string "worktree rel stripped" "lib/foo.ml" worktree_rel)
;;

let test_docker_playground_path_also_resolves () =
  with_temp_base_dir (fun base_dir ->
    let worktree = Filename.concat base_dir "workspace/repo" in
    mkdir_p worktree;
    let repo =
      { id = "masc"
      ; name = "masc"
      ; url = "https://github.com/owner/repo"
      ; local_path = worktree
      ; aliases = []
      ; default_branch = "main"
      ; keepers = []
      ; status = Active
      ; auto_sync = false
      ; sync_interval = 0
      ; created_at = Int64.zero
      ; updated_at = Int64.zero
      }
    in
    (match Repo_store.save_all ~base_path:base_dir [ repo ] with
     | Ok () -> ()
     | Error msg -> failf "save_all: %s" msg);
    let docker_file =
      Filename.concat
        base_dir
        ".masc/playground/docker/tech_glutton/repos/masc/lib/foo.ml"
    in
    let partition, rel =
      Masc.Keeper_tool_filesystem_runtime.resolve_partition_for_write
        ~base_dir
        ~kind:"region"
        ~file_path:docker_file
    in
    match partition with
    | Ide_paths.By_url _ ->
      check string "docker sandbox rel" "lib/foo.ml" rel
    | _ -> fail "Docker sandbox path should resolve via repo_id lookup")
;;

let () =
  run
    "ide_canonical_url_join"
    [ ( "RFC-0128 §6.3"
      , [ test_case
            "sandbox write joins with working-tree read"
            `Quick
            test_sandbox_write_joins_with_worktree_read
        ; test_case
            "unregistered path → Base_unresolved"
            `Quick
            test_unregistered_path_lands_in_base_unresolved
        ; test_case
            "blank URL → No_canonical_url"
            `Quick
            test_blank_url_lands_in_no_canonical_url
        ; test_case
            "sandbox playground path joins with working-tree (PR-6)"
            `Quick
            test_sandbox_playground_path_joins_with_worktree
        ; test_case
            "docker playground path resolves via repo_id (PR-6)"
            `Quick
            test_docker_playground_path_also_resolves
        ] )
    ]
;;
