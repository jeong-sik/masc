module Claim = Masc.Keeper_repo_claim_hitl
module AQ = Masc.Keeper_approval_queue

(* #23956 made nonblocking resolution fail closed when no delivery hook is
   installed (the pre-bootstrap default is None). These tests resolve
   approvals without a server bootstrap, so install the same no-op hook the
   approval queue's own suite uses; delivery semantics are covered there,
   not here. *)
let () =
  AQ.set_approval_resolution_wake_hook
    (fun ~base_path:_ ~keeper_name:_ ~approval_id:_ ~decision:_ ~channel:_ ->
      Ok (fun () -> ()))
;;

open Repo_manager_types

let contains_substring s needle =
  let s_len = String.length s in
  let n_len = String.length needle in
  let rec loop i =
    if i + n_len > s_len then false
    else if String.sub s i n_len = needle then true
    else loop (i + 1)
  in
  if n_len = 0 then true else loop 0
;;

let is_directory_no_follow path =
  match Unix.lstat path with
  | { Unix.st_kind = Unix.S_DIR; _ } -> true
  | _ -> false
  | exception Unix.Unix_error _ -> false
;;

let path_exists_no_follow path =
  match Unix.lstat path with
  | _ -> true
  | exception Unix.Unix_error _ -> false
;;

let rec remove_tree path =
  if path_exists_no_follow path then
    if is_directory_no_follow path then begin
      Sys.readdir path
      |> Array.iter (fun name -> remove_tree (Filename.concat path name));
      Unix.rmdir path
    end else
      Sys.remove path
;;

let ensure_dir path =
  let rec loop path =
    if path = "" || path = "." || path = "/" || Sys.file_exists path then ()
    else begin
      let parent = Filename.dirname path in
      if parent <> path then loop parent;
      Unix.mkdir path 0o755
    end
  in
  loop path
;;

let write_file path content =
  ensure_dir (Filename.dirname path);
  let oc = open_out path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () -> output_string oc content)
;;

let run_git_quiet argv =
  let devnull = Unix.openfile "/dev/null" [ Unix.O_WRONLY ] 0 in
  Fun.protect
    ~finally:(fun () -> Unix.close devnull)
    (fun () ->
       try
         let pid = Unix.create_process "git" argv Unix.stdin devnull devnull in
         match Unix.waitpid [] pid with
         | _, Unix.WEXITED code -> code
         | _, (Unix.WSIGNALED _ | Unix.WSTOPPED _) -> 1
       with
       | Unix.Unix_error _ -> 1)
;;

let git_available () = run_git_quiet [| "git"; "--version" |] = 0

let canonical_path path =
  try Unix.realpath path with
  | Unix.Unix_error _ | Sys_error _ -> path
;;

let init_git_repo dir url =
  ensure_dir dir;
  Alcotest.(check int) "git init" 0 (run_git_quiet [| "git"; "init"; "-q"; dir |]);
  Alcotest.(check int)
    "git remote add"
    0
    (run_git_quiet [| "git"; "-C"; dir; "remote"; "add"; "origin"; url |]);
  Alcotest.(check int)
    "git origin HEAD"
    0
    (run_git_quiet
       [| "git"
        ; "-C"
        ; dir
        ; "symbolic-ref"
        ; "refs/remotes/origin/HEAD"
        ; "refs/remotes/origin/main"
       |])
;;

let set_git_origin_url dir url =
  Alcotest.(check int)
    "git remote set-url"
    0
    (run_git_quiet [| "git"; "-C"; dir; "remote"; "set-url"; "origin"; url |])
;;

let with_temp_base_path f =
  let dir = Filename.temp_file "repo_claim_hitl" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  Fun.protect ~finally:(fun () -> remove_tree dir) (fun () -> f dir)
;;

let sample_repo ~base_path id =
  let local_path = Filename.concat base_path ("repo-" ^ id) in
  ensure_dir local_path;
  { id
  ; name = id
  ; url = "https://github.com/test/" ^ id
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

let write_repositories base_path repos =
  let repo_block (repo : repository) =
    Printf.sprintf
      "[repository.%s]\nname = \"%s\"\nurl = \"%s\"\nlocal_path = \"%s\"\n\
       default_branch = \"%s\"\nkeepers = []\nstatus = \"Active\"\nauto_sync = false\n\
       sync_interval = 0\n"
      repo.id
      repo.name
      repo.url
      repo.local_path
      repo.default_branch
  in
  write_file
    (Filename.concat base_path ".masc/config/repositories.toml")
    (String.concat "\n" (List.map repo_block repos))
;;

let write_mapping base_path keeper_id repo_ids =
  let mapping = make_keeper_repo_mapping ~keeper_id ~repository_ids:repo_ids in
  match Keeper_repo_mapping.save_mapping ~base_path mapping with
  | Ok () -> ()
  | Error detail -> Alcotest.fail ("save_mapping failed: " ^ detail)
;;

let test_registered_repo_outside_advisory_mapping_is_allowed () =
  AQ.For_testing.reset_audit_store ();
  Fun.protect ~finally:AQ.For_testing.reset_audit_store @@ fun () ->
  with_temp_base_path @@ fun base_path ->
  let keeper_id = "keeper-repo-advisory-scope" in
  let repo_a = sample_repo ~base_path "repo-a" in
  let repo_b = sample_repo ~base_path "repo-b" in
  write_repositories base_path [ repo_a; repo_b ];
  write_mapping base_path keeper_id [ repo_a.id ];
  let pending_before = AQ.pending_count () in
  let result =
    Claim.request_path_access
      ~keeper_id
      ~base_path
      ~path:(Filename.concat repo_b.local_path "README.md")
  in
  (match result with
   | Claim.Access_allowed -> ()
   | Claim.Access_denied detail ->
     Alcotest.fail ("registered repo outside advisory mapping denied: " ^ detail)
   | Claim.Access_denied_hitl_pending _ ->
     Alcotest.fail "registered repo must not create HITL");
  Alcotest.(check int) "pending count unchanged" pending_before (AQ.pending_count ())
;;

let playground_repo_root ~base_path ~keeper_id ~repository_id =
  Filename.concat
    base_path
    (Filename.concat (Playground_paths.repos_path keeper_id) repository_id)
;;

let test_unregistered_repository_without_clone_does_not_request_hitl () =
  AQ.For_testing.reset_audit_store ();
  Fun.protect ~finally:AQ.For_testing.reset_audit_store @@ fun () ->
  with_temp_base_path @@ fun base_path ->
  let keeper_id = "keeper-repo-unregistered" in
  let repo_a = sample_repo ~base_path "repo-a" in
  write_repositories base_path [ repo_a ];
  write_mapping base_path keeper_id [ repo_a.id ];
  let pending_before = AQ.pending_count () in
  let result =
    Claim.request_repository_access
      ~keeper_id
      ~base_path
      ~repository_id:"not-registered"
  in
  (match result with
   | Claim.Access_denied detail ->
     Alcotest.(check bool)
       "denial mentions unregistered repository"
       true
       (contains_substring detail "not-registered")
   | Claim.Access_allowed -> Alcotest.fail "expected unregistered denial"
   | Claim.Access_denied_hitl_pending _ ->
     Alcotest.fail "repository id without clone must not create HITL");
  Alcotest.(check int) "pending count unchanged" pending_before (AQ.pending_count ())
;;

let require_one_pending ~keeper_id =
  match
    AQ.list_pending_entries ()
    |> List.filter (fun (entry : AQ.pending_approval) ->
      String.equal entry.keeper_name keeper_id)
  with
  | [ entry ] -> entry
  | entries ->
    Alcotest.failf
      "expected one pending approval for %s, got %d"
      keeper_id
      (List.length entries)
;;

let string_field key json =
  match Yojson.Safe.Util.member key json with
  | `String value -> value
  | other ->
    Alcotest.failf
      "expected string field %s, got %s"
      key
      (Yojson.Safe.to_string other)
;;

let test_unregistered_repository_id_with_clone_requests_hitl () =
  if not (git_available ()) then Alcotest.skip ()
  else (
    AQ.For_testing.reset_audit_store ();
    Fun.protect ~finally:AQ.For_testing.reset_audit_store @@ fun () ->
    with_temp_base_path @@ fun base_path ->
    let keeper_id = "keeper-repo-direct-register" in
    write_repositories base_path [];
    let repo_root =
      playground_repo_root ~base_path ~keeper_id ~repository_id:"not-registered"
    in
    init_git_repo repo_root "https://github.com/test/not-registered.git";
    let pending_before = AQ.pending_count () in
    let result =
      Claim.request_repository_access
        ~keeper_id
        ~base_path
        ~repository_id:"not-registered"
    in
    (match result with
     | Claim.Access_denied_hitl_pending { detail; approval_id } ->
       Alcotest.(check bool)
         "denial mentions unregistered repository"
         true
         (contains_substring detail "not-registered");
       Alcotest.(check bool) "approval id nonempty" true (String.trim approval_id <> "")
     | Claim.Access_allowed -> Alcotest.fail "expected unregistered denial"
     | Claim.Access_denied detail ->
       Alcotest.fail ("expected HITL pending denial, got: " ^ detail));
    Alcotest.(check int) "pending count increments" (pending_before + 1) (AQ.pending_count ());
    let pending = require_one_pending ~keeper_id in
    Alcotest.(check string)
      "requested action"
      "register_repository"
      (string_field "requested_action" pending.input);
    Alcotest.(check string)
      "repo root"
      (canonical_path repo_root)
      (string_field "repo_root" pending.input))
;;

let test_unregistered_clone_requests_hitl_and_approval_registers_repo () =
  if not (git_available ()) then Alcotest.skip ()
  else (
    AQ.For_testing.reset_audit_store ();
    Fun.protect ~finally:AQ.For_testing.reset_audit_store @@ fun () ->
    with_temp_base_path @@ fun base_path ->
    let keeper_id = "keeper-repo-register-clone" in
    write_repositories base_path [];
    let repo_root =
      Filename.concat
        base_path
        (Filename.concat ".masc/playground" (keeper_id ^ "/repos/not-registered"))
    in
    let target = Filename.concat repo_root "README.md" in
    init_git_repo repo_root "https://github.com/test/not-registered.git";
    write_file target "hello\n";
    let pending_before = AQ.pending_count () in
    let result = Claim.request_path_access ~keeper_id ~base_path ~path:target in
    (match result with
     | Claim.Access_denied_hitl_pending { detail; approval_id } ->
       Alcotest.(check bool)
         "denial mentions unregistered repository"
         true
         (contains_substring detail "not-registered");
       Alcotest.(check bool) "approval id nonempty" true (String.trim approval_id <> "")
     | Claim.Access_allowed -> Alcotest.fail "expected unregistered denial"
     | Claim.Access_denied detail ->
       Alcotest.fail ("expected HITL pending denial, got: " ^ detail));
    Alcotest.(check int) "pending count increments" (pending_before + 1) (AQ.pending_count ());
    let pending = require_one_pending ~keeper_id in
    Alcotest.(check string)
      "requested action"
      "register_repository"
      (string_field "requested_action" pending.input);
    Alcotest.(check string)
      "policy source"
      Config_dir_resolver.repositories_toml_basename
      (string_field "policy_source" pending.input);
    (match AQ.resolve ~id:pending.id ~decision:Agent_sdk.Hooks.Approve with
     | Ok () -> ()
     | Error err -> Alcotest.fail (AQ.resolve_error_to_string err));
    match Repo_store.find ~base_path "not-registered" with
    | Error detail -> Alcotest.fail ("approved registration did not persist: " ^ detail)
    | Ok repo ->
      Alcotest.(check string) "registered url" "https://github.com/test/not-registered.git" repo.url;
      Alcotest.(check string)
        "registered local path"
        (canonical_path repo_root)
        repo.local_path)
;;

let test_registration_approval_rechecks_clone_origin () =
  if not (git_available ()) then Alcotest.skip ()
  else (
    AQ.For_testing.reset_audit_store ();
    Fun.protect ~finally:AQ.For_testing.reset_audit_store @@ fun () ->
    with_temp_base_path @@ fun base_path ->
    let keeper_id = "keeper-repo-register-stale-origin" in
    write_repositories base_path [];
    let repo_root =
      Filename.concat
        base_path
        (Filename.concat ".masc/playground" (keeper_id ^ "/repos/not-registered"))
    in
    let target = Filename.concat repo_root "README.md" in
    init_git_repo repo_root "https://github.com/test/not-registered.git";
    write_file target "hello\n";
    (match Claim.request_path_access ~keeper_id ~base_path ~path:target with
     | Claim.Access_denied_hitl_pending _ -> ()
     | Claim.Access_allowed -> Alcotest.fail "expected registration HITL denial"
     | Claim.Access_denied detail ->
       Alcotest.fail ("expected registration HITL pending denial, got: " ^ detail));
    let pending = require_one_pending ~keeper_id in
    set_git_origin_url repo_root "https://github.com/test/renamed.git";
    (match AQ.resolve ~id:pending.id ~decision:Agent_sdk.Hooks.Approve with
     | Ok () -> ()
     | Error err -> Alcotest.fail (AQ.resolve_error_to_string err));
    match Repo_store.find ~base_path "not-registered" with
    | Error _ -> ()
    | Ok _ -> Alcotest.fail "stale approved registration must not persist")
;;

let test_unregistered_clone_matching_existing_remote_requests_alias () =
  if not (git_available ()) then Alcotest.skip ()
  else (
    AQ.For_testing.reset_audit_store ();
    Fun.protect ~finally:AQ.For_testing.reset_audit_store @@ fun () ->
    with_temp_base_path @@ fun base_path ->
    let keeper_id = "keeper-repo-alias-clone" in
    let registered = sample_repo ~base_path "masc" in
    let registered =
      { registered with url = "https://github.com/jeong-sik/masc.git"; aliases = [] }
    in
    write_repositories base_path [ registered ];
    let repo_root =
      Filename.concat
        base_path
        (Filename.concat ".masc/playground" (keeper_id ^ "/repos/masc-mcp"))
    in
    let target = Filename.concat repo_root "README.md" in
    init_git_repo repo_root registered.url;
    write_file target "hello\n";
    let result = Claim.request_path_access ~keeper_id ~base_path ~path:target in
    (match result with
     | Claim.Access_denied_hitl_pending _ -> ()
     | Claim.Access_allowed -> Alcotest.fail "expected alias HITL denial"
     | Claim.Access_denied detail ->
       Alcotest.fail ("expected alias HITL pending denial, got: " ^ detail));
    let pending = require_one_pending ~keeper_id in
    Alcotest.(check string)
      "requested action"
      "add_repository_alias"
      (string_field "requested_action" pending.input);
    Alcotest.(check string)
      "target repository"
      "masc"
      (string_field "target_repository_id" pending.input);
    Alcotest.(check string) "alias" "masc-mcp" (string_field "alias" pending.input);
    (match AQ.resolve ~id:pending.id ~decision:Agent_sdk.Hooks.Approve with
     | Ok () -> ()
     | Error err -> Alcotest.fail (AQ.resolve_error_to_string err));
    match Repo_store.find ~base_path "masc" with
    | Error detail -> Alcotest.fail ("existing repo disappeared: " ^ detail)
    | Ok repo ->
	      Alcotest.(check bool)
	        "alias persisted"
	        true
	        (List.exists (String.equal "masc-mcp") repo.aliases))
	;;

let test_unregistered_repository_id_clone_matching_existing_remote_requests_alias () =
  if not (git_available ()) then Alcotest.skip ()
  else (
    AQ.For_testing.reset_audit_store ();
    Fun.protect ~finally:AQ.For_testing.reset_audit_store @@ fun () ->
    with_temp_base_path @@ fun base_path ->
    let keeper_id = "keeper-repo-direct-alias" in
    let registered = sample_repo ~base_path "masc" in
    let registered =
      { registered with url = "https://github.com/jeong-sik/masc.git"; aliases = [] }
    in
    write_repositories base_path [ registered ];
    let repo_root =
      playground_repo_root ~base_path ~keeper_id ~repository_id:"masc-mcp"
    in
    init_git_repo repo_root registered.url;
    let result =
      Claim.request_repository_access
        ~keeper_id
        ~base_path
        ~repository_id:"masc-mcp"
    in
    (match result with
     | Claim.Access_denied_hitl_pending _ -> ()
     | Claim.Access_allowed -> Alcotest.fail "expected alias HITL denial"
     | Claim.Access_denied detail ->
       Alcotest.fail ("expected alias HITL pending denial, got: " ^ detail));
    let pending = require_one_pending ~keeper_id in
    Alcotest.(check string)
      "requested action"
      "add_repository_alias"
      (string_field "requested_action" pending.input);
    Alcotest.(check string)
      "target repository"
      "masc"
      (string_field "target_repository_id" pending.input);
    Alcotest.(check string) "alias" "masc-mcp" (string_field "alias" pending.input))
;;

let test_unregistered_repository_id_empty_clone_reports_verification_failure () =
  with_temp_base_path @@ fun base_path ->
  let keeper_id = "keeper-repo-direct-empty-clone" in
  let repository_id = "masc-empty" in
  let repo_root = playground_repo_root ~base_path ~keeper_id ~repository_id in
  ensure_dir repo_root;
  match Claim.request_repository_access ~keeper_id ~base_path ~repository_id with
  | Claim.Access_allowed -> Alcotest.fail "expected explicit verification denial"
  | Claim.Access_denied_hitl_pending _ ->
    Alcotest.fail "empty clone directory must not queue HITL"
  | Claim.Access_denied detail ->
    Alcotest.(check bool)
      "denial names clone verification"
      true
      (contains_substring detail "playground clone candidate could not be verified");
    Alcotest.(check bool)
      "denial keeps git probe reason"
      true
      (contains_substring detail repo_root)
;;

let test_nested_git_root_queues_manual_review_without_alias () =
  if not (git_available ()) then Alcotest.skip ()
  else (
    AQ.For_testing.reset_audit_store ();
    Fun.protect ~finally:AQ.For_testing.reset_audit_store @@ fun () ->
    with_temp_base_path @@ fun base_path ->
    let keeper_id = "keeper-repo-nested-root" in
    let registered = sample_repo ~base_path "masc" in
    let registered =
      { registered with url = "https://github.com/jeong-sik/masc.git"; aliases = [] }
    in
    write_repositories base_path [ registered ];
    let expected_repo_root =
      Filename.concat
        base_path
        (Filename.concat ".masc/playground" (keeper_id ^ "/repos/masc-mcp"))
    in
    let nested_root = Filename.concat expected_repo_root "nested" in
    let target = Filename.concat nested_root "README.md" in
    init_git_repo nested_root registered.url;
    write_file target "nested\n";
    (match Claim.request_path_access ~keeper_id ~base_path ~path:target with
     | Claim.Access_denied_hitl_pending _ -> ()
     | Claim.Access_allowed -> Alcotest.fail "expected manual review HITL denial"
     | Claim.Access_denied detail ->
       Alcotest.fail ("expected manual review HITL pending denial, got: " ^ detail));
    let pending = require_one_pending ~keeper_id in
    Alcotest.(check string)
      "requested action"
      "review_repository_catalog"
      (string_field "requested_action" pending.input);
    Alcotest.(check string)
      "expected repo root"
      expected_repo_root
      (string_field "expected_repo_root" pending.input);
    Alcotest.(check string)
      "git root"
      (canonical_path nested_root)
      (string_field "repo_root" pending.input);
    (match AQ.resolve ~id:pending.id ~decision:Agent_sdk.Hooks.Approve with
     | Ok () -> ()
     | Error err -> Alcotest.fail (AQ.resolve_error_to_string err));
    match Repo_store.find ~base_path "masc" with
    | Error detail -> Alcotest.fail ("existing repo disappeared: " ^ detail)
    | Ok repo ->
      Alcotest.(check bool)
        "manual review approval does not persist alias"
        false
        (List.exists (String.equal "masc-mcp") repo.aliases))
;;

let test_alias_approval_rechecks_clone_origin () =
  if not (git_available ()) then Alcotest.skip ()
  else (
    AQ.For_testing.reset_audit_store ();
    Fun.protect ~finally:AQ.For_testing.reset_audit_store @@ fun () ->
    with_temp_base_path @@ fun base_path ->
    let keeper_id = "keeper-repo-alias-stale-origin" in
    let registered = sample_repo ~base_path "masc" in
    let registered =
      { registered with url = "https://github.com/jeong-sik/masc.git"; aliases = [] }
    in
    write_repositories base_path [ registered ];
    let repo_root =
      Filename.concat
        base_path
        (Filename.concat ".masc/playground" (keeper_id ^ "/repos/masc-mcp"))
    in
    let target = Filename.concat repo_root "README.md" in
    init_git_repo repo_root registered.url;
    write_file target "hello\n";
    (match Claim.request_path_access ~keeper_id ~base_path ~path:target with
     | Claim.Access_denied_hitl_pending _ -> ()
     | Claim.Access_allowed -> Alcotest.fail "expected alias HITL denial"
     | Claim.Access_denied detail ->
       Alcotest.fail ("expected alias HITL pending denial, got: " ^ detail));
    let pending = require_one_pending ~keeper_id in
    set_git_origin_url repo_root "https://github.com/jeong-sik/not-masc.git";
    (match AQ.resolve ~id:pending.id ~decision:Agent_sdk.Hooks.Approve with
     | Ok () -> ()
     | Error err -> Alcotest.fail (AQ.resolve_error_to_string err));
    match Repo_store.find ~base_path "masc" with
    | Error detail -> Alcotest.fail ("existing repo disappeared: " ^ detail)
    | Ok repo ->
      Alcotest.(check bool)
        "stale alias not persisted"
        false
        (List.exists (String.equal "masc-mcp") repo.aliases))
;;

let () =
  Alcotest.run
    "Keeper_repo_claim_hitl"
    [ ( "repo advisory access"
      , [ Alcotest.test_case
            "registered repo outside advisory mapping is allowed"
            `Quick
            test_registered_repo_outside_advisory_mapping_is_allowed
        ; Alcotest.test_case
            "unregistered repository without clone remains fail-closed"
            `Quick
            test_unregistered_repository_without_clone_does_not_request_hitl
        ; Alcotest.test_case
            "unregistered repository id with clone queues repository HITL"
            `Quick
            test_unregistered_repository_id_with_clone_requests_hitl
        ; Alcotest.test_case
            "unregistered sandbox clone queues registration HITL"
            `Quick
            test_unregistered_clone_requests_hitl_and_approval_registers_repo
        ; Alcotest.test_case
            "registration approval rechecks clone origin"
            `Quick
            test_registration_approval_rechecks_clone_origin
        ; Alcotest.test_case
            "clone name mismatch queues alias HITL"
            `Quick
            test_unregistered_clone_matching_existing_remote_requests_alias
        ; Alcotest.test_case
            "repository id clone name mismatch queues alias HITL"
            `Quick
            test_unregistered_repository_id_clone_matching_existing_remote_requests_alias
        ; Alcotest.test_case
            "repository id empty clone reports verification failure"
            `Quick
            test_unregistered_repository_id_empty_clone_reports_verification_failure
        ; Alcotest.test_case
            "nested git root queues manual review without alias"
            `Quick
            test_nested_git_root_queues_manual_review_without_alias
        ; Alcotest.test_case
            "alias approval rechecks clone origin"
            `Quick
            test_alias_approval_rechecks_clone_origin
        ] )
    ]
