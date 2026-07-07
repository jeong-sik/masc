type access_result =
  | Access_allowed
  | Access_denied of string
  | Access_denied_hitl_pending of { detail : string; approval_id : string }

let repository_registration_tool_name = "keeper_repository_registration"
let repository_registration_kind = "repository_registration"
let repository_registration_disposition = "operator_action_required"
let repository_registration_reason = "repository_unregistered"

type registration_candidate =
  { repository_id : Repo_manager_types.repository_id
  ; repo_root : string
  ; origin_url : string
  ; default_branch : string
  }

type registration_operation =
  | Register_new of registration_candidate
  | Add_alias_to_existing of
      { existing_repository_id : Repo_manager_types.repository_id
      ; alias : string
      ; candidate : registration_candidate
      }
  | Manual_catalog_review of
      { reason : string
      ; candidate : registration_candidate
      }

let repository_record_of_candidate ~keeper_id candidate =
  { Repo_manager_types.id = candidate.repository_id
  ; name = candidate.repository_id
  ; url = candidate.origin_url
  ; local_path = candidate.repo_root
  ; aliases = []
  ; default_branch = candidate.default_branch
  ; keepers = [ keeper_id ]
  ; status = Repo_manager_types.Active
  ; auto_sync = false
  ; sync_interval = 0
  ; created_at = Int64.zero
  ; updated_at = Int64.zero
  }
;;

let candidate_identity_is_valid ~keeper_id candidate =
  let repo = repository_record_of_candidate ~keeper_id candidate in
  Keeper_repo_mapping.repository_url_basename_matches_identity repo
;;

let add_string_once value values =
  if List.exists (String.equal value) values then values else values @ [ value ]
;;

let canonical_url_equal left right =
  match
    ( Agent_observation.canonical_url_of_remote left
    , Agent_observation.canonical_url_of_remote right )
  with
  | Some left, Some right -> String.equal left right
  | _ -> false
;;

let origin_url_matches left right = String.equal left right || canonical_url_equal left right

let revalidate_registration_candidate candidate =
  match Repo_git.worktree_root ~local_path:candidate.repo_root with
  | Error reason -> Error ("worktree root recheck failed: " ^ reason)
  | Ok repo_root ->
    if not (String.equal repo_root candidate.repo_root)
    then
      Error
        (Printf.sprintf
           "worktree root changed from %s to %s"
           candidate.repo_root
           repo_root)
    else (
      match Repo_git.get_origin_url ~local_path:repo_root with
      | Error reason -> Error ("origin recheck failed: " ^ reason)
      | Ok origin_url ->
        if not (origin_url_matches candidate.origin_url origin_url)
        then
          Error
            (Printf.sprintf
               "origin changed from %s to %s"
               candidate.origin_url
               origin_url)
        else (
          match Repo_git.origin_head_branch ~local_path:repo_root with
          | Error reason -> Error ("origin HEAD recheck failed: " ^ reason)
          | Ok default_branch ->
            if not (String.equal default_branch candidate.default_branch)
            then
              Error
                (Printf.sprintf
                   "default branch changed from %s to %s"
                   candidate.default_branch
                   default_branch)
            else Ok { candidate with repo_root; origin_url; default_branch }))
;;

let find_existing_repository_by_origin ~base_path origin_url =
  match Repo_store.load_all ~base_path with
  | Error detail -> Error detail
  | Ok repos ->
    Ok
      (List.find_opt
         (fun (repo : Repo_manager_types.repository) ->
            canonical_url_equal repo.url origin_url)
         repos)
;;

let log_stale_approved_candidate ~keeper_id candidate detail =
  Log.Keeper.warn
    "keeper repo registration approved but git metadata recheck failed; \
     skipping catalog mutation keeper=%s repository=%s repo_root=%s \
     source=%s error=%s"
    keeper_id
    candidate.repository_id
    candidate.repo_root
    Config_dir_resolver.repositories_toml_basename
    detail
;;

let registration_operation ~keeper_id ~base_path candidate =
  match find_existing_repository_by_origin ~base_path candidate.origin_url with
  | Error reason -> Manual_catalog_review { reason; candidate }
  | Ok (Some existing) ->
    Add_alias_to_existing
      { existing_repository_id = existing.id; alias = candidate.repository_id; candidate }
  | Ok None ->
    if candidate_identity_is_valid ~keeper_id candidate then Register_new candidate
    else
      Manual_catalog_review
        { reason = "origin URL basename does not match requested repository id"
        ; candidate
        }
;;

let operation_candidate = function
  | Register_new candidate
  | Add_alias_to_existing { candidate; _ }
  | Manual_catalog_review { candidate; _ } -> candidate
;;

let operation_name = function
  | Register_new _ -> "register_repository"
  | Add_alias_to_existing _ -> "add_repository_alias"
  | Manual_catalog_review _ -> "review_repository_catalog"
;;

let persist_alias ~keeper_id ~base_path ~(existing : Repo_manager_types.repository) ~alias =
  let updated =
    { existing with
      aliases = add_string_once alias existing.aliases
    ; keepers = add_string_once keeper_id existing.keepers
    }
  in
  match Repo_store.update ~base_path existing.id updated with
  | Ok _ ->
    Log.Keeper.info
      "keeper repo alias approved keeper=%s repository=%s alias=%s source=%s"
      keeper_id
      existing.id
      alias
      Config_dir_resolver.repositories_toml_basename
  | Error detail ->
    Log.Keeper.warn
      "keeper repo alias approved but catalog update failed keeper=%s \
       repository=%s alias=%s source=%s error=%s"
      keeper_id
      existing.id
      alias
      Config_dir_resolver.repositories_toml_basename
      detail
;;

let approve_alias ~keeper_id ~base_path ~existing_repository_id ~alias ~candidate =
  match revalidate_registration_candidate candidate with
  | Error detail -> log_stale_approved_candidate ~keeper_id candidate detail
  | Ok current_candidate -> (
    match Repo_store.find ~base_path existing_repository_id with
  | Error detail ->
    Log.Keeper.warn
      "keeper repo alias approved but catalog read failed keeper=%s \
       repository=%s alias=%s source=%s error=%s"
      keeper_id
      existing_repository_id
      alias
      Config_dir_resolver.repositories_toml_basename
      detail
  | Ok existing ->
    if not (origin_url_matches existing.url current_candidate.origin_url)
    then
      Log.Keeper.warn
        "keeper repo alias approved but current clone origin does not match \
         target repository; skipping catalog mutation keeper=%s repository=%s \
         alias=%s source=%s target_origin=%s current_origin=%s"
        keeper_id
        existing.id
        alias
        Config_dir_resolver.repositories_toml_basename
        existing.url
        current_candidate.origin_url
    else persist_alias ~keeper_id ~base_path ~existing ~alias)
;;

let approve_new_registration ~keeper_id ~base_path candidate =
  match revalidate_registration_candidate candidate with
  | Error detail -> log_stale_approved_candidate ~keeper_id candidate detail
  | Ok candidate -> (
  match find_existing_repository_by_origin ~base_path candidate.origin_url with
  | Error detail ->
    Log.Keeper.warn
      "keeper repo registration approved but catalog recheck failed keeper=%s \
       repository=%s source=%s error=%s"
      keeper_id
      candidate.repository_id
      Config_dir_resolver.repositories_toml_basename
      detail
  | Ok (Some existing) ->
    persist_alias ~keeper_id ~base_path ~existing ~alias:candidate.repository_id
  | Ok None ->
    if candidate_identity_is_valid ~keeper_id candidate then (
      let repo = repository_record_of_candidate ~keeper_id candidate in
      match Repo_store.add ~base_path repo with
      | Ok _ ->
        Log.Keeper.info
          "keeper repo registration approved keeper=%s repository=%s source=%s"
          keeper_id
          candidate.repository_id
          Config_dir_resolver.repositories_toml_basename
      | Error detail ->
        Log.Keeper.warn
          "keeper repo registration approved but catalog update failed keeper=%s \
           repository=%s source=%s error=%s"
          keeper_id
          candidate.repository_id
          Config_dir_resolver.repositories_toml_basename
          detail)
    else
      Log.Keeper.warn
        "keeper repo registration approved but identity check failed keeper=%s \
         repository=%s url=%s"
        keeper_id
        candidate.repository_id
        candidate.origin_url)
;;

let apply_approved_operation ~keeper_id ~base_path = function
  | Register_new candidate -> approve_new_registration ~keeper_id ~base_path candidate
  | Add_alias_to_existing { existing_repository_id; alias; candidate } ->
    approve_alias ~keeper_id ~base_path ~existing_repository_id ~alias ~candidate
  | Manual_catalog_review { reason; candidate } ->
    Log.Keeper.warn
      "keeper repo catalog review approved but no automatic mutation is safe \
       keeper=%s repository=%s reason=%s"
      keeper_id
      candidate.repository_id
      reason
;;

let register_candidate_on_approval ~keeper_id ~base_path operation decision =
  let candidate = operation_candidate operation in
  match decision with
  | Agent_sdk.Hooks.Approve ->
    apply_approved_operation ~keeper_id ~base_path operation
  | Agent_sdk.Hooks.Reject reason ->
    Log.Keeper.info
      "keeper repo registration rejected keeper=%s repository=%s reason=%s"
      keeper_id
      candidate.repository_id
      reason
  | Agent_sdk.Hooks.Edit _ ->
    Log.Keeper.warn
      "keeper repo registration edit decision ignored keeper=%s repository=%s; \
       dashboard approval resolver supports approve/reject only"
      keeper_id
      candidate.repository_id
;;

let registration_operation_input ~keeper_id ~base_path operation =
  let candidate = operation_candidate operation in
  let operation_fields =
    match operation with
    | Register_new _ -> []
    | Add_alias_to_existing { existing_repository_id; alias; _ } ->
      [ "target_repository_id", `String existing_repository_id; "alias", `String alias ]
    | Manual_catalog_review { reason; _ } -> [ "manual_review_reason", `String reason ]
  in
  `Assoc
    ([ "kind", `String repository_registration_kind
     ; "keeper_id", `String keeper_id
     ; "repository_id", `String candidate.repository_id
     ; "policy_source", `String Config_dir_resolver.repositories_toml_basename
     ; "requested_action", `String (operation_name operation)
     ; "base_path", `String base_path
     ; "repo_root", `String candidate.repo_root
     ; "origin_url", `String candidate.origin_url
     ; "default_branch", `String candidate.default_branch
     ; "identity_valid", `Bool (candidate_identity_is_valid ~keeper_id candidate)
     ]
     @ operation_fields)
;;

let submit_registration_hitl ~keeper_id ~base_path operation =
  Keeper_approval_queue.submit_pending
    ~keeper_name:keeper_id
    ~tool_name:repository_registration_tool_name
    ~input:(registration_operation_input ~keeper_id ~base_path operation)
    ~risk_level:Keeper_approval_queue.High
    ~base_path
    ~sandbox_target:"repository_catalog"
    ~disposition:repository_registration_disposition
    ~disposition_reason:repository_registration_reason
    ~on_resolution:(register_candidate_on_approval ~keeper_id ~base_path operation)
    ()
;;

let path_for_git_probe path =
  try if Sys.file_exists path && Sys.is_directory path then path else Filename.dirname path with
  | Sys_error _ -> Filename.dirname path
;;

let registration_candidate_of_path ~repository_id ~path =
  let probe_path = path_for_git_probe path in
  match Repo_git.worktree_root ~local_path:probe_path with
  | Error reason -> Error reason
  | Ok repo_root ->
    (match Repo_git.get_origin_url ~local_path:repo_root with
     | Error reason -> Error reason
     | Ok origin_url ->
       (match Repo_git.origin_head_branch ~local_path:repo_root with
        | Error reason -> Error reason
        | Ok default_branch ->
          Ok { repository_id; repo_root; origin_url; default_branch }))
;;

let request_repository_access ~keeper_id ~base_path ~repository_id =
  match Keeper_repo_mapping.access_decision ~keeper_id ~repository_id ~base_path with
  | Keeper_repo_mapping.Access_allowed -> Access_allowed
  | Keeper_repo_mapping.Access_denied denial ->
    Access_denied (Keeper_repo_mapping.access_denial_to_string denial)
;;

let request_path_access ~keeper_id ~base_path ~path =
  match Keeper_repo_mapping.repository_resolution_of_path ~base_path ~path with
  | Keeper_repo_mapping.No_repository -> Access_allowed
  | Keeper_repo_mapping.Repository repository_id ->
    (match request_repository_access ~keeper_id ~base_path ~repository_id with
     | Access_denied detail ->
       (match registration_candidate_of_path ~repository_id ~path with
        | Ok candidate ->
          let operation = registration_operation ~keeper_id ~base_path candidate in
          let approval_id = submit_registration_hitl ~keeper_id ~base_path operation in
          Access_denied_hitl_pending { detail; approval_id }
        | Error reason ->
          Log.Keeper.warn
            "keeper repo registration candidate unavailable keeper=%s repository=%s \
             path=%s error=%s"
            keeper_id
            repository_id
            path
            reason;
          Access_denied detail)
     | (Access_allowed | Access_denied_hitl_pending _) as result -> result)
  | Keeper_repo_mapping.Repository_identity_mismatch mismatch ->
    Access_denied (Keeper_repo_mapping.repository_identity_mismatch_message mismatch)
  | Keeper_repo_mapping.Repository_store_error detail ->
    Access_denied
      (Printf.sprintf
         "Repository store load failed while validating keeper %s path %s: %s"
         keeper_id
         path
         detail)
;;

let tool_response_json ~path = function
  | Access_allowed ->
    `Assoc [ "ok", `Bool true; "path", `String path ]
  | Access_denied detail ->
    `Assoc
      [ "ok", `Bool false
      ; "error", `String detail
      ; "path", `String path
      ; ( "deterministic_retry"
        , `Assoc
            [ "reason", `String "policy_blocked"
            ; "retry_same_args", `Bool false
            ] )
      ]
  | Access_denied_hitl_pending { detail; approval_id } ->
    `Assoc
      [ "ok", `Bool false
      ; "error", `String detail
      ; "path", `String path
      ; ( "approval_pending"
        , `Assoc
            [ "id", `String approval_id
            ; "kind", `String repository_registration_kind
            ; "non_blocking", `Bool true
            ] )
      ; ( "deterministic_retry"
        , `Assoc
            [ "reason", `String "policy_blocked"
            ; "retry_same_args", `Bool false
            ] )
      ]
;;
