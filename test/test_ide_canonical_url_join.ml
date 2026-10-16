(** IDE write/read joins measured from real Git checkouts, independent of layout. *)
open Alcotest

let rec rm_rf path =
  if Sys.file_exists path then
    if Sys.is_directory path then (
      Array.iter (fun name -> rm_rf (Filename.concat path name)) (Sys.readdir path);
      Unix.rmdir path)
    else Sys.remove path
;;

let with_base f =
  let path = Filename.temp_file "ide-attribution-" "" in
  Sys.remove path;
  Unix.mkdir path 0o755;
  let path = Unix.realpath path in
  Fun.protect ~finally:(fun () -> rm_rf path) (fun () -> f path)
;;

let rec mkdir_p path =
  if not (Sys.file_exists path) then (mkdir_p (Filename.dirname path); Unix.mkdir path 0o755)
;;

let touch path =
  mkdir_p (Filename.dirname path);
  close_out (open_out path)
;;

let git path args =
  let cmd = String.concat " " (List.map Filename.quote ("git" :: "-C" :: path :: args)) in
  if Sys.command (cmd ^ " >/dev/null 2>&1") <> 0 then failf "Git fixture failed: %s" cmd
;;

let init ?origin path =
  mkdir_p path;
  git path [ "init"; "-b"; "main" ];
  git path [ "-c"; "user.name=Fixture"; "-c"; "user.email=fixture@example.invalid"
           ; "-c"; "commit.gpgsign=false"; "-c"; "core.hooksPath=/dev/null"
           ; "commit"; "--allow-empty"; "-m"; "fixture" ];
  Option.iter (fun url -> git path [ "remote"; "add"; "origin"; url ]) origin;
  touch (Filename.concat path "lib/foo.ml")
;;

let url = "https://github.com/owner/repo.git"
let other_url = "https://github.com/other/project.git"

let repo ?(remote = url) id local_path : Repo_manager_types.repository =
  { id; name = id; url = remote; local_path; aliases = []; default_branch = "main"
  ; keepers = []; status = Repo_manager_types.Active; auto_sync = false; sync_interval = 0
  ; created_at = 0L; updated_at = 0L }
;;

let save base repositories =
  match Repo_store.save_all ~base_path:base repositories with
  | Ok () -> ()
  | Error error -> failf "catalog fixture: %s" error
;;

let resolve base file_path =
  Masc.Keeper_tool_filesystem_runtime.resolve_write_attribution ~base_dir:base ~file_path
;;

let addressed = function
  | Agent_observation.Addressed record -> record
  | Agent_observation.Unaddressed { reason; _ } ->
    failf "expected address, got %s" (Agent_observation.Unattributed.reason_to_string reason)
;;

let check_address ~slug ~path result =
  let record = addressed result in
  check string "catalog-owned codebase" slug (Agent_observation.Code_address.codebase record.address);
  check string "measured repo-relative path" path (Agent_observation.Code_address.path record.address);
  record
;;

let check_reason expected attempted = function
  | Agent_observation.Addressed _ -> fail "unexpected attribution"
  | Agent_observation.Unaddressed { reason; attempted_path } ->
    check string "typed failure" expected (Agent_observation.Unattributed.reason_to_string reason);
    check string "original attempted path" attempted attempted_path
;;

let setup base =
  let operator = Filename.concat base "workspace/operator" in
  init ~origin:url operator;
  save base [ repo "catalog-id" operator ];
  operator
;;

let test_distinct_clones_join () =
  with_base (fun base ->
    let operator = setup base in
    let clone = Filename.concat base ".masc/playground/keeper/work/renamed-clone" in
    init ~origin:"git@github.com:owner/repo.git" clone;
    let op = check_address ~slug:"github.com_owner_repo" ~path:"lib/foo.ml"
               (resolve base (Filename.concat operator "lib/foo.ml")) in
    let copy = check_address ~slug:"github.com_owner_repo" ~path:"lib/foo.ml"
                 (resolve base (Filename.concat clone "lib/foo.ml")) in
    check bool "same read/write join key" true (Agent_observation.Code_address.equal op.address copy.address);
    check (option string) "operator root is measured too" (Some operator) op.checkout;
    check (option string) "clone root is projection only" (Some clone) copy.checkout)
;;

let test_misleading_dirname () =
  with_base (fun base ->
    let operator = setup base in
    let other = Filename.concat base "workspace/other" in
    init ~origin:other_url other;
    save base [ repo "catalog-id" operator; repo ~remote:other_url "other-id" other ];
    let clone = Filename.concat base ".masc/playground/keeper/repos/catalog-id" in
    init ~origin:other_url clone;
    ignore (check_address ~slug:"github.com_other_project" ~path:"lib/foo.ml"
              (resolve base (Filename.concat clone "lib/foo.ml"))))
;;

let test_arbitrary_layout () =
  with_base (fun base ->
    ignore (setup base);
    List.iter (fun rel ->
      let clone = Filename.concat base rel in
      init ~origin:url clone;
      ignore (check_address ~slug:"github.com_owner_repo" ~path:"lib/foo.ml"
                (resolve base (Filename.concat clone "lib/foo.ml"))))
      [ "elsewhere/deep/clone"; ".masc/playground/docker/k/repos/not-the-id" ])
;;

let local_origin origin_of =
  with_base (fun base ->
    let operator = setup base in
    let clone = Filename.concat base "copy" in
    init ~origin:(origin_of operator) clone;
    ignore (check_address ~slug:"github.com_owner_repo" ~path:"lib/foo.ml"
              (resolve base (Filename.concat clone "lib/foo.ml"))))
;;

let test_remote_change () =
  with_base (fun base ->
    let operator = setup base in
    let other = Filename.concat base "workspace/other" in
    init ~origin:other_url other;
    save base [ repo "one" operator; repo ~remote:other_url "two" other ];
    let file = Filename.concat operator "lib/foo.ml" in
    ignore (check_address ~slug:"github.com_owner_repo" ~path:"lib/foo.ml" (resolve base file));
    git operator [ "remote"; "set-url"; "origin"; other_url ];
    ignore (check_address ~slug:"github.com_other_project" ~path:"lib/foo.ml" (resolve base file));
    git operator [ "remote"; "remove"; "origin" ];
    check_reason "origin_missing" file (resolve base file))
;;

let test_nested_foreign ~registered () =
  with_base (fun base ->
    let operator = setup base in
    let nested = Filename.concat operator "vendor/foreign" in
    init ~origin:other_url nested;
    if registered then save base [ repo "one" operator; repo ~remote:other_url "two" nested ];
    let file = Filename.concat nested "lib/foo.ml" in
    if registered then
      ignore (check_address ~slug:"github.com_other_project" ~path:"lib/foo.ml" (resolve base file))
    else check_reason "unregistered_origin" file (resolve base file))
;;

let test_local_origin_nested_foreign () =
  with_base (fun base ->
    let operator = setup base in
    let nested = Filename.concat operator "vendor/foreign" in
    init ~origin:other_url nested;
    let clone = Filename.concat base "copy" in
    init ~origin:nested clone;
    let file = Filename.concat clone "lib/foo.ml" in
    check_reason "unregistered_origin" file (resolve base file))
;;

let test_local_origin_outside_linked_worktree () =
  with_base (fun base ->
    let operator = setup base in
    let linked = Filename.concat base "outside/linked" in
    mkdir_p (Filename.dirname linked);
    git operator [ "worktree"; "add"; "-b"; "local-origin"; linked ];
    let clone = Filename.concat base "copy" in
    init ~origin:linked clone;
    ignore (check_address ~slug:"github.com_owner_repo" ~path:"lib/foo.ml"
              (resolve base (Filename.concat clone "lib/foo.ml")));
    save base [ repo "one" operator; repo ~remote:other_url "two" linked ];
    let file = Filename.concat clone "lib/foo.ml" in
    check_reason "ambiguous_origin" file (resolve base file))
;;

let test_local_origin_unavailable_catalog_checkout () =
  with_base (fun base ->
    let operator = setup base in
    let unavailable = Filename.concat base "unavailable" in
    mkdir_p unavailable;
    let clone = Filename.concat base "copy" in
    init ~origin:operator clone;
    let file = Filename.concat clone "lib/foo.ml" in
    List.iter (fun repositories ->
      save base repositories;
      check_reason "checkout_unavailable" file (resolve base file))
      [ [ repo "known" operator; repo ~remote:other_url "unknown" unavailable ]
      ; [ repo ~remote:other_url "unknown" unavailable; repo "known" operator ] ])
;;

let test_worktrees () =
  with_base (fun base ->
    let operator = setup base in
    List.iteri (fun index rel ->
      let clone = Filename.concat base rel in
      git operator [ "worktree"; "add"; "-b"; Printf.sprintf "fixture-%d" index; clone ];
      touch (Filename.concat clone "lib/foo.ml");
      let record = check_address ~slug:"github.com_owner_repo" ~path:"lib/foo.ml"
                     (resolve base (Filename.concat clone "lib/foo.ml")) in
      check (option string) "measured worktree projection" (Some clone) record.checkout)
      [ "workspace/operator/.worktrees/task"; "anywhere/task" ];
    touch (Filename.concat operator ".worktrees/plain/lib/foo.ml");
    let record = check_address ~slug:"github.com_owner_repo" ~path:".worktrees/plain/lib/foo.ml"
                   (resolve base (Filename.concat operator ".worktrees/plain/lib/foo.ml")) in
    check (option string) "plain subdir belongs to measured operator root" (Some operator) record.checkout)
;;

let test_conflicting_catalog () =
  with_base (fun base ->
    let operator = setup base in
    save base [ repo "one" operator; repo ~remote:other_url "two" operator ];
    let clone = Filename.concat base "copy" in
    init ~origin:operator clone;
    let file = Filename.concat clone "lib/foo.ml" in
    check_reason "ambiguous_origin" file (resolve base file))
;;

let test_duplicate_identity () =
  with_base (fun base ->
    let operator = setup base in
    save base [ repo "one" operator; repo ~remote:"git@github.com:owner/repo.git" "two" operator ];
    let clone = Filename.concat base "copy" in
    init ~origin:operator clone;
    ignore (check_address ~slug:"github.com_owner_repo" ~path:"lib/foo.ml"
              (resolve base (Filename.concat clone "lib/foo.ml"))))
;;

let test_no_checkout_or_origin () =
  with_base (fun base ->
    let operator = setup base in
    let plain = Filename.concat base "plain" in
    touch (Filename.concat plain "lib/foo.ml");
    save base [ repo "plain" plain; repo "one" operator ];
    let file = Filename.concat plain "lib/foo.ml" in
    check_reason "checkout_unavailable" file (resolve base file);
    init plain;
    check_reason "origin_missing" file (resolve base file))
;;

let test_catalog_failure () =
  with_base (fun base ->
    let operator = setup base in
    let file = Filename.concat operator "lib/foo.ml" in
    let path = Filename.concat base ".masc/config/repositories.toml" in
    let output = open_out path in
    output_string output "repository = \"broken\"\n";
    close_out output;
    check_reason "repository_catalog_unavailable" file (resolve base file))
;;

let test_deleted_leaf_and_dots () =
  with_base (fun base ->
    let operator = setup base in
    Sys.remove (Filename.concat operator "lib/foo.ml");
    ignore (check_address ~slug:"github.com_owner_repo" ~path:"lib/foo.ml"
              (resolve base (Filename.concat operator "lib/../lib/foo.ml"))))
;;

let () =
  run "IDE measured attribution"
    [ "write/read journey",
      [ test_case "renamed clone joins operator read" `Quick test_distinct_clones_join
      ; test_case "dirname never overrides actual origin" `Quick test_misleading_dirname
      ; test_case "arbitrary and Docker layouts" `Quick test_arbitrary_layout
      ; test_case "absolute local origin" `Quick (fun () -> local_origin Fun.id)
      ; test_case "relative local origin uses checkout root" `Quick (fun () -> local_origin (fun _ -> "../workspace/operator"))
      ; test_case "file URI local origin" `Quick (fun () -> local_origin (fun path -> "file://" ^ path))
      ; test_case "Git-directory local origin" `Quick (fun () -> local_origin (fun path -> Filename.concat path ".git"))
      ; test_case "remote change and removal are fresh" `Quick test_remote_change
      ; test_case "unregistered nested foreign repository" `Quick (test_nested_foreign ~registered:false)
      ; test_case "registered nested foreign repository" `Quick (test_nested_foreign ~registered:true)
      ; test_case "local nested foreign origin cannot inherit outer repo" `Quick test_local_origin_nested_foreign
      ; test_case "local outside linked-worktree origin and conflicting identity" `Quick test_local_origin_outside_linked_worktree
      ; test_case "unavailable local candidate never grants known identity" `Quick test_local_origin_unavailable_catalog_checkout
      ; test_case "worktrees fold without naming convention" `Quick test_worktrees
      ; test_case "conflicting local catalog identities" `Quick test_conflicting_catalog
      ; test_case "duplicate catalog rows retain one identity" `Quick test_duplicate_identity
      ; test_case "missing checkout and missing origin stay explicit" `Quick test_no_checkout_or_origin
      ; test_case "invalid catalog stays explicit" `Quick test_catalog_failure
      ; test_case "deleted leaf and dot segments" `Quick test_deleted_leaf_and_dots
      ] ]
