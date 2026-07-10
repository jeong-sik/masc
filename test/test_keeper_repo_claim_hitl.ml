module Claim = Masc.Keeper_repo_claim_hitl
module Raw_AQ = Masc.Keeper_approval_queue

module AQ = struct
  include Raw_AQ

  let pending_scopes : (string, string) Hashtbl.t = Hashtbl.create 16

  let base_path_for_id id =
    match Hashtbl.find_opt pending_scopes id with
    | Some base_path -> base_path
    | None ->
      (match For_testing.pending_base_path ~id with
       | Some base_path ->
         Hashtbl.replace pending_scopes id base_path;
         base_path
       | None -> Alcotest.failf "pending approval %s has no workspace" id)
  ;;

  let resolve ~id ~decision =
    Raw_AQ.resolve ~base_path:(base_path_for_id id) ~id ~decision
  ;;

  let get_pending_entry ~id =
    Raw_AQ.get_pending_entry ~base_path:(base_path_for_id id) ~id
  ;;

  let pending_count = For_testing.pending_count
  let list_pending_entries = For_testing.list_pending_entries
end

open Repo_manager_types

let reset_approval_state () =
  AQ.For_testing.reset_pending ();
  AQ.For_testing.reset_audit_store ()
;;

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

let seed_keeper_meta base_path keeper_id =
  let config = Masc.Workspace.default_config base_path in
  ignore (Masc.Workspace.init config ~agent_name:(Some "repo-claim-test"));
  let meta =
    match
      Masc_test_deps.meta_of_json_fixture
        (`Assoc
          [ "name", `String keeper_id
          ; "agent_name", `String ("agent-" ^ keeper_id)
          ; "trace_id", `String ("trace-" ^ keeper_id)
          ])
    with
    | Ok meta -> meta
    | Error err -> Alcotest.fail ("seed keeper meta: " ^ err)
  in
  let meta = { meta with name = keeper_id } in
  let path = Masc.Keeper_types_profile.keeper_meta_path config keeper_id in
  write_file path (Yojson.Safe.pretty_to_string (Masc.Keeper_meta_json.meta_to_json meta));
  match Masc.Keeper_meta_store.read_meta config keeper_id with
  | Ok (Some _) -> ()
  | Ok None ->
    Alcotest.failf
      "seed keeper meta was not durably readable path=%s exists=%b config_base=%s"
      path
      (Sys.file_exists path)
      config.base_path
  | Error err -> Alcotest.fail ("read seeded keeper meta: " ^ err)
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
  match Repo_store.save_all ~base_path repos with
  | Ok () -> ()
  | Error detail -> Alcotest.fail ("write repositories: " ^ detail)
;;

let write_mapping base_path keeper_id repo_ids =
  let mapping = make_keeper_repo_mapping ~keeper_id ~repository_ids:repo_ids in
  match Keeper_repo_mapping.save_mapping ~base_path mapping with
  | Ok () -> ()
  | Error detail -> Alcotest.fail ("save_mapping failed: " ^ detail)
;;

let test_registered_repo_outside_advisory_mapping_is_allowed () =
  reset_approval_state ();
  Fun.protect ~finally:reset_approval_state @@ fun () ->
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
  reset_approval_state ();
  Fun.protect ~finally:reset_approval_state @@ fun () ->
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

let read_keeper_meta base_path keeper_id =
  let config = Masc.Workspace.default_config base_path in
  match Masc.Keeper_meta_store.read_meta config keeper_id with
  | Ok (Some meta) -> meta
  | Ok None -> Alcotest.failf "keeper meta disappeared: %s" keeper_id
  | Error err -> Alcotest.fail err
;;

let write_keeper_meta_direct base_path (meta : Masc.Keeper_meta_contract.keeper_meta) =
  let config = Masc.Workspace.default_config base_path in
  let path = Masc.Keeper_types_profile.keeper_meta_path config meta.name in
  write_file path (Yojson.Safe.pretty_to_string (Masc.Keeper_meta_json.meta_to_json meta))
;;

let repository_operation_path base_path =
  let dir =
    Filename.concat
      base_path
      ".masc/approvals/repository-registration"
  in
  let files =
    if Sys.file_exists dir
    then
      Sys.readdir dir
      |> Array.to_list
      |> List.filter (String.ends_with ~suffix:".json")
    else []
  in
  match files with
  | [ file ] -> Filename.concat dir file
  | files ->
    Alcotest.failf
      "expected one durable repository operation, got %d"
      (List.length files)
;;

let repository_operation_record_exists base_path =
  let dir =
    Filename.concat
      base_path
      ".masc/approvals/repository-registration"
  in
  Sys.file_exists dir
  && (Sys.readdir dir
      |> Array.exists (String.ends_with ~suffix:".json"))
;;

let repository_gate_operation_id (meta : Masc.Keeper_meta_contract.keeper_meta) =
  match meta.latched_reason with
  | Some (Keeper_latched_reason.Repository_registration_pending { operation_id }) ->
    operation_id
  | Some reason ->
    Alcotest.failf
      "expected repository gate, got %s"
      (Keeper_latched_reason.to_wire reason)
  | None -> Alcotest.fail "expected repository gate, got no latch"
;;

let request_clone_registration ~base_path ~keeper_id ~repository_id =
  let repo_root = playground_repo_root ~base_path ~keeper_id ~repository_id in
  init_git_repo repo_root ("https://github.com/test/" ^ repository_id ^ ".git");
  match
    Claim.request_repository_access
      ~keeper_id
      ~base_path
      ~repository_id
  with
  | Claim.Access_denied_hitl_pending { approval_id; _ } -> approval_id, repo_root
  | Claim.Access_allowed -> Alcotest.fail "expected repository registration HITL"
  | Claim.Access_denied detail ->
    Alcotest.fail ("expected repository registration HITL: " ^ detail)
;;

let test_unregistered_repository_id_with_clone_requests_hitl () =
  if not (git_available ()) then Alcotest.skip ()
  else (
    reset_approval_state ();
    Fun.protect ~finally:reset_approval_state @@ fun () ->
    with_temp_base_path @@ fun base_path ->
    let keeper_id = "repo-direct-register" in
    seed_keeper_meta base_path keeper_id;
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
      "verify_repository_catalog_registration"
      (string_field "requested_action" pending.input);
    Alcotest.(check string)
      "repo root"
      (canonical_path repo_root)
      (string_field "repo_root" pending.input))
;;

let test_unregistered_clone_requests_hitl_and_approval_registers_repo () =
  if not (git_available ()) then Alcotest.skip ()
  else (
    reset_approval_state ();
    Fun.protect ~finally:reset_approval_state @@ fun () ->
    with_temp_base_path @@ fun base_path ->
    let keeper_id = "repo-register-clone" in
    seed_keeper_meta base_path keeper_id;
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
      "verify_repository_catalog_registration"
      (string_field "requested_action" pending.input);
    Alcotest.(check string)
      "policy source"
      Config_dir_resolver.repositories_toml_basename
      (string_field "policy_source" pending.input);
    Alcotest.(check bool)
      "repository mutation uses the authoritative blocking lane"
      true
      (pending.lane_policy = AQ.Blocking);
    Alcotest.(check bool)
      "repository mutation owns an authoritative callback"
      true
      (Option.is_some pending.on_resolution_callback);
    Alcotest.(check bool)
      "repository mutation is not a non-authoritative observer"
      true
      (Option.is_none pending.on_resolution_observer);
    (match
       AQ.resolve
         ~id:pending.id
         ~decision:(Agent_sdk.Hooks.Edit (`Assoc [ "unexpected", `Bool true ]))
     with
     | Error (AQ.Delivery_failed _) -> ()
     | Error err -> Alcotest.fail (AQ.resolve_error_to_string err)
     | Ok () -> Alcotest.fail "unsupported edit must retain the approval");
    Alcotest.(check bool)
      "unsupported repository edit keeps approval pending"
      true
      (Option.is_some (AQ.get_pending_entry ~id:pending.id));
    let config = Masc.Workspace.default_config base_path in
    let persisted_gate =
      match Masc.Keeper_meta_store.read_meta config keeper_id with
      | Ok (Some meta) -> meta
      | Ok None -> Alcotest.fail "repository gate keeper meta disappeared"
      | Error err -> Alcotest.fail err
    in
    Alcotest.(check bool) "repository approval durably pauses keeper" true persisted_gate.paused;
    Alcotest.(check bool)
      "repository approval persists a typed continue gate"
      true
      (Masc.Keeper_supervisor_types.paused_meta_requires_reconcile_recovery
         persisted_gate);
    AQ.For_testing.reset_pending ();
    (match Claim.restore_pending_registration_hitl ~config persisted_gate with
     | Claim.Registration_restored -> ()
     | Claim.No_registration_record -> Alcotest.fail "durable operation disappeared"
     | Claim.Registration_superseded -> Alcotest.fail "durable operation was superseded"
     | Claim.Registration_corrupt detail ->
       Alcotest.fail ("durable operation became corrupt: " ^ detail));
    let restored_pending = require_one_pending ~keeper_id in
    Alcotest.(check bool)
      "restored approval receives a fresh queue identity"
      true
      (not (String.equal pending.id restored_pending.id));
    let operator_registered =
      { (sample_repo ~base_path "not-registered") with
        url = "https://github.com/test/not-registered.git"
      ; local_path = canonical_path repo_root
      ; keepers = [ keeper_id ]
      }
    in
    write_repositories base_path [ operator_registered ];
    (match AQ.resolve ~id:restored_pending.id ~decision:Agent_sdk.Hooks.Approve with
     | Ok () -> ()
     | Error err -> Alcotest.fail (AQ.resolve_error_to_string err));
    let resumed_meta =
      match Masc.Keeper_meta_store.read_meta config keeper_id with
      | Ok (Some meta) -> meta
      | Ok None -> Alcotest.fail "approved repository keeper meta disappeared"
      | Error err -> Alcotest.fail err
    in
    Alcotest.(check bool) "approved repository gate resumes keeper" false resumed_meta.paused;
    Alcotest.(check bool)
      "approved repository gate clears typed blocker"
      true
      (Option.is_none resumed_meta.runtime.last_blocker);
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
    reset_approval_state ();
    Fun.protect ~finally:reset_approval_state @@ fun () ->
    with_temp_base_path @@ fun base_path ->
    let keeper_id = "repo-register-stale-origin" in
    seed_keeper_meta base_path keeper_id;
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
     | Error (AQ.Delivery_failed _) -> ()
     | Error err -> Alcotest.fail (AQ.resolve_error_to_string err)
     | Ok () -> Alcotest.fail "failed revalidation must retain the approval");
    Alcotest.(check bool)
      "failed revalidation keeps registration approval pending"
      true
      (Option.is_some (AQ.get_pending_entry ~id:pending.id));
    (match Repo_store.find ~base_path "not-registered" with
     | Error _ -> ()
    | Ok _ -> Alcotest.fail "stale approved registration must not persist");
    set_git_origin_url repo_root "https://github.com/test/not-registered.git";
    let operator_registered =
      { (sample_repo ~base_path "not-registered") with
        url = "https://github.com/test/not-registered.git"
      ; local_path = canonical_path repo_root
      ; keepers = [ keeper_id ]
      }
    in
    write_repositories base_path [ operator_registered ];
    (match AQ.resolve ~id:pending.id ~decision:Agent_sdk.Hooks.Approve with
     | Ok () -> ()
     | Error err -> Alcotest.fail (AQ.resolve_error_to_string err));
    match Repo_store.find ~base_path "not-registered" with
    | Ok _ -> ()
    | Error detail -> Alcotest.fail ("retry did not persist registration: " ^ detail))
;;

let test_unregistered_clone_matching_existing_remote_requests_alias () =
  if not (git_available ()) then Alcotest.skip ()
  else (
    reset_approval_state ();
    Fun.protect ~finally:reset_approval_state @@ fun () ->
    with_temp_base_path @@ fun base_path ->
    let keeper_id = "repo-alias-clone" in
    seed_keeper_meta base_path keeper_id;
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
      "verify_repository_catalog_alias"
      (string_field "requested_action" pending.input);
    Alcotest.(check string)
      "target repository"
      "masc"
      (string_field "target_repository_id" pending.input);
    Alcotest.(check string) "alias" "masc-mcp" (string_field "alias" pending.input);
    write_repositories base_path [ { registered with aliases = [ "masc-mcp" ] } ];
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
    reset_approval_state ();
    Fun.protect ~finally:reset_approval_state @@ fun () ->
    with_temp_base_path @@ fun base_path ->
    let keeper_id = "repo-direct-alias" in
    seed_keeper_meta base_path keeper_id;
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
      "verify_repository_catalog_alias"
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
    reset_approval_state ();
    Fun.protect ~finally:reset_approval_state @@ fun () ->
    with_temp_base_path @@ fun base_path ->
    let keeper_id = "repo-nested-root" in
    seed_keeper_meta base_path keeper_id;
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
      "verify_repository_catalog_review"
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
     | Error (AQ.Delivery_failed { reason; _ }) ->
       Alcotest.(check bool)
         "unresolved manual review reports missing exact catalog binding"
         true
         (contains_substring reason "repository catalog read failed")
     | Error err -> Alcotest.fail (AQ.resolve_error_to_string err)
     | Ok () -> Alcotest.fail "manual review must remain pending until catalog access is allowed");
    Alcotest.(check bool)
      "unresolved manual review remains pending"
      true
      (Option.is_some (AQ.get_pending_entry ~id:pending.id));
    let manually_registered =
      { registered with
        id = "masc-mcp"
      ; name = "masc-mcp"
      ; local_path = nested_root
      }
    in
    let wrong_binding =
      { manually_registered with url = "https://github.com/wrong/repository.git" }
    in
    (match Repo_store.add ~base_path wrong_binding with
     | Ok _ -> ()
     | Error detail -> Alcotest.fail ("operator catalog update failed: " ^ detail));
    (match AQ.resolve ~id:pending.id ~decision:Agent_sdk.Hooks.Approve with
     | Error (AQ.Delivery_failed { reason; _ }) ->
       Alcotest.(check bool)
         "wrong catalog row is rejected by exact candidate binding"
         true
         (contains_substring reason "catalog binding mismatch")
     | Error err -> Alcotest.fail (AQ.resolve_error_to_string err)
     | Ok () -> Alcotest.fail "wrong repository binding must retain manual approval");
    Alcotest.(check bool)
      "wrong binding keeps manual approval pending"
      true
      (Option.is_some (AQ.get_pending_entry ~id:pending.id));
    write_repositories base_path [ registered; manually_registered ];
    (match AQ.resolve ~id:pending.id ~decision:Agent_sdk.Hooks.Approve with
     | Ok () -> ()
     | Error err -> Alcotest.fail (AQ.resolve_error_to_string err));
    Alcotest.(check bool)
      "manual review is removed after exact catalog access becomes allowed"
      false
      (Option.is_some (AQ.get_pending_entry ~id:pending.id));
    match Repo_store.find ~base_path "masc" with
    | Error detail -> Alcotest.fail ("existing repo disappeared: " ^ detail)
    | Ok repo ->
      Alcotest.(check bool)
        "manual review resolution does not auto-mutate the original repository"
        false
        (List.exists (String.equal "masc-mcp") repo.aliases))
;;

let test_alias_approval_rechecks_clone_origin () =
  if not (git_available ()) then Alcotest.skip ()
  else (
    reset_approval_state ();
    Fun.protect ~finally:reset_approval_state @@ fun () ->
    with_temp_base_path @@ fun base_path ->
    let keeper_id = "repo-alias-stale-origin" in
    seed_keeper_meta base_path keeper_id;
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
     | Error (AQ.Delivery_failed _) -> ()
     | Error err -> Alcotest.fail (AQ.resolve_error_to_string err)
     | Ok () -> Alcotest.fail "failed alias revalidation must retain the approval");
    Alcotest.(check bool)
      "failed alias revalidation keeps approval pending"
      true
      (Option.is_some (AQ.get_pending_entry ~id:pending.id));
    set_git_origin_url repo_root registered.url;
    write_repositories base_path [ { registered with aliases = [ "masc-mcp" ] } ];
    (match AQ.resolve ~id:pending.id ~decision:Agent_sdk.Hooks.Approve with
     | Ok () -> ()
     | Error err -> Alcotest.fail (AQ.resolve_error_to_string err));
    match Repo_store.find ~base_path "masc" with
    | Error detail -> Alcotest.fail ("existing repo disappeared: " ^ detail)
    | Ok repo ->
      Alcotest.(check bool)
        "retry persists alias after revalidation succeeds"
        true
        (List.exists (String.equal "masc-mcp") repo.aliases))
;;

let test_pending_record_restores_gate_after_store_before_pause_crash () =
  if not (git_available ()) then Alcotest.skip ()
  else (
    reset_approval_state ();
    Fun.protect ~finally:reset_approval_state @@ fun () ->
    with_temp_base_path @@ fun base_path ->
    let keeper_id = "repo-crash-gap" in
    seed_keeper_meta base_path keeper_id;
    write_repositories base_path [];
    let _, _ =
      request_clone_registration
        ~base_path
        ~keeper_id
        ~repository_id:"crash-gap-repo"
    in
    let pending = require_one_pending ~keeper_id in
    let operation_id = string_field "operation_id" pending.input in
    let paused_meta = read_keeper_meta base_path keeper_id in
    Alcotest.(check string)
      "durable file and typed gate share exact operation identity"
      operation_id
      (repository_gate_operation_id paused_meta);
    let ungated_meta =
      { paused_meta with
        paused = false
      ; latched_reason = None
      ; runtime = { paused_meta.runtime with last_blocker = None }
      }
    in
    write_keeper_meta_direct base_path ungated_meta;
    AQ.For_testing.reset_pending ();
    let config = Masc.Workspace.default_config base_path in
    (match Claim.restore_pending_registration_hitl ~config ungated_meta with
     | Claim.Registration_restored -> ()
     | Claim.No_registration_record -> Alcotest.fail "crash-gap record disappeared"
     | Claim.Registration_superseded -> Alcotest.fail "crash-gap record was superseded"
     | Claim.Registration_corrupt detail -> Alcotest.fail detail);
    let restored_meta = read_keeper_meta base_path keeper_id in
    Alcotest.(check bool) "restore reinstalls durable pause" true restored_meta.paused;
    Alcotest.(check string)
      "restore reuses exact operation identity"
      operation_id
      (repository_gate_operation_id restored_meta);
    let restored = require_one_pending ~keeper_id in
    Alcotest.(check string)
      "restored queue entry reuses exact operation identity"
      operation_id
      (string_field "operation_id" restored.input))
;;

let test_reject_persists_terminal_pause_and_blocks_requeue () =
  if not (git_available ()) then Alcotest.skip ()
  else (
    reset_approval_state ();
    Fun.protect ~finally:reset_approval_state @@ fun () ->
    with_temp_base_path @@ fun base_path ->
    let keeper_id = "repo-reject-terminal" in
    seed_keeper_meta base_path keeper_id;
    write_repositories base_path [];
    let _, _ =
      request_clone_registration
        ~base_path
        ~keeper_id
        ~repository_id:"rejected-repo"
    in
    let pending = require_one_pending ~keeper_id in
    (match
       AQ.resolve
         ~id:pending.id
         ~decision:(Agent_sdk.Hooks.Reject "operator denied exact registration")
     with
     | Ok () -> ()
     | Error err -> Alcotest.fail (AQ.resolve_error_to_string err));
    let rejected_meta = read_keeper_meta base_path keeper_id in
    let terminal_rejection =
      rejected_meta.paused
      &&
      match rejected_meta.latched_reason with
      | Some
          (Keeper_latched_reason.Operator_paused
            { operator_actor = Keeper_latched_reason.Hitl_rejection }) ->
        true
      | Some (Keeper_latched_reason.Operator_paused _)
      | Some _ | None -> false
    in
    Alcotest.(check bool) "Reject persists terminal HITL pause" true terminal_rejection;
    Alcotest.(check bool)
      "Reject removes terminal durable operation only after commit"
      false
      (repository_operation_record_exists base_path);
    (match
       Claim.request_repository_access
         ~keeper_id
         ~base_path
         ~repository_id:"rejected-repo"
     with
     | Claim.Access_denied detail ->
       Alcotest.(check bool)
         "same operation cannot requeue before explicit resume"
         true
         (contains_substring detail "terminally paused")
     | Claim.Access_denied_hitl_pending _ ->
       Alcotest.fail "rejected repository operation must not requeue"
     | Claim.Access_allowed -> Alcotest.fail "unregistered rejected repository was allowed");
    Alcotest.(check int) "no replacement approval queued" 0 (AQ.pending_count ()))
;;

let test_stale_approve_preserves_dead_tombstone () =
  if not (git_available ()) then Alcotest.skip ()
  else (
    reset_approval_state ();
    Fun.protect ~finally:reset_approval_state @@ fun () ->
    with_temp_base_path @@ fun base_path ->
    let keeper_id = "repo-dead-supersedes" in
    seed_keeper_meta base_path keeper_id;
    write_repositories base_path [];
    let _, _ =
      request_clone_registration
        ~base_path
        ~keeper_id
        ~repository_id:"dead-supersedes-repo"
    in
    let pending = require_one_pending ~keeper_id in
    let gated_meta = read_keeper_meta base_path keeper_id in
    let dead_meta =
      { gated_meta with
        paused = true
      ; latched_reason = Some Keeper_latched_reason.Dead_tombstone
      ; auto_resume_after_sec = None
      ; runtime = { gated_meta.runtime with last_blocker = None }
      }
    in
    write_keeper_meta_direct base_path dead_meta;
    (match AQ.resolve ~id:pending.id ~decision:Agent_sdk.Hooks.Approve with
     | Ok () -> ()
     | Error err -> Alcotest.fail (AQ.resolve_error_to_string err));
    let authoritative = read_keeper_meta base_path keeper_id in
    let dead_preserved =
      authoritative.paused
      &&
      match authoritative.latched_reason with
      | Some Keeper_latched_reason.Dead_tombstone -> true
      | Some _ | None -> false
    in
    Alcotest.(check bool) "newer Dead tombstone wins stale Approve" true dead_preserved;
    Alcotest.(check bool)
      "stale approval terminalizes its own durable record"
      false
      (repository_operation_record_exists base_path);
    Alcotest.(check int) "stale approval is removed" 0 (AQ.pending_count ()))
;;

let test_distinct_operations_are_single_flight_per_keeper () =
  if not (git_available ()) then Alcotest.skip ()
  else (
    reset_approval_state ();
    Fun.protect ~finally:reset_approval_state @@ fun () ->
    with_temp_base_path @@ fun base_path ->
    let keeper_id = "repo-single-flight" in
    seed_keeper_meta base_path keeper_id;
    write_repositories base_path [];
    let _, _ =
      request_clone_registration
        ~base_path
        ~keeper_id
        ~repository_id:"first-repo"
    in
    let second_root =
      playground_repo_root ~base_path ~keeper_id ~repository_id:"second-repo"
    in
    init_git_repo second_root "https://github.com/test/second-repo.git";
    (match
       Claim.request_repository_access
         ~keeper_id
         ~base_path
         ~repository_id:"second-repo"
     with
     | Claim.Access_denied detail ->
       Alcotest.(check bool)
         "second exact operation reports the active single-flight owner"
         true
         (contains_substring detail "another repository operation is already pending")
     | Claim.Access_denied_hitl_pending _ ->
       Alcotest.fail "distinct repository operation must not dedupe to the first approval"
     | Claim.Access_allowed -> Alcotest.fail "second unregistered repository was allowed");
    Alcotest.(check int) "one repository approval remains" 1 (AQ.pending_count ()))
;;

let test_corrupt_record_installs_actionable_recovery_gate () =
  if not (git_available ()) then Alcotest.skip ()
  else (
    reset_approval_state ();
    Fun.protect ~finally:reset_approval_state @@ fun () ->
    with_temp_base_path @@ fun base_path ->
    let keeper_id = "repo-corrupt-recovery" in
    seed_keeper_meta base_path keeper_id;
    write_repositories base_path [];
    let _, _ =
      request_clone_registration
        ~base_path
        ~keeper_id
        ~repository_id:"corrupt-repo"
    in
    let gated_meta = read_keeper_meta base_path keeper_id in
    let durable_path = repository_operation_path base_path in
    AQ.For_testing.reset_pending ();
    write_file durable_path "{not-valid-json";
    let config = Masc.Workspace.default_config base_path in
    (match Claim.restore_pending_registration_hitl ~config gated_meta with
     | Claim.Registration_corrupt detail ->
       Alcotest.(check bool)
         "corrupt outcome keeps parse evidence"
         true
         (String.trim detail <> "")
     | Claim.No_registration_record -> Alcotest.fail "corrupt record disappeared"
     | Claim.Registration_restored -> Alcotest.fail "corrupt record was treated as valid"
     | Claim.Registration_superseded -> Alcotest.fail "corrupt record was silently dropped");
    let recovery = require_one_pending ~keeper_id in
    Alcotest.(check string)
      "corrupt record exposes dedicated operator recovery"
      "keeper_repository_registration_recovery"
      recovery.tool_name;
    let recovery_meta = read_keeper_meta base_path keeper_id in
    Alcotest.(check bool) "corrupt record remains fail-closed" true recovery_meta.paused;
    Sys.remove durable_path;
    (match AQ.resolve ~id:recovery.id ~decision:Agent_sdk.Hooks.Approve with
     | Ok () -> ()
     | Error err -> Alcotest.fail (AQ.resolve_error_to_string err));
    let resumed_meta = read_keeper_meta base_path keeper_id in
    Alcotest.(check bool)
      "operator repair and Approve clears only the corrupt recovery gate"
      false
      resumed_meta.paused)
;;

let () =
  Fs_compat.clear_fs ();
  Eio_guard.disable ();
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
        ; Alcotest.test_case
            "store-before-pause crash restores exact repository gate"
            `Quick
            test_pending_record_restores_gate_after_store_before_pause_crash
        ; Alcotest.test_case
            "Reject persists terminal pause and blocks requeue"
            `Quick
            test_reject_persists_terminal_pause_and_blocks_requeue
        ; Alcotest.test_case
            "stale Approve preserves newer Dead tombstone"
            `Quick
            test_stale_approve_preserves_dead_tombstone
        ; Alcotest.test_case
            "distinct repository operations are single-flight per keeper"
            `Quick
            test_distinct_operations_are_single_flight_per_keeper
        ; Alcotest.test_case
            "corrupt durable record exposes operator recovery gate"
            `Quick
            test_corrupt_record_installs_actionable_recovery_gate
        ] )
    ]
