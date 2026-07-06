module Claim = Masc.Keeper_repo_claim_hitl
module AQ = Masc.Keeper_approval_queue

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
     Alcotest.fail ("registered repo outside advisory mapping denied: " ^ detail));
  Alcotest.(check int) "pending count unchanged" pending_before (AQ.pending_count ())
;;

let test_unregistered_repository_does_not_request_hitl () =
  with_temp_base_path @@ fun base_path ->
  let keeper_id = "keeper-repo-claim-unregistered" in
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
   | Claim.Access_allowed -> Alcotest.fail "expected unregistered denial");
  Alcotest.(check int) "pending count unchanged" pending_before (AQ.pending_count ())
;;

let () =
  Alcotest.run
    "Keeper_repo_claim_hitl"
    [ ( "repo claim"
      , [ Alcotest.test_case
            "registered repo outside advisory mapping is allowed"
            `Quick
            test_registered_repo_outside_advisory_mapping_is_allowed
        ; Alcotest.test_case
            "unregistered repository remains fail-closed"
            `Quick
            test_unregistered_repository_does_not_request_hitl
        ] )
    ]
