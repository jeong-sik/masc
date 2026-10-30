(* A removed keeper's worktrees are reclaimed at shutdown finalization by
   name: only what [git worktree list --porcelain] of the keeper's clones
   names, contained to the keeper's bundle by realpath on both sides, through
   [git worktree remove --force]. These pin the porcelain reading,
   the containment and the commands sent, with an injected [run_argv]. *)

open Alcotest
module W = Masc.Keeper_bundle_worktrees

let sorted = List.sort String.compare

let make_temp_dir prefix =
  (* No [Unix.mkdtemp] in this toolchain; same shape as the other suites. *)
  let dir = Filename.temp_file prefix "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  dir

let rec remove_tree path =
  try
    match (Unix.lstat path).st_kind with
    | Unix.S_DIR ->
      Array.iter
        (fun entry ->
           if not (String.equal entry "." || String.equal entry "..")
           then remove_tree (Filename.concat path entry))
        (Sys.readdir path);
      Unix.rmdir path
    | Unix.S_REG | Unix.S_LNK | Unix.S_CHR | Unix.S_BLK | Unix.S_FIFO | Unix.S_SOCK ->
      Sys.remove path
  with Sys_error _ | Unix.Unix_error _ -> ()

(* ── Porcelain ──────────────────────────────────────────────────────── *)

let repo_path = "/base/.masc/playground/gone/repos/app"

let porcelain_main = "worktree " ^ repo_path
let porcelain_linked = "worktree /base/.masc/playground/gone/app-wt"

let test_porcelain_keeps_linked_worktrees_only () =
  let raw =
    String.concat "\n"
      [ porcelain_main
      ; "HEAD 0123456789abcdef0123456789abcdef01234567"
      ; "branch refs/heads/main"
      ; ""
      ; porcelain_linked
      ; "HEAD fedcba9876543210fedcba9876543210fedcba98"
      ; "detached"
      ; ""
      ]
  in
  check (result (list string) string) "the clone's own checkout is not a target"
    (Ok [ "/base/.masc/playground/gone/app-wt" ])
    (W.worktree_paths_of_porcelain ~repo_path raw)

let test_porcelain_excludes_symlinked_main_checkout () =
  let bundle_root = make_temp_dir "masc-wt-symlink" in
  let real_repos = Filename.concat bundle_root "real-repos" in
  Unix.mkdir real_repos 0o755;
  let real_repo = Filename.concat real_repos "app" in
  Unix.mkdir real_repo 0o755;
  let linked_repos = Filename.concat bundle_root "repos" in
  Unix.symlink real_repos linked_repos;
  let symlink_repo = Filename.concat linked_repos "app" in
  let wt_clean = Filename.concat bundle_root "app-wt" in
  Unix.mkdir wt_clean 0o755;
  Fun.protect
    ~finally:(fun () -> remove_tree bundle_root)
    (fun () ->
       let raw =
         String.concat "\n"
           [ "worktree " ^ Unix.realpath real_repo
           ; "HEAD 0123456789abcdef0123456789abcdef01234567"
           ; "branch refs/heads/main"
           ; ""
           ; "worktree " ^ wt_clean
           ; "HEAD fedcba9876543210fedcba9876543210fedcba98"
           ; "detached"
           ; ""
           ]
       in
       check (result (list string) string)
         "canonical main checkout is excluded even when repo_path crosses a symlink"
         (Ok [ wt_clean ])
         (W.worktree_paths_of_porcelain ~repo_path:symlink_repo raw))

let test_porcelain_rejects_what_it_cannot_read () =
  check bool "empty output names nothing to remove" true
    (match W.worktree_paths_of_porcelain ~repo_path "" with
     | Error _ -> true
     | Ok _ -> false);
  check bool "a block without a worktree line rejects the snapshot" true
    (match
       W.worktree_paths_of_porcelain ~repo_path "HEAD 0123\n\nworktree /x\n\n"
     with
     | Error _ -> true
     | Ok _ -> false)

(* ── Containment ──────────────────────────────────────────────────── *)

let test_within_bundle_resolves_both_sides () =
  let bundle_root = make_temp_dir "masc-wt-bundle" in
  let inside = Filename.concat bundle_root "app-wt" in
  Unix.mkdir inside 0o755;
  let outside = make_temp_dir "masc-wt-outside" in
  check (result unit string) "a path inside the bundle is owned"
    (Ok ())
    (W.within_bundle ~bundle_root inside);
  check (result unit string) "the bundle root itself is owned"
    (Ok ())
    (W.within_bundle ~bundle_root bundle_root);
  check bool "a sibling directory is foreign" true
    (match W.within_bundle ~bundle_root outside with
     | Error _ -> true
     | Ok () -> false);
  check bool "an unresolvable path counts as foreign" true
    (match W.within_bundle ~bundle_root (Filename.concat bundle_root "nope") with
     | Error _ -> true
     | Ok () -> false);
  remove_tree bundle_root;
  remove_tree outside

(* ── Execution against a stubbed runner ─────────────────────────────── *)

let with_repo_dirs f =
  let bundle_root = make_temp_dir "masc-wt-bundle" in
  let repos_dir = Filename.concat bundle_root "repos" in
  Unix.mkdir repos_dir 0o755;
  let repo_path = Filename.concat repos_dir "app" in
  Unix.mkdir repo_path 0o755;
  let wt_clean = Filename.concat bundle_root "app-wt" in
  Unix.mkdir wt_clean 0o755;
  let wt_locked = Filename.concat bundle_root "app-wt2" in
  Unix.mkdir wt_locked 0o755;
  Fun.protect
    ~finally:(fun () -> remove_tree bundle_root)
    (fun () -> f ~bundle_root ~repo_path ~wt_clean ~wt_locked)

let test_prune_removes_only_porcelain_named_worktrees () =
  with_repo_dirs (fun ~bundle_root ~repo_path ~wt_clean ~wt_locked ->
    let calls = ref [] in
    let run_argv ~timeout_sec:_ argv =
      calls := argv :: !calls;
      match argv with
      | [ _; _; _; _; _; "worktree"; "list"; _ ] ->
        Unix.WEXITED 0
      , String.concat "\n"
          [ "worktree " ^ repo_path; "HEAD abc"; ""
          ; "worktree " ^ wt_clean; "HEAD def"; ""
          ; "worktree " ^ wt_locked; "HEAD 123"; ""
          ]
      | [ _; _; _; _; _; "worktree"; "remove"; "--force"; path ] when String.equal path wt_locked ->
        (* a single --force still refuses a locked worktree; the failure is
           recorded and the remaining removals still run *)
        Unix.WEXITED 128, Printf.sprintf "fatal: cannot remove a locked working tree: '%s'" path
      | _ -> Unix.WEXITED 0, ""
    in
    let outcome =
      W.prune_repo_worktrees ~run_argv ~timeout_sec:1.0 ~repo_path ~bundle_root
    in
    check (list string) "the clean linked worktree is removed"
      [ wt_clean ]
      outcome.W.removed;
    check (list string) "the locked one is reported, not unlocked"
      [ wt_locked ]
      (List.map fst outcome.W.failed);
    check string "nothing was skipped" "" outcome.W.skipped;
    let removed_paths =
      List.filter_map
        (function
          | [ _; _; _; _; _; "worktree"; "remove"; "--force"; path ] -> Some path
          | _ -> None)
        !calls
    in
    check (list string) "remove argv named exactly the porcelain paths, the \
                         main checkout never"
      [ wt_clean; wt_locked ]
      (sorted removed_paths))

let test_prune_leaves_foreign_worktrees_untouched () =
  with_repo_dirs (fun ~bundle_root ~repo_path ~wt_clean ~wt_locked:_ ->
    let outside = make_temp_dir "masc-wt-outside" in
    Fun.protect
      ~finally:(fun () -> remove_tree outside)
      (fun () ->
         let calls = ref [] in
         let run_argv ~timeout_sec:_ argv =
           calls := argv :: !calls;
           match argv with
           | [ _; _; _; _; _; "worktree"; "list"; _ ] ->
             Unix.WEXITED 0
           , String.concat "\n"
               [ "worktree " ^ repo_path; "HEAD abc"; ""
               ; "worktree " ^ wt_clean; "HEAD def"; ""
               ; "worktree " ^ outside; "HEAD 123"; ""
               ]
           | _ -> Unix.WEXITED 0, ""
         in
         let outcome =
           W.prune_repo_worktrees ~run_argv ~timeout_sec:1.0 ~repo_path
             ~bundle_root
         in
         check (list string) "the owned worktree is removed"
           [ wt_clean ]
           outcome.W.removed;
         check bool "the foreign path is reported as skipped" true
           (let needle = "outside the bundle" in
            let skipped = outcome.W.skipped in
            let found = ref false in
            let max_start = String.length skipped - String.length needle in
            for start = 0 to max_start do
              if String.sub skipped start (String.length needle) = needle
              then found := true
            done;
            !found);
         let removed_paths =
           List.filter_map
             (function
               | [ _; _; _; _; _; "worktree"; "remove"; "--force"; path ] -> Some path
               | _ -> None)
             !calls
         in
         check (list string) "remove argv never named the foreign path"
           [ wt_clean ]
           removed_paths))

let test_prune_skips_repo_when_listing_is_unreadable () =
  let calls = ref [] in
  let run_argv ~timeout_sec:_ argv =
    calls := argv :: !calls;
    Unix.WEXITED 128, "fatal: not a git repository"
  in
  let outcome =
    W.prune_repo_worktrees ~run_argv ~timeout_sec:1.0 ~repo_path
      ~bundle_root:"/nonexistent-bundle-root"
  in
  check (list string) "nothing removed" [] outcome.W.removed;
  check int "nothing failed" 0 (List.length outcome.W.failed);
  check bool "the skip names the fault" true
    (String.length outcome.W.skipped > 0);
  check (list (list string)) "no removal was attempted"
    [ W.worktree_list_argv ~repo_path ]
    !calls

(* The bundle is the one the keeper's profile places, so a Docker keeper's
   clones under [playground/docker/<keeper>] are walked and a neighbour's
   bundle is never listed. A bundle without [repos] sends nothing. *)
let test_removal_walks_only_the_dissolved_keepers_bundle () =
  let base_path = make_temp_dir "masc-wt-base" in
  Fun.protect
    ~finally:(fun () -> remove_tree base_path)
    (fun () ->
       let bundle keeper_name profile =
         Filename.concat
           base_path
           (Keeper_sandbox_config.host_root_rel_of_profile profile keeper_name)
       in
       let rec mkdir_p path =
         if not (Sys.file_exists path)
         then (
           mkdir_p (Filename.dirname path);
           Unix.mkdir path 0o755)
       in
       let gone_repo =
         Filename.concat (bundle "gone" Keeper_sandbox_config.Docker) "repos/app"
       in
       let gone_worktree =
         Filename.concat (bundle "gone" Keeper_sandbox_config.Docker) "app-wt"
       in
       let neighbour_repo =
         Filename.concat (bundle "alive" Keeper_sandbox_config.Docker) "repos/app"
       in
       List.iter mkdir_p [ gone_repo; gone_worktree; neighbour_repo ];
       let calls = ref [] in
       let run_argv ~timeout_sec:_ argv =
         calls := argv :: !calls;
         match argv with
         | [ _; _; _; _; repo; "worktree"; "list"; _ ] ->
           ( Unix.WEXITED 0
           , String.concat
               "\n"
               [ "worktree " ^ repo; "HEAD abc"; ""; "worktree " ^ gone_worktree; "HEAD def"; "" ] )
         | _ -> Unix.WEXITED 0, ""
       in
       let outcomes =
         W.remove_keeper_worktrees
           ~run_argv
           ~timeout_sec:1.0
           ~base_path
           ~keeper_name:"gone"
           ~profile:Keeper_sandbox_config.Docker
       in
       check (list string) "the dissolved keeper's clone is the one walked"
         [ gone_repo ]
         (List.map fst outcomes);
       check (list string) "its linked worktree is removed"
         [ gone_worktree ]
         (List.concat_map (fun (_, outcome) -> outcome.W.removed) outcomes);
       check bool "the neighbour's clone is never listed" false
         (List.exists
            (fun argv -> List.exists (String.equal neighbour_repo) argv)
            !calls);
       calls := [];
       check int "a bundle without repos has nothing to remove" 0
         (List.length
            (W.remove_keeper_worktrees
               ~run_argv
               ~timeout_sec:1.0
               ~base_path
               ~keeper_name:"gone"
               ~profile:Keeper_sandbox_config.Micro_vm));
       check int "and sends no command" 0 (List.length !calls))

let test_argv_spellings () =
  check (list string) "list goes through git -C with porcelain"
    [ "git"; "-c"; "core.fsmonitor=false"; "-C"; repo_path; "worktree"; "list"
    ; "--porcelain" ]
    (W.worktree_list_argv ~repo_path);
  (* Without --force git runs [git status] in the worktree to prove it clean,
     and that child executes the clone's own filter.<name>.clean/.process
     commands. --force skips the status check, so the host never evaluates
     the keeper's repo configuration on removal. *)
  check (list string) "remove is forced, so git never runs status in the worktree"
    [ "git"; "-c"; "core.fsmonitor=false"; "-C"; repo_path; "worktree"; "remove"
    ; "--force"; "/base/.masc/playground/gone/app-wt" ]
    (W.worktree_remove_argv ~repo_path
       ~worktree_path:"/base/.masc/playground/gone/app-wt")

let () =
  Alcotest.run "keeper_bundle_worktrees"
    [ ( "porcelain"
      , [ test_case "linked worktrees only, main checkout excluded" `Quick
            test_porcelain_keeps_linked_worktrees_only
        ; test_case "symlinked repo_path still excludes canonical main checkout" `Quick
            test_porcelain_excludes_symlinked_main_checkout
        ; test_case "unreadable porcelain removes nothing" `Quick
            test_porcelain_rejects_what_it_cannot_read
        ] )
    ; ( "containment"
      , [ test_case "realpath containment, unresolvable is foreign" `Quick
            test_within_bundle_resolves_both_sides
        ] )
    ; ( "prune"
      , [ test_case "removes only porcelain-named worktrees" `Quick
            test_prune_removes_only_porcelain_named_worktrees
        ; test_case "foreign worktrees are skipped, never removed" `Quick
            test_prune_leaves_foreign_worktrees_untouched
        ; test_case "an unreadable listing skips the repo" `Quick
            test_prune_skips_repo_when_listing_is_unreadable
        ; test_case "removal walks only the dissolved keeper's bundle" `Quick
            test_removal_walks_only_the_dissolved_keepers_bundle
        ; test_case "argv spellings" `Quick
            test_argv_spellings
        ] )
    ]
;;
