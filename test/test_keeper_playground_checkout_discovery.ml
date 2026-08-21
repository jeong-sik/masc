(** Tests for [Keeper_playground_checkouts.discover].

    Each case pins one decision from RFC-keeper-workspace-root-only. The
    fixtures are shaped after the live playground measured on 2026-08-13, not
    after the layout the system used to prescribe. *)

open Alcotest
module C = Masc.Keeper_playground_checkouts

let rec rm_rf path =
  if Sys.file_exists path
  then
    if Sys.is_directory path
    then (
      Sys.readdir path |> Array.iter (fun n -> rm_rf (Filename.concat path n));
      Unix.rmdir path)
    else Sys.remove path
;;

let mkdir_p path =
  let rec go path =
    if not (Sys.file_exists path)
    then (
      go (Filename.dirname path);
      Unix.mkdir path 0o755)
  in
  go path
;;

let write_file path contents =
  mkdir_p (Filename.dirname path);
  let oc = open_out path in
  output_string oc contents;
  close_out oc
;;

(** A primary checkout: [<dir>/.git] is a directory. *)
let make_checkout root rel = mkdir_p (Filename.concat (Filename.concat root rel) ".git")

(** A linked worktree: [<dir>/.git] is a regular file holding a gitdir pointer. *)
let make_worktree root rel =
  let dir = Filename.concat root rel in
  mkdir_p dir;
  write_file (Filename.concat dir ".git") "gitdir: /somewhere/.git/worktrees/x\n"
;;

let with_temp_root f =
  let dir = Filename.temp_file "keeper-checkout-discovery-" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  Fun.protect ~finally:(fun () -> try rm_rf dir with _ -> ()) (fun () -> f dir)
;;

let paths_of result =
  match result with
  | Ok (C.Complete cs) -> List.map (fun (c : C.checkout) -> c.relative_path) cs
  | Ok (C.Partial { found; _ }) ->
    List.map (fun (c : C.checkout) -> c.relative_path) found
  | Error e -> [ "<error: " ^ C.scan_error_to_string e ^ ">" ]
;;

let check_paths msg expected result = check (list string) msg expected (paths_of result)

(* ------------------------------------------------------------------ *)
(* Discovery shape                                                     *)
(* ------------------------------------------------------------------ *)

(* The old layout must keep working: this is what makes the change need no
   migration. *)
let test_finds_legacy_repos_layout () =
  with_temp_root (fun root ->
    make_checkout root "repos/masc";
    check_paths "repos/masc is still found" [ "repos/masc" ] (C.discover ~root))
;;

let test_finds_checkout_directly_under_root () =
  with_temp_root (fun root ->
    make_checkout root "masc";
    check_paths "a checkout one level down is found" [ "masc" ] (C.discover ~root))
;;

(* A keeper that clones straight into its workspace root would otherwise be a
   blind spot. *)
let test_root_itself_is_a_checkout () =
  with_temp_root (fun root ->
    mkdir_p (Filename.concat root ".git");
    make_checkout root "nested/other";
    check_paths "root reports as \".\" and nothing below is scanned" [ "." ]
      (C.discover ~root))
;;

(* Measured live: two live Keepers both put checkouts under a
   dot-directory. A scan that skips hidden names loses them. *)
let test_finds_checkout_under_hidden_directory () =
  with_temp_root (fun root ->
    make_checkout root ".masc/repos/vp-tempo-cli";
    check_paths "hidden directories are traversed"
      [ ".masc/repos/vp-tempo-cli" ]
      (C.discover ~root))
;;

let test_finds_worktree_with_gitdir_file () =
  with_temp_root (fun root ->
    make_worktree root ".tmp/task136-fix";
    check_paths "a .git file counts as a checkout"
      [ ".tmp/task136-fix" ]
      (C.discover ~root);
    match C.discover ~root with
    | Ok (C.Complete [ c ]) ->
      check bool "classified as a pointer file" true (c.git_link = C.Git_pointer_file)
    | _ -> fail "expected exactly one checkout")
;;

(* No depth limit: a depth limit is the same kind of layout rule this module
   removes, and it fails silently. *)
let test_no_depth_limit () =
  with_temp_root (fun root ->
    make_checkout root "a/b/c/d/e/masc";
    check_paths "a deeply nested checkout is found"
      [ "a/b/c/d/e/masc" ]
      (C.discover ~root))
;;

(* ------------------------------------------------------------------ *)
(* Stopping at a checkout                                              *)
(* ------------------------------------------------------------------ *)

(* dune writes _build/.sandbox/.git and yarn writes node_modules/*/.git. Both
   live inside a checkout, so stopping there removes them without naming them.
   No blacklist. *)
let test_does_not_descend_into_a_checkout () =
  with_temp_root (fun root ->
    make_checkout root "repos/masc";
    make_worktree root "repos/masc/_build/.sandbox";
    make_checkout root "repos/masc/node_modules/pkg";
    check_paths "build artifacts inside a checkout are not reported"
      [ "repos/masc" ]
      (C.discover ~root))
;;

let test_hierarchical_worktree_is_not_a_separate_checkout () =
  with_temp_root (fun root ->
    make_checkout root "repos/masc";
    make_worktree root "repos/masc/.worktrees/task-017";
    check_paths "a worktree under its parent checkout is not counted twice"
      [ "repos/masc" ]
      (C.discover ~root))
;;

(* Measured live: a Keeper's repos/masc-task-188 sits beside the checkout it
   belongs to, not under it. The old scan already counted these, so the
   behaviour must not change. *)
let test_flat_worktree_is_its_own_checkout () =
  with_temp_root (fun root ->
    make_checkout root "repos/masc";
    make_worktree root "repos/masc-task-188";
    check_paths "a worktree beside the checkout is counted"
      [ "repos/masc"; "repos/masc-task-188" ]
      (C.discover ~root))
;;

(* Measured live: a Keeper's repos/masc/review-pr-28304 is a worktree
   outside the .worktrees/ convention. Naming that directory would miss it. *)
let test_worktree_outside_the_worktrees_convention () =
  with_temp_root (fun root ->
    make_checkout root "repos/masc";
    make_worktree root "repos/review-pr-28304";
    check_paths "no special handling of the .worktrees name"
      [ "repos/masc"; "repos/review-pr-28304" ]
      (C.discover ~root))
;;

(* ------------------------------------------------------------------ *)
(* Symlinks                                                            *)
(* ------------------------------------------------------------------ *)

let test_symlinked_directory_is_not_traversed () =
  with_temp_root (fun root ->
    make_checkout root "repos/masc";
    Unix.symlink (Filename.concat root "repos") (Filename.concat root "link");
    check_paths "a symlink to a directory does not duplicate its contents"
      [ "repos/masc" ]
      (C.discover ~root))
;;

(* A .git symlink can point outside the workspace root; treating it as a
   checkout would attribute writes to a tree the keeper does not own. *)
let test_symlinked_git_entry_is_rejected () =
  with_temp_root (fun root ->
    let target = Filename.concat root "elsewhere" in
    mkdir_p target;
    let dir = Filename.concat root "repos/x" in
    mkdir_p dir;
    Unix.symlink target (Filename.concat dir ".git");
    check_paths "a symlinked .git is not a checkout" [] (C.discover ~root))
;;

(* ------------------------------------------------------------------ *)
(* Failure is not emptiness                                            *)
(* ------------------------------------------------------------------ *)

(* The whole point of the typed result: today "the root does not exist" and
   "the root holds no checkout" both surface as []. *)
let test_missing_root_is_not_an_empty_listing () =
  with_temp_root (fun root ->
    let missing = Filename.concat root "does-not-exist" in
    match C.discover ~root:missing with
    | Error (C.Root_missing _) -> ()
    | Ok (C.Complete []) -> fail "a missing root must not read as an empty listing"
    | Ok _ -> fail "expected Root_missing"
    | Error e -> fail ("expected Root_missing, got " ^ C.scan_error_to_string e))
;;

let test_empty_root_is_a_complete_empty_listing () =
  with_temp_root (fun root ->
    match C.discover ~root with
    | Ok (C.Complete []) -> ()
    | other -> fail ("expected Complete [], got " ^ String.concat "," (paths_of other)))
;;

let test_root_that_is_a_file () =
  with_temp_root (fun root ->
    let path = Filename.concat root "a-file" in
    write_file path "x";
    match C.discover ~root:path with
    | Error (C.Root_not_directory _) -> ()
    | _ -> fail "expected Root_not_directory")
;;

(* One unreadable subdirectory must not blank the whole listing. *)
let test_unreadable_subdirectory_is_partial_not_fatal () =
  if Unix.geteuid () = 0
  then ()
  else
    with_temp_root (fun root ->
      make_checkout root "repos/masc";
      let blocked = Filename.concat root "blocked" in
      mkdir_p blocked;
      Unix.chmod blocked 0o000;
      (* Restore under protect: if discover raises, an un-restored 0o000
         directory also blocks the harness's own cleanup. *)
      let result =
        Fun.protect
          ~finally:(fun () -> try Unix.chmod blocked 0o755 with _ -> ())
          (fun () -> C.discover ~root)
      in
      match result with
      | Ok (C.Partial { found; limit = C.Directory_unreadable _ }) ->
        check (list string) "checkouts found before the failure are kept"
          [ "repos/masc" ]
          (List.map (fun (c : C.checkout) -> c.relative_path) found)
      | other ->
        fail
          ("expected Partial Directory_unreadable, got "
           ^ String.concat "," (paths_of other)))
;;

(* Truncation must be visible. A caller that cannot tell a capped listing from
   a complete one will present the cap as the whole answer. *)
let test_checkout_budget_truncates_visibly () =
  with_temp_root (fun root ->
    for i = 0 to C.max_reported_checkouts do
      make_checkout root (Printf.sprintf "repos/r%03d" i)
    done;
    match C.discover ~root with
    | Ok (C.Partial { found; limit = C.Checkout_budget_exhausted _ }) ->
      check int "listing is capped at the budget" C.max_reported_checkouts
        (List.length found)
    | Ok (C.Complete cs) ->
      failf "expected Partial, got Complete with %d checkouts" (List.length cs)
    | Ok (C.Partial { limit; _ }) ->
      fail ("expected Checkout_budget_exhausted, got " ^ C.limit_to_string limit)
    | Error e -> fail (C.scan_error_to_string e))
;;

(* ------------------------------------------------------------------ *)
(* Name resolution and path joining                                    *)
(* ------------------------------------------------------------------ *)

(* Two checkouts can share a basename once the layout is free. Picking by sort
   order would be an arbitrary answer to an ambiguous question. *)
let test_duplicate_basename_is_ambiguous () =
  with_temp_root (fun root ->
    make_checkout root "repos/masc";
    make_checkout root "work/masc";
    match C.discover ~root with
    | Ok discovery ->
      (match C.resolve_by_name discovery ~name:"masc" with
       | C.Ambiguous many -> check int "both candidates reported" 2 (List.length many)
       | C.Resolved _ -> fail "must not pick one of two same-named checkouts"
       | C.Not_found -> fail "expected Ambiguous")
    | Error e -> fail (C.scan_error_to_string e))
;;

let test_join_edges () =
  with_temp_root (fun root ->
    make_checkout root "repos/masc";
    match C.discover ~root with
    | Ok (C.Complete [ c ]) ->
      check string "empty suffix does not leave a trailing slash"
        "repos/masc"
        (C.join c ~suffix:"");
      check string "suffix is appended"
        "repos/masc/lib/foo.ml"
        (C.join c ~suffix:"lib/foo.ml")
    | _ -> fail "expected exactly one checkout");
  with_temp_root (fun root ->
    mkdir_p (Filename.concat root ".git");
    match C.discover ~root with
    | Ok (C.Complete [ c ]) ->
      check string "root checkout does not produce a ./ prefix" "lib"
        (C.join c ~suffix:"lib");
      check string "root checkout with empty suffix stays \".\"" "."
        (C.join c ~suffix:"")
    | _ -> fail "expected the root to be the only checkout")
;;

let test_results_are_sorted_and_stable () =
  with_temp_root (fun root ->
    make_checkout root "work/b";
    make_checkout root "repos/a";
    make_checkout root "zz";
    let first = paths_of (C.discover ~root) in
    let second = paths_of (C.discover ~root) in
    check (list string) "sorted by relative path" [ "repos/a"; "work/b"; "zz" ] first;
    check (list string) "repeated scans agree" first second)
;;

(* ------------------------------------------------------------------ *)
(* Wire encoding                                                       *)
(* ------------------------------------------------------------------ *)

let scan_state json =
  match json with
  | `Assoc fields ->
    (match List.assoc_opt "state" fields with
     | Some (`String s) -> s
     | _ -> "<missing>")
  | _ -> "<not an object>"
;;

(* A missing root and an empty root must not encode the same way. *)
let test_scan_json_separates_failure_from_emptiness () =
  with_temp_root (fun root ->
    check string "empty root encodes as complete" "complete"
      (scan_state (C.scan_json (C.discover ~root)));
    let missing = Filename.concat root "does-not-exist" in
    check string "missing root encodes as unavailable" "unavailable"
      (scan_state (C.scan_json (C.discover ~root:missing))))
;;

let () =
  run
    "keeper_playground_checkout_discovery"
    [ ( "discovery"
      , [ test_case "legacy repos/ layout still found" `Quick test_finds_legacy_repos_layout
        ; test_case "checkout directly under root" `Quick
            test_finds_checkout_directly_under_root
        ; test_case "root itself is a checkout" `Quick test_root_itself_is_a_checkout
        ; test_case "hidden directories are traversed" `Quick
            test_finds_checkout_under_hidden_directory
        ; test_case "gitdir file counts as checkout" `Quick
            test_finds_worktree_with_gitdir_file
        ; test_case "no depth limit" `Quick test_no_depth_limit
        ] )
    ; ( "stopping at a checkout"
      , [ test_case "does not descend into a checkout" `Quick
            test_does_not_descend_into_a_checkout
        ; test_case "hierarchical worktree not counted" `Quick
            test_hierarchical_worktree_is_not_a_separate_checkout
        ; test_case "flat worktree is its own checkout" `Quick
            test_flat_worktree_is_its_own_checkout
        ; test_case "worktree outside .worktrees/" `Quick
            test_worktree_outside_the_worktrees_convention
        ] )
    ; ( "symlinks"
      , [ test_case "symlinked directory not traversed" `Quick
            test_symlinked_directory_is_not_traversed
        ; test_case "symlinked .git rejected" `Quick test_symlinked_git_entry_is_rejected
        ] )
    ; ( "failure is not emptiness"
      , [ test_case "missing root is not an empty listing" `Quick
            test_missing_root_is_not_an_empty_listing
        ; test_case "empty root is Complete []" `Quick
            test_empty_root_is_a_complete_empty_listing
        ; test_case "root that is a file" `Quick test_root_that_is_a_file
        ; test_case "unreadable subdirectory is partial" `Quick
            test_unreadable_subdirectory_is_partial_not_fatal
        ; test_case "checkout budget truncates visibly" `Quick
            test_checkout_budget_truncates_visibly
        ] )
    ; ( "resolution and joining"
      , [ test_case "duplicate basename is ambiguous" `Quick
            test_duplicate_basename_is_ambiguous
        ; test_case "join edges" `Quick test_join_edges
        ; test_case "sorted and stable" `Quick test_results_are_sorted_and_stable
        ] )
    ; ( "wire"
      , [ test_case "scan_json separates failure from emptiness" `Quick
            test_scan_json_separates_failure_from_emptiness
        ] )
    ]
;;
