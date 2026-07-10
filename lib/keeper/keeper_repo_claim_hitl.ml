type access_result =
  | Access_allowed
  | Access_denied of string
  | Access_denied_hitl_pending of { detail : string; approval_id : string }

type registration_restore_outcome =
  | No_registration_record
  | Registration_restored
  | Registration_superseded
  | Registration_corrupt of string

let repository_registration_tool_name = "keeper_repository_registration"
let repository_registration_recovery_tool_name =
  "keeper_repository_registration_recovery"
;;
let repository_registration_kind = "repository_registration"
let repository_registration_disposition = "operator_action_required"
let repository_registration_reason = "repository_unregistered"
let repository_registration_next_action = "update_repository_catalog_then_approve"
let ( let* ) = Result.bind

type registration_candidate =
  { repository_id : Repo_manager_types.repository_id
  ; repo_root : string
  ; expected_repo_root : string option
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

let canonical_url_equal left right =
  match
    ( Agent_observation.canonical_url_of_remote left
    , Agent_observation.canonical_url_of_remote right )
  with
  | Some left, Some right -> String.equal left right
  | _ -> false
;;

let origin_url_matches left right = String.equal left right || canonical_url_equal left right

let normalized_root_for_compare path =
  let trimmed = String.trim path in
  let trimmed =
    if String.ends_with ~suffix:"/" trimmed
    then String.sub trimmed 0 (String.length trimmed - 1)
    else trimmed
  in
  try Unix.realpath trimmed with
  | Unix.Unix_error _ | Sys_error _ -> trimmed
;;

let candidate_expected_repo_root_mismatch candidate =
  match candidate.expected_repo_root with
  | None -> None
  | Some expected_repo_root ->
    if
      String.equal
        (normalized_root_for_compare candidate.repo_root)
        (normalized_root_for_compare expected_repo_root)
    then None
    else
      Some
        (Printf.sprintf
           "git worktree root %s does not match expected playground repository root %s"
           candidate.repo_root
           expected_repo_root)
;;

let revalidate_candidate_git_identity candidate =
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
    else
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
            else Ok { candidate with repo_root; origin_url; default_branch })
;;

let revalidate_registration_candidate candidate =
  match candidate_expected_repo_root_mismatch candidate with
  | Some reason -> Error reason
  | None -> revalidate_candidate_git_identity candidate
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

let registration_operation ~keeper_id ~base_path candidate =
  match candidate_expected_repo_root_mismatch candidate with
  | Some reason -> Manual_catalog_review { reason; candidate }
  | None -> (
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
        })
;;

let operation_candidate = function
  | Register_new candidate
  | Add_alias_to_existing { candidate; _ }
  | Manual_catalog_review { candidate; _ } -> candidate
;;

let operation_name = function
  | Register_new _ -> "verify_repository_catalog_registration"
  | Add_alias_to_existing _ -> "verify_repository_catalog_alias"
  | Manual_catalog_review _ -> "verify_repository_catalog_review"
;;

let pending_operation_schema = "masc.repository_registration_pending.v2"

let candidate_to_json candidate =
  `Assoc
    [ "repository_id", `String candidate.repository_id
    ; "repo_root", `String candidate.repo_root
    ; ( "expected_repo_root"
      , match candidate.expected_repo_root with
        | Some path -> `String path
        | None -> `Null )
    ; "origin_url", `String candidate.origin_url
    ; "default_branch", `String candidate.default_branch
    ]
;;

let registration_operation_to_json operation =
  let kind, fields =
    match operation with
    | Register_new candidate -> "register_new", [ "candidate", candidate_to_json candidate ]
    | Add_alias_to_existing { existing_repository_id; alias; candidate } ->
      ( "add_alias_to_existing"
      , [ "existing_repository_id", `String existing_repository_id
        ; "alias", `String alias
        ; "candidate", candidate_to_json candidate
        ] )
    | Manual_catalog_review { reason; candidate } ->
      ( "manual_catalog_review"
      , [ "reason", `String reason; "candidate", candidate_to_json candidate ] )
  in
  `Assoc ([ "kind", `String kind ] @ fields)
;;

let required_string fields key =
  match List.assoc_opt key fields with
  | Some (`String value) when String.trim value <> "" -> Ok value
  | Some _ -> Error (Printf.sprintf "repository pending operation field %s is invalid" key)
  | None -> Error (Printf.sprintf "repository pending operation field %s is missing" key)
;;

let candidate_of_json = function
  | `Assoc fields ->
    let* repository_id = required_string fields "repository_id" in
    let* repo_root = required_string fields "repo_root" in
    let* origin_url = required_string fields "origin_url" in
    let* default_branch = required_string fields "default_branch" in
    let* expected_repo_root =
      match List.assoc_opt "expected_repo_root" fields with
      | Some (`String path) when String.trim path <> "" -> Ok (Some path)
      | Some `Null | None -> Ok None
      | Some _ ->
        Error "repository pending operation expected_repo_root must be a string or null"
    in
    Ok { repository_id; repo_root; expected_repo_root; origin_url; default_branch }
  | _ -> Error "repository pending operation candidate must be an object"
;;

let registration_operation_of_json = function
  | `Assoc fields ->
    let* kind = required_string fields "kind" in
      let* candidate =
        match List.assoc_opt "candidate" fields with
        | Some json -> candidate_of_json json
        | None -> Error "repository pending operation candidate is missing"
      in
    (match kind with
       | "register_new" -> Ok (Register_new candidate)
       | "add_alias_to_existing" ->
         let* existing_repository_id = required_string fields "existing_repository_id" in
         let* alias = required_string fields "alias" in
         Ok (Add_alias_to_existing { existing_repository_id; alias; candidate })
       | "manual_catalog_review" ->
         let* reason = required_string fields "reason" in
         Ok (Manual_catalog_review { reason; candidate })
       | _ -> Error ("unsupported repository pending operation kind: " ^ kind))
  | _ -> Error "repository pending operation must be an object"
;;

type durable_operation_status =
  | Pending
  | Approving
  | Approved
  | Rejecting of string
  | Rejected of string
  | Cancelled

type durable_operation =
  { keeper_id : string
  ; operation_id : string
  ; operation : registration_operation
  ; status : durable_operation_status
  }

let operation_id ~keeper_id operation =
  let canonical =
    Yojson.Safe.to_string (registration_operation_to_json operation)
  in
  Digestif.SHA256.(digest_string (keeper_id ^ "\000" ^ canonical) |> to_hex)
;;

let durable_status_to_string = function
  | Pending -> "pending"
  | Approving -> "approving"
  | Approved -> "approved"
  | Rejecting _ -> "rejecting"
  | Rejected _ -> "rejected"
  | Cancelled -> "cancelled"
;;

let durable_status_of_json fields = function
  | "pending" -> Ok Pending
  | "approving" -> Ok Approving
  | "approved" -> Ok Approved
  | ("rejecting" | "rejected") as status ->
    let* reason = required_string fields "rejection_reason" in
    if String.equal status "rejecting" then Ok (Rejecting reason) else Ok (Rejected reason)
  | "cancelled" -> Ok Cancelled
  | value -> Error ("unsupported repository pending operation status: " ^ value)
;;

let durable_operation_to_json record =
  let rejection_fields =
    match record.status with
    | Rejecting reason | Rejected reason -> [ "rejection_reason", `String reason ]
    | Pending | Approving | Approved | Cancelled -> []
  in
  `Assoc
    ([ "schema", `String pending_operation_schema
     ; "keeper_id", `String record.keeper_id
     ; "operation_id", `String record.operation_id
     ; "status", `String (durable_status_to_string record.status)
     ; "operation", registration_operation_to_json record.operation
     ]
     @ rejection_fields)
;;

let durable_operation_of_json ~expected_keeper_id = function
  | `Assoc fields ->
    let* schema = required_string fields "schema" in
    if not (String.equal schema pending_operation_schema)
    then Error ("unsupported repository pending operation schema: " ^ schema)
    else
      let* keeper_id = required_string fields "keeper_id" in
      if not (String.equal keeper_id expected_keeper_id)
      then
        Error
          (Printf.sprintf
             "repository pending operation keeper mismatch: expected=%S actual=%S"
             expected_keeper_id
             keeper_id)
      else
        let* stored_operation_id = required_string fields "operation_id" in
        let* status_wire = required_string fields "status" in
        let* status = durable_status_of_json fields status_wire in
        let* operation =
          match List.assoc_opt "operation" fields with
          | Some json -> registration_operation_of_json json
          | None -> Error "repository pending operation payload is missing"
        in
        let expected_operation_id = operation_id ~keeper_id operation in
        if not (String.equal stored_operation_id expected_operation_id)
        then Error "repository pending operation identity digest mismatch"
        else
          Ok
            { keeper_id
            ; operation_id = stored_operation_id
            ; operation
            ; status
            }
  | _ -> Error "repository pending operation record must be an object"
;;

let pending_operation_path ~keeper_id ~base_path =
  let root = Workspace_utils.masc_dir_from_base_path ~base_path in
  let keeper_digest = Digestif.SHA256.(digest_string keeper_id |> to_hex) in
  Filename.concat
    (Filename.concat root "approvals/repository-registration")
    (keeper_digest ^ ".json")
;;

let with_durable_operation_lock ~keeper_id ~base_path f =
  let path = pending_operation_path ~keeper_id ~base_path in
  Fs_compat.mkdir_p (Filename.dirname path);
  try File_lock_eio.with_lock path f with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
    Error
      (Printf.sprintf
         "repository durable operation lock failed for keeper %s: %s"
         keeper_id
         (Printexc.to_string exn))
;;

let persist_durable_operation ~base_path record =
  let keeper_id = record.keeper_id in
  let path = pending_operation_path ~keeper_id ~base_path in
  Fs_compat.mkdir_p (Filename.dirname path);
  Keeper_fs.save_json_atomic path (durable_operation_to_json record)
;;

let load_durable_operation ~keeper_id ~base_path =
  let path = pending_operation_path ~keeper_id ~base_path in
  if not (Fs_compat.file_exists path)
  then Ok None
  else
    match Safe_ops.read_json_file_safe path with
    | Error err -> Error err
    | Ok json ->
      Result.map Option.some (durable_operation_of_json ~expected_keeper_id:keeper_id json)
;;

let durable_pending_operation ~keeper_id operation =
  { keeper_id
  ; operation_id = operation_id ~keeper_id operation
  ; operation
  ; status = Pending
  }
;;

let durable_operation_with_status record status = { record with status }

let remove_terminal_operation_if_matching ~keeper_id ~base_path ~operation_id =
  match
    with_durable_operation_lock ~keeper_id ~base_path (fun () ->
      let* current = load_durable_operation ~keeper_id ~base_path in
      match current with
      | Some record
        when String.equal record.operation_id operation_id
             && not (record.status = Pending || record.status = Approving) ->
        let path = pending_operation_path ~keeper_id ~base_path in
        (try
           Sys.remove path;
           Ok ()
         with
         | Unix.Unix_error (Unix.ENOENT, _, _) -> Ok ()
         | Sys_error detail | Unix.Unix_error (_, _, detail) ->
           Error
             (Printf.sprintf
                "failed to remove terminal repository operation %s: %s"
                path
                detail))
      | Some _ | None -> Ok ())
  with
  | Ok () -> ()
  | Error err ->
    Log.Keeper.warn
      "repository terminal operation cleanup deferred keeper=%s operation_id=%s: %s"
      keeper_id
      operation_id
      err
;;

let latched_repository_operation_id = function
  | Some (Keeper_latched_reason.Repository_registration_pending { operation_id }) ->
    Some operation_id
  | Some _ | None -> None
;;

let meta_owns_repository_gate ~operation_id (meta : Keeper_meta_contract.keeper_meta) =
  meta.paused
  &&
  match latched_repository_operation_id meta.latched_reason with
  | Some current -> String.equal current operation_id
  | None -> false
;;

let repository_gate_merge
      ~(latest : Keeper_meta_contract.keeper_meta)
      ~(caller : Keeper_meta_contract.keeper_meta)
  =
  let merged = Keeper_meta_merge.monotonic_usage_counters ~latest ~caller in
  let same_gate =
    match
      latched_repository_operation_id latest.latched_reason,
      latched_repository_operation_id caller.latched_reason
    with
    | Some left, Some right -> String.equal left right
    | Some _, None | None, Some _ | None, None -> false
  in
  if latest.paused && not same_gate
  then
    { merged with
      paused = latest.paused
    ; latched_reason = latest.latched_reason
    ; auto_resume_after_sec = latest.auto_resume_after_sec
    ; runtime = { merged.runtime with last_blocker = latest.runtime.last_blocker }
    }
  else
    { merged with
      paused = true
    ; latched_reason = caller.latched_reason
    ; auto_resume_after_sec = None
    ; runtime = { merged.runtime with last_blocker = caller.runtime.last_blocker }
    }
;;

let current_keeper_meta ~keeper_id ~base_path =
  let config = Workspace.default_config base_path in
  match Keeper_meta_store.read_meta config keeper_id with
  | Ok (Some meta) -> Ok (config, meta)
  | Ok None ->
    (match Keeper_registry.get ~base_path keeper_id with
     | Some entry -> Ok (config, entry.meta)
     | None -> Error (Printf.sprintf "keeper metadata unavailable: %s" keeper_id))
  | Error err -> Error err
;;

let persist_registration_gate ~keeper_id ~base_path ~operation_id =
  let* config, meta = current_keeper_meta ~keeper_id ~base_path in
  if meta.paused && not (meta_owns_repository_gate ~operation_id meta)
  then Ok false
  else
    let blocker =
      Keeper_meta_contract.blocker_info_of_class
        ~detail:"repository registration approval pending"
        Keeper_meta_contract.Ambiguous_post_commit_failure
    in
    let gated_meta =
      { meta with
        paused = true
      ; latched_reason =
          Some (Keeper_latched_reason.Repository_registration_pending { operation_id })
      ; auto_resume_after_sec = None
      ; updated_at = Keeper_meta_contract.now_iso ()
      ; runtime = { meta.runtime with last_blocker = Some blocker }
      }
    in
    let* persisted =
      Keeper_meta_store.write_meta_with_merge_returning
        ~merge:repository_gate_merge
        config
        gated_meta
    in
    Keeper_registry.sync_persisted_meta_if_newer ~base_path keeper_id persisted;
    Ok (meta_owns_repository_gate ~operation_id persisted)
;;

let repository_gate_resolution_merge ~operation_id
      ~(latest : Keeper_meta_contract.keeper_meta)
      ~(caller : Keeper_meta_contract.keeper_meta)
  =
  let merged = Keeper_meta_merge.monotonic_usage_counters ~latest ~caller in
  match latched_repository_operation_id latest.latched_reason with
  | Some current when String.equal current operation_id ->
    { merged with
      paused = caller.paused
    ; latched_reason = caller.latched_reason
    ; auto_resume_after_sec = caller.auto_resume_after_sec
    ; runtime = { merged.runtime with last_blocker = caller.runtime.last_blocker }
    }
  | Some _ | None ->
    { merged with
      paused = latest.paused
    ; latched_reason = latest.latched_reason
    ; auto_resume_after_sec = latest.auto_resume_after_sec
    ; runtime = { merged.runtime with last_blocker = latest.runtime.last_blocker }
    }
;;

let persist_registration_gate_replacement
      ~keeper_id
      ~base_path
      ~from_operation_id
      ~to_operation_id
  =
  let* config, meta = current_keeper_meta ~keeper_id ~base_path in
  if not (meta_owns_repository_gate ~operation_id:from_operation_id meta)
  then Error "repository recovery gate was superseded before replacement"
  else
    let replacement =
      { meta with
        paused = true
      ; latched_reason =
          Some
            (Keeper_latched_reason.Repository_registration_pending
               { operation_id = to_operation_id })
      ; auto_resume_after_sec = None
      ; updated_at = Keeper_meta_contract.now_iso ()
      }
    in
    let* persisted =
      Keeper_meta_store.write_meta_with_merge_returning
        ~merge:(repository_gate_resolution_merge ~operation_id:from_operation_id)
        config
        replacement
    in
    Keeper_registry.sync_persisted_meta_if_newer ~base_path keeper_id persisted;
    if meta_owns_repository_gate ~operation_id:to_operation_id persisted
    then Ok ()
    else Error "repository recovery gate replacement lost exact ownership"
;;

let persist_registration_resume ~keeper_id ~base_path ~operation_id =
  let* config, meta = current_keeper_meta ~keeper_id ~base_path in
  match latched_repository_operation_id meta.latched_reason with
  | Some current when String.equal current operation_id ->
    let resumed_meta =
      { meta with
        paused = false
      ; latched_reason = None
      ; auto_resume_after_sec = None
      ; updated_at = Keeper_meta_contract.now_iso ()
      ; runtime = { meta.runtime with last_blocker = None }
      }
    in
    let* persisted =
      Keeper_meta_store.write_meta_with_merge_returning
        ~merge:(repository_gate_resolution_merge ~operation_id)
        config
        resumed_meta
    in
    Keeper_registry.sync_persisted_meta_if_newer ~base_path keeper_id persisted;
    Ok ((not persisted.paused) && Option.is_none persisted.latched_reason, persisted)
  | Some _ | None -> Ok (false, meta)
;;

let persist_registration_rejection ~keeper_id ~base_path ~operation_id =
  let* config, meta = current_keeper_meta ~keeper_id ~base_path in
  match latched_repository_operation_id meta.latched_reason with
  | Some current when String.equal current operation_id ->
    let rejected_meta =
      { meta with
        paused = true
      ; latched_reason =
          Some
            (Keeper_latched_reason.Operator_paused
               { operator_actor = Keeper_latched_reason.Hitl_rejection })
      ; auto_resume_after_sec = None
      ; updated_at = Keeper_meta_contract.now_iso ()
      ; runtime = { meta.runtime with last_blocker = None }
      }
    in
    let* persisted =
      Keeper_meta_store.write_meta_with_merge_returning
        ~merge:(repository_gate_resolution_merge ~operation_id)
        config
        rejected_meta
    in
    Keeper_registry.sync_persisted_meta_if_newer ~base_path keeper_id persisted;
    let rejected =
      persisted.paused
      &&
      match persisted.latched_reason with
      | Some
          (Keeper_latched_reason.Operator_paused
            { operator_actor = Keeper_latched_reason.Hitl_rejection }) ->
        true
      | Some (Keeper_latched_reason.Operator_paused _)
      | Some _ | None -> false
    in
    Ok (rejected, persisted)
  | Some _ | None -> Ok (false, meta)
;;

type approved_operation_error =
  | Candidate_revalidation_failed of string
  | Catalog_read_failed of string
  | Target_origin_mismatch of
      { target_origin : string
      ; current_origin : string
      }
  | Manual_catalog_review_unresolved of
      { repository_id : string
      ; manual_review_reason : string
      ; access_denial : Keeper_repo_mapping.access_denial
      }
  | Manual_catalog_binding_mismatch of
      { repository_id : string
      ; field : string
      ; expected : string
      ; actual : string
      }
  | Unsupported_edit_decision

let approved_operation_error_to_string = function
  | Candidate_revalidation_failed detail ->
    "repository candidate revalidation failed: " ^ detail
  | Catalog_read_failed detail -> "repository catalog read failed: " ^ detail
  | Target_origin_mismatch { target_origin; current_origin } ->
    Printf.sprintf
      "repository target origin mismatch: target=%s current=%s"
      target_origin
      current_origin
  | Manual_catalog_review_unresolved
      { repository_id; manual_review_reason; access_denial } ->
    Printf.sprintf
      "manual repository catalog review unresolved: repository=%s reason=%s access=%s"
      repository_id
      manual_review_reason
      (Keeper_repo_mapping.access_denial_to_string access_denial)
  | Manual_catalog_binding_mismatch { repository_id; field; expected; actual } ->
    Printf.sprintf
      "manual repository catalog binding mismatch: repository=%s field=%s expected=%s actual=%s"
      repository_id
      field
      expected
      actual
  | Unsupported_edit_decision ->
    "repository registration does not support edited approval payloads"
;;

let manual_catalog_binding_mismatch
      ~base_path
      (candidate : registration_candidate)
      (repository : Repo_manager_types.repository)
  =
  let mismatch field expected actual =
    Some
      (Manual_catalog_binding_mismatch
         { repository_id = candidate.repository_id; field; expected; actual })
  in
  if not (origin_url_matches repository.url candidate.origin_url)
  then mismatch "origin_url" candidate.origin_url repository.url
  else if
    not
      (String.equal
         (normalized_root_for_compare (Repo_store.local_path ~base_path repository))
         (normalized_root_for_compare candidate.repo_root))
  then
    mismatch
      "local_path"
      candidate.repo_root
      (Repo_store.local_path ~base_path repository)
  else if not (String.equal repository.default_branch candidate.default_branch)
  then mismatch "default_branch" candidate.default_branch repository.default_branch
  else None
;;

let validate_catalog_access ~keeper_id ~base_path ~repository_id ~reason =
  match Keeper_repo_mapping.access_decision ~keeper_id ~repository_id ~base_path with
  | Keeper_repo_mapping.Access_allowed -> Ok ()
  | Keeper_repo_mapping.Access_denied access_denial ->
    Error
      (Manual_catalog_review_unresolved
         { repository_id; manual_review_reason = reason; access_denial })
;;

let validate_registered_candidate ~keeper_id ~base_path candidate =
  match revalidate_registration_candidate candidate with
  | Error detail -> Error (Candidate_revalidation_failed detail)
  | Ok current_candidate ->
    (match Repo_store.find ~base_path current_candidate.repository_id with
     | Error detail -> Error (Catalog_read_failed detail)
     | Ok repository ->
       (match manual_catalog_binding_mismatch ~base_path current_candidate repository with
        | Some error -> Error error
        | None ->
          validate_catalog_access
            ~keeper_id
            ~base_path
            ~repository_id:current_candidate.repository_id
            ~reason:"operator catalog registration not yet exact"))
;;

let validate_registered_alias
      ~keeper_id
      ~base_path
      ~existing_repository_id
      ~alias
      candidate
  =
  match revalidate_registration_candidate candidate with
  | Error detail -> Error (Candidate_revalidation_failed detail)
  | Ok current_candidate ->
    (match Repo_store.find ~base_path existing_repository_id with
     | Error detail -> Error (Catalog_read_failed detail)
     | Ok repository ->
       if not (origin_url_matches repository.url current_candidate.origin_url)
       then
         Error
           (Target_origin_mismatch
              { target_origin = repository.url
              ; current_origin = current_candidate.origin_url
              })
       else if not (List.exists (String.equal alias) repository.aliases)
       then
         Error
           (Manual_catalog_binding_mismatch
              { repository_id = existing_repository_id
              ; field = "alias"
              ; expected = alias
              ; actual = String.concat "," repository.aliases
              })
       else
         validate_catalog_access
           ~keeper_id
           ~base_path
           ~repository_id:existing_repository_id
           ~reason:"operator catalog alias not yet exact")
;;

let apply_approved_operation ~keeper_id ~base_path = function
  | Register_new candidate -> validate_registered_candidate ~keeper_id ~base_path candidate
  | Add_alias_to_existing { existing_repository_id; alias; candidate } ->
    validate_registered_alias
      ~keeper_id
      ~base_path
      ~existing_repository_id
      ~alias
      candidate
  | Manual_catalog_review { reason; candidate } ->
    (match revalidate_candidate_git_identity candidate with
     | Error detail -> Error (Candidate_revalidation_failed detail)
     | Ok current_candidate ->
       (match Repo_store.find ~base_path current_candidate.repository_id with
        | Error detail -> Error (Catalog_read_failed detail)
        | Ok repository ->
          (match manual_catalog_binding_mismatch ~base_path current_candidate repository with
           | Some error -> Error error
           | None ->
             match
               Keeper_repo_mapping.access_decision
                 ~keeper_id
                 ~repository_id:current_candidate.repository_id
                 ~base_path
             with
             | Keeper_repo_mapping.Access_allowed ->
               Log.Keeper.info
                 "keeper repo catalog review approved after exact operator catalog update \
                  keeper=%s repository=%s reason=%s"
                 keeper_id
                 current_candidate.repository_id
                 reason;
               Ok ()
             | Keeper_repo_mapping.Access_denied access_denial ->
               Log.Keeper.warn
                 "keeper repo catalog review approval retained because exact repository \
                  access remains denied keeper=%s repository=%s reason=%s access=%s"
                 keeper_id
                 current_candidate.repository_id
                 reason
                 (Keeper_repo_mapping.access_denial_to_string access_denial);
               Error
                 (Manual_catalog_review_unresolved
                    { repository_id = current_candidate.repository_id
                    ; manual_review_reason = reason
                    ; access_denial
                    }))))
;;

let reject_unsupported_edit_decision ~keeper_id operation =
  let candidate = operation_candidate operation in
  Log.Keeper.warn
    "keeper repo registration edit decision rejected keeper=%s repository=%s; \
     no typed edit contract is defined"
    keeper_id
    candidate.repository_id;
  failwith (approved_operation_error_to_string Unsupported_edit_decision)
;;

let wake_keeper_after_registration ~keeper_id ~base_path () =
  match Keeper_registry.get ~base_path keeper_id with
  | Some entry -> Atomic.set entry.fiber_wakeup true
  | None ->
    Log.Keeper.warn
      "keeper repo registration resolved but no live keeper fiber was available keeper=%s"
      keeper_id
;;

let refresh_and_wake_if_unpaused ~keeper_id ~base_path () =
  let config = Workspace.default_config base_path in
  match Keeper_meta_store.read_meta config keeper_id with
  | Error err ->
    Log.Keeper.error
      "repository registration resolved but durable keeper refresh failed keeper=%s: %s"
      keeper_id
      err
  | Ok None ->
    Log.Keeper.error
      "repository registration resolved but durable keeper metadata disappeared keeper=%s"
      keeper_id
  | Ok (Some meta) ->
    Keeper_registry.sync_persisted_meta_if_newer ~base_path keeper_id meta;
    if not meta.paused then wake_keeper_after_registration ~keeper_id ~base_path ()
;;

let registration_operation_input
      ~keeper_id
      ~base_path
      ~operation_id
      ~status
      operation
  =
  let candidate = operation_candidate operation in
  let operation_fields =
    match operation with
    | Register_new _ -> []
    | Add_alias_to_existing { existing_repository_id; alias; _ } ->
      [ "target_repository_id", `String existing_repository_id; "alias", `String alias ]
    | Manual_catalog_review { reason; _ } -> [ "manual_review_reason", `String reason ]
  in
  let decision_fields =
    [ "decision_state", `String (durable_status_to_string status) ]
    @
    match status with
    | Rejecting reason | Rejected reason -> [ "rejection_reason", `String reason ]
    | Pending | Approving | Approved | Cancelled -> []
  in
  `Assoc
    ([ "kind", `String repository_registration_kind
     ; "keeper_id", `String keeper_id
     ; "operation_id", `String operation_id
     ; "repository_id", `String candidate.repository_id
     ; "policy_source", `String Config_dir_resolver.repositories_toml_basename
     ; "requested_action", `String (operation_name operation)
	     ; "base_path", `String base_path
	     ; "repo_root", `String candidate.repo_root
     ; ( "expected_repo_root"
       , match candidate.expected_repo_root with
         | None -> `Null
         | Some expected_repo_root -> `String expected_repo_root )
	     ; "origin_url", `String candidate.origin_url
	     ; "default_branch", `String candidate.default_branch
	     ; "identity_valid", `Bool (candidate_identity_is_valid ~keeper_id candidate)
     ]
     @ decision_fields
     @ operation_fields)
;;

type matching_registration_approval =
  | No_registration_approval
  | Matching_registration_approval of string
  | Conflicting_registration_approval of string

let registration_approval_operation_id (entry : Keeper_approval_queue.pending_approval) =
  match Yojson.Safe.Util.member "operation_id" entry.input with
  | `String value when String.trim value <> "" -> Some value
  | `String _ | `Null
  | `Assoc _ | `List _ | `Int _ | `Intlit _ | `Float _ | `Bool _ -> None
;;

let existing_registration_approval ~keeper_id ~base_path ~operation_id =
  let entries =
    Keeper_approval_queue.list_pending_entries ~base_path
    |> List.filter (fun (entry : Keeper_approval_queue.pending_approval) ->
      String.equal entry.keeper_name keeper_id
      && String.equal entry.tool_name repository_registration_tool_name)
  in
  match entries with
  | [] -> No_registration_approval
  | [ entry ] ->
    (match registration_approval_operation_id entry with
     | Some current when String.equal current operation_id ->
       Matching_registration_approval entry.id
     | Some current -> Conflicting_registration_approval current
     | None -> Conflicting_registration_approval "missing-operation-id")
  | _ -> Conflicting_registration_approval "multiple-repository-approvals"
;;

let durable_operation_file_remove ~keeper_id ~base_path =
  let path = pending_operation_path ~keeper_id ~base_path in
  try
    Sys.remove path;
    Ok ()
  with
  | Unix.Unix_error (Unix.ENOENT, _, _) -> Ok ()
  | Sys_error detail -> Error detail
  | Unix.Unix_error (err, _, _) -> Error (Unix.error_message err)
;;

let current_meta_owns_repository_gate ~keeper_id ~base_path ~operation_id =
  let* _, meta = current_keeper_meta ~keeper_id ~base_path in
  Ok (meta_owns_repository_gate ~operation_id meta)
;;

type repository_resolution_outcome =
  | Resolution_applied
  | Resolution_cancelled

let approve_durable_operation ~keeper_id ~base_path ~operation_id =
  with_durable_operation_lock ~keeper_id ~base_path (fun () ->
    let* current = load_durable_operation ~keeper_id ~base_path in
    match current with
    | None -> Error "repository approval lost its durable operation record"
    | Some record when not (String.equal record.operation_id operation_id) ->
      Error
        (Printf.sprintf
           "repository approval operation changed: expected=%s actual=%s"
           operation_id
           record.operation_id)
    | Some record ->
      let cancel () =
        let* () =
          persist_durable_operation
            ~base_path
            (durable_operation_with_status record Cancelled)
        in
        Ok Resolution_cancelled
      in
      let finish_approved () =
        let* applied, _ =
          persist_registration_resume ~keeper_id ~base_path ~operation_id
        in
        if applied then Ok Resolution_applied else cancel ()
      in
      let finish_approving () =
         let* owns_gate =
           current_meta_owns_repository_gate ~keeper_id ~base_path ~operation_id
         in
         if not owns_gate
         then cancel ()
         else
           let* () =
             apply_approved_operation ~keeper_id ~base_path record.operation
             |> Result.map_error approved_operation_error_to_string
           in
           let* () =
             persist_durable_operation
               ~base_path
               (durable_operation_with_status record Approved)
           in
           finish_approved ()
      in
      (match record.status with
       | Rejecting _ | Rejected _ -> Error "repository operation was already rejected"
       | Cancelled -> Ok Resolution_cancelled
       | Approved -> finish_approved ()
       | Approving -> finish_approving ()
       | Pending ->
         let* () =
           persist_durable_operation
             ~base_path
             (durable_operation_with_status record Approving)
         in
         finish_approving ()))
;;

let reject_durable_operation ~keeper_id ~base_path ~operation_id ~reason =
  with_durable_operation_lock ~keeper_id ~base_path (fun () ->
    let* current = load_durable_operation ~keeper_id ~base_path in
    match current with
    | None -> Error "repository rejection lost its durable operation record"
    | Some record when not (String.equal record.operation_id operation_id) ->
      Error
        (Printf.sprintf
           "repository rejection operation changed: expected=%s actual=%s"
           operation_id
           record.operation_id)
    | Some record ->
      let cancel () =
        let* () =
          persist_durable_operation
            ~base_path
            (durable_operation_with_status record Cancelled)
        in
        Ok Resolution_cancelled
      in
      let finish_rejected () =
        let* applied, _ =
          persist_registration_rejection ~keeper_id ~base_path ~operation_id
        in
        if applied then Ok Resolution_applied else cancel ()
      in
      let finish_rejecting () =
         let* owns_gate =
           current_meta_owns_repository_gate ~keeper_id ~base_path ~operation_id
         in
         if not owns_gate
         then cancel ()
         else
           let* () =
             persist_durable_operation
               ~base_path
               (durable_operation_with_status record (Rejected reason))
           in
           finish_rejected ()
      in
      (match record.status with
       | Approved | Approving -> Error "repository operation was already approved"
       | Cancelled -> Ok Resolution_cancelled
       | Rejected stored_reason | Rejecting stored_reason
         when not (String.equal stored_reason reason) ->
         Error "repository rejection reason contradicts the durable decision"
       | Rejected _ -> finish_rejected ()
       | Rejecting _ -> finish_rejecting ()
       | Pending ->
         let* () =
           persist_durable_operation
             ~base_path
             (durable_operation_with_status record (Rejecting reason))
         in
         finish_rejecting ()))
;;

let ensure_resolution_direction ~keeper_id ~base_path ~operation_id decision =
  with_durable_operation_lock ~keeper_id ~base_path (fun () ->
    let* current = load_durable_operation ~keeper_id ~base_path in
    match current with
    | None -> Error "repository approval lost its durable operation record"
    | Some record when not (String.equal record.operation_id operation_id) ->
      Error "repository approval no longer owns the durable operation record"
    | Some record ->
      (match record.status, decision with
       | (Pending | Cancelled), _ -> Ok ()
       | (Approving | Approved), Agent_sdk.Hooks.Approve -> Ok ()
       | (Approving | Approved), (Agent_sdk.Hooks.Reject _ | Agent_sdk.Hooks.Edit _) ->
         Error "repository operation already has a durable Approve decision"
       | (Rejecting stored | Rejected stored), Agent_sdk.Hooks.Reject reason
         when String.equal stored reason ->
         Ok ()
       | (Rejecting _ | Rejected _),
         (Agent_sdk.Hooks.Approve | Agent_sdk.Hooks.Reject _ | Agent_sdk.Hooks.Edit _) ->
         Error "repository operation already has a different durable Reject decision")
  )
;;

let submit_registration_hitl_in_memory ~keeper_id ~base_path record =
  let operation = record.operation in
  let operation_id = record.operation_id in
  Keeper_approval_queue.submit_pending_blocking
    ~keeper_name:keeper_id
    ~tool_name:repository_registration_tool_name
    ~input:
      (registration_operation_input
         ~keeper_id
         ~base_path
         ~operation_id
         ~status:record.status
         operation)
    ~risk_level:Keeper_approval_queue.High
    ~base_path
    ~sandbox_target:"repository_catalog"
    ~disposition:repository_registration_disposition
    ~disposition_reason:repository_registration_reason
    ~on_resolution:(fun ~approval_id:_ decision ->
      (match ensure_resolution_direction ~keeper_id ~base_path ~operation_id decision with
       | Ok () -> ()
       | Error err -> failwith err);
      match decision with
      | Agent_sdk.Hooks.Edit _ ->
        reject_unsupported_edit_decision ~keeper_id operation
      | Agent_sdk.Hooks.Approve ->
        Keeper_approval_queue.blocking_resolution_plan
          ~effect_key:(repository_registration_kind ^ ":" ^ operation_id)
          ~commit:(fun () ->
            let outcome =
              match approve_durable_operation ~keeper_id ~base_path ~operation_id with
              | Ok outcome -> outcome
              | Error err -> failwith ("repository registration approval failed: " ^ err)
            in
            fun () ->
              remove_terminal_operation_if_matching ~keeper_id ~base_path ~operation_id;
              (match outcome with
               | Resolution_applied ->
                 refresh_and_wake_if_unpaused ~keeper_id ~base_path ()
               | Resolution_cancelled -> ()))
      | Agent_sdk.Hooks.Reject reason ->
        Keeper_approval_queue.blocking_resolution_plan
          ~effect_key:(repository_registration_kind ^ ":" ^ operation_id)
          ~commit:(fun () ->
            let outcome =
              match
                reject_durable_operation
                  ~keeper_id
                  ~base_path
                  ~operation_id
                  ~reason
              with
              | Ok outcome -> outcome
              | Error err -> failwith ("repository registration rejection failed: " ^ err)
            in
            fun () ->
              remove_terminal_operation_if_matching ~keeper_id ~base_path ~operation_id;
              (match outcome with
               | Resolution_cancelled -> ()
               | Resolution_applied ->
                 refresh_and_wake_if_unpaused ~keeper_id ~base_path ();
                 Log.Keeper.info
                   "keeper repo registration rejected keeper=%s repository=%s reason=%s"
                   keeper_id
                   (operation_candidate operation).repository_id
                   reason)))
    ()
;;

let corrupt_registration_operation_id ~keeper_id =
  let digest =
    Digestif.SHA256.(digest_string ("corrupt-repository-operation\000" ^ keeper_id) |> to_hex)
  in
  "corrupt-" ^ digest
;;

let existing_registration_recovery_approval ~keeper_id ~base_path ~operation_id =
  Keeper_approval_queue.list_pending_entries ~base_path
  |> List.find_map (fun (entry : Keeper_approval_queue.pending_approval) ->
    if
      String.equal entry.keeper_name keeper_id
      && String.equal entry.tool_name repository_registration_recovery_tool_name
      && Option.equal
           String.equal
           (registration_approval_operation_id entry)
           (Some operation_id)
    then Some entry.id
    else None)
;;

let submit_corrupt_registration_recovery ~keeper_id ~base_path ~operation_id ~detail =
  Keeper_approval_queue.submit_pending_blocking
    ~keeper_name:keeper_id
    ~tool_name:repository_registration_recovery_tool_name
    ~input:
      (`Assoc
         [ "kind", `String "repository_registration_recovery"
         ; "keeper_id", `String keeper_id
         ; "operation_id", `String operation_id
         ; "durable_path", `String (pending_operation_path ~keeper_id ~base_path)
         ; "error_detail", `String detail
         ; "required_action", `String "repair_or_remove_corrupt_record_then_approve"
         ])
    ~risk_level:Keeper_approval_queue.Critical
    ~base_path
    ~sandbox_target:"repository_catalog"
    ~disposition:repository_registration_disposition
    ~disposition_reason:"repository_registration_state_corrupt"
    ~on_resolution:(fun ~approval_id:_ decision ->
      match decision with
      | Agent_sdk.Hooks.Edit _ | Agent_sdk.Hooks.Reject _ ->
        failwith
          "corrupt repository recovery supports Approve only after the durable record is repaired or removed"
      | Agent_sdk.Hooks.Approve ->
        Keeper_approval_queue.blocking_resolution_plan
          ~effect_key:(repository_registration_kind ^ ":" ^ operation_id)
          ~commit:(fun () ->
            let next_record =
              match
                with_durable_operation_lock ~keeper_id ~base_path (fun () ->
                  load_durable_operation ~keeper_id ~base_path)
              with
              | Ok record -> record
              | Error err ->
                failwith ("repository recovery record is still unreadable: " ^ err)
            in
            (match next_record with
             | None ->
               (match persist_registration_resume ~keeper_id ~base_path ~operation_id with
                | Ok (true, _) ->
                  fun () -> refresh_and_wake_if_unpaused ~keeper_id ~base_path ()
                | Ok (false, _) ->
                  failwith "repository recovery gate was superseded before resolution"
                | Error err -> failwith ("repository recovery resume failed: " ^ err))
             | Some record ->
               (match
                  persist_registration_gate_replacement
                    ~keeper_id
                    ~base_path
                    ~from_operation_id:operation_id
                    ~to_operation_id:record.operation_id
                with
                | Error err -> failwith err
                | Ok () ->
                  (match
                     existing_registration_approval
                       ~keeper_id
                       ~base_path
                       ~operation_id:record.operation_id
                   with
                   | Matching_registration_approval _ -> ()
                   | Conflicting_registration_approval current_id ->
                     failwith
                       (Printf.sprintf
                          "conflicting repository approval exists during recovery: %s"
                          current_id)
                   | No_registration_approval ->
                     ignore
                       (submit_registration_hitl_in_memory
                          ~keeper_id
                          ~base_path
                          record));
                  fun () -> ()))))
    ()
;;

let ensure_corrupt_registration_recovery ~keeper_id ~base_path ~detail =
  let operation_id = corrupt_registration_operation_id ~keeper_id in
  let* _, meta = current_keeper_meta ~keeper_id ~base_path in
  let* owns_gate =
    match meta.paused, latched_repository_operation_id meta.latched_reason with
    | true, Some current when String.equal current operation_id -> Ok true
    | true, Some current ->
      let* () =
        persist_registration_gate_replacement
          ~keeper_id
          ~base_path
          ~from_operation_id:current
          ~to_operation_id:operation_id
      in
      Ok true
    | true, None -> Ok false
    | false, Some _ | false, None ->
      persist_registration_gate ~keeper_id ~base_path ~operation_id
  in
  if not owns_gate
  then Error "keeper is paused by a different authoritative operation"
  else
    match
      existing_registration_recovery_approval ~keeper_id ~base_path ~operation_id
    with
    | Some _ -> Ok ()
    | None ->
      ignore
        (submit_corrupt_registration_recovery
           ~keeper_id
           ~base_path
           ~operation_id
           ~detail);
      Ok ()
;;

let keeper_has_terminal_hitl_rejection ~keeper_id ~base_path =
  match current_keeper_meta ~keeper_id ~base_path with
  | Error err -> Error err
  | Ok (_, meta) ->
    Ok
      (meta.paused
       &&
       match meta.latched_reason with
       | Some
           (Keeper_latched_reason.Operator_paused
             { operator_actor = Keeper_latched_reason.Hitl_rejection }) ->
         true
       | Some (Keeper_latched_reason.Operator_paused _)
       | Some _ | None -> false)
;;

let submit_registration_hitl ~keeper_id ~base_path operation =
  let requested = durable_pending_operation ~keeper_id operation in
  with_durable_operation_lock ~keeper_id ~base_path (fun () ->
    let* existing = load_durable_operation ~keeper_id ~base_path in
    match existing with
    | Some current when current.status = Pending || current.status = Approving ->
      if not (String.equal current.operation_id requested.operation_id)
      then
        Error
          (Printf.sprintf
             "another repository operation is already pending for keeper %s: %s"
             keeper_id
             current.operation_id)
      else
        let* owns_gate =
          persist_registration_gate
            ~keeper_id
            ~base_path
            ~operation_id:current.operation_id
        in
        if not owns_gate
        then Error "keeper is paused by a different authoritative operation"
        else
          (match
             existing_registration_approval
               ~keeper_id
               ~base_path
               ~operation_id:current.operation_id
           with
           | Matching_registration_approval id -> Ok id
           | Conflicting_registration_approval current_id ->
             Error
               (Printf.sprintf
                  "conflicting repository approval already exists for keeper %s: %s"
                  keeper_id
                  current_id)
           | No_registration_approval ->
             Ok (submit_registration_hitl_in_memory ~keeper_id ~base_path current))
    | Some current ->
      (match
         existing_registration_approval
           ~keeper_id
           ~base_path
           ~operation_id:current.operation_id
       with
       | Matching_registration_approval id -> Ok id
       | Conflicting_registration_approval current_id ->
         Error
           (Printf.sprintf
              "conflicting repository approval already exists for keeper %s: %s"
              keeper_id
              current_id)
       | No_registration_approval ->
         let* projection_applied =
           match current.status with
           | Approved ->
             persist_registration_resume
               ~keeper_id
               ~base_path
               ~operation_id:current.operation_id
             |> Result.map fst
           | Rejected _ ->
             persist_registration_rejection
               ~keeper_id
               ~base_path
               ~operation_id:current.operation_id
             |> Result.map fst
           | Cancelled -> Ok true
           | Pending | Approving | Rejecting _ ->
             Error "nonterminal repository operation reached terminal cleanup"
         in
         let* () =
           if projection_applied || current.status = Cancelled
           then Ok ()
           else
             persist_durable_operation
               ~base_path
               (durable_operation_with_status current Cancelled)
         in
         let* () = durable_operation_file_remove ~keeper_id ~base_path in
         let* terminal_rejection =
           keeper_has_terminal_hitl_rejection ~keeper_id ~base_path
         in
         let rejected =
           match current.status with
           | Rejected _ -> projection_applied
           | Pending | Approving | Approved | Rejecting _ | Cancelled -> false
         in
         if rejected || terminal_rejection
         then
           Error
             "keeper is terminally paused after a rejected HITL decision; explicitly resume before requesting repository registration again"
         else
           let* () = persist_durable_operation ~base_path requested in
           let* owns_gate =
             persist_registration_gate
               ~keeper_id
               ~base_path
               ~operation_id:requested.operation_id
           in
           if not owns_gate
           then Error "keeper is paused by a different authoritative operation"
           else
             Ok (submit_registration_hitl_in_memory ~keeper_id ~base_path requested))
    | None ->
      let* terminal_rejection =
        keeper_has_terminal_hitl_rejection ~keeper_id ~base_path
      in
      if terminal_rejection
      then
        Error
          "keeper is terminally paused after a rejected HITL decision; explicitly resume before requesting repository registration again"
      else
        let* () = persist_durable_operation ~base_path requested in
        let* owns_gate =
          persist_registration_gate
            ~keeper_id
            ~base_path
            ~operation_id:requested.operation_id
        in
        if not owns_gate
        then Error "keeper is paused by a different authoritative operation"
        else Ok (submit_registration_hitl_in_memory ~keeper_id ~base_path requested))
;;

let restore_pending_registration_hitl ~(config : Workspace.config)
    (meta : Keeper_meta_contract.keeper_meta) =
  let keeper_id = meta.name in
  let base_path = config.base_path in
  match
    with_durable_operation_lock ~keeper_id ~base_path (fun () ->
      let* current = load_durable_operation ~keeper_id ~base_path in
      match current with
      | None -> Ok No_registration_record
      | Some record ->
        let cancel_and_remove () =
          let* () =
            persist_durable_operation
              ~base_path
              (durable_operation_with_status record Cancelled)
          in
          let* () = durable_operation_file_remove ~keeper_id ~base_path in
          Ok Registration_superseded
        in
        let restore_active () =
           let* owns_gate =
             persist_registration_gate
               ~keeper_id
               ~base_path
               ~operation_id:record.operation_id
           in
           if not owns_gate
           then cancel_and_remove ()
           else
             (match
                existing_registration_approval
                  ~keeper_id
                  ~base_path
                  ~operation_id:record.operation_id
              with
              | Matching_registration_approval _ -> Ok Registration_restored
              | Conflicting_registration_approval current_id ->
                Error
                  (Printf.sprintf
                     "repository operation restore found conflicting queue entry keeper=%s operation_id=%s current=%s"
                     keeper_id
                     record.operation_id
                     current_id)
              | No_registration_approval ->
                let _approval_id =
                  submit_registration_hitl_in_memory ~keeper_id ~base_path record
                in
                Ok Registration_restored)
        in
        (match record.status with
         | Pending | Approving | Rejecting _ -> restore_active ()
         | Approved ->
           let* applied, _ =
             persist_registration_resume
               ~keeper_id
               ~base_path
               ~operation_id:record.operation_id
           in
           if applied
           then
             let* () = durable_operation_file_remove ~keeper_id ~base_path in
             Ok Registration_restored
           else cancel_and_remove ()
         | Rejected _ ->
           let* applied, _ =
             persist_registration_rejection
               ~keeper_id
               ~base_path
               ~operation_id:record.operation_id
           in
           if applied
           then
             let* () = durable_operation_file_remove ~keeper_id ~base_path in
             Ok Registration_restored
           else cancel_and_remove ()
         | Cancelled ->
           let* () = durable_operation_file_remove ~keeper_id ~base_path in
           Ok Registration_superseded))
  with
  | Ok outcome -> outcome
  | Error err ->
    Log.Keeper.error
      "repository registration pending state is unreadable; keeper remains fail-closed keeper=%s: %s"
      keeper_id
      err;
    (match ensure_corrupt_registration_recovery ~keeper_id ~base_path ~detail:err with
     | Ok () -> ()
     | Error recovery_err ->
       Log.Keeper.error
         "repository registration corrupt-state approval could not be installed keeper=%s: %s"
         keeper_id
         recovery_err);
    Registration_corrupt err
;;

let path_for_git_probe path =
  try if Sys.file_exists path && Sys.is_directory path then path else Filename.dirname path with
  | Sys_error _ -> Filename.dirname path
;;

let registration_candidate_of_path ~repository_id ~expected_repo_root ~path =
  let probe_path = path_for_git_probe path in
  match Repo_git.worktree_root ~local_path:probe_path with
  | Error reason -> Error reason
  | Ok repo_root -> (
    match Repo_git.get_origin_url ~local_path:repo_root with
    | Error reason -> Error reason
    | Ok origin_url -> (
      match Repo_git.origin_head_branch ~local_path:repo_root with
      | Error reason -> Error reason
      | Ok default_branch ->
        Ok { repository_id; repo_root; expected_repo_root; origin_url; default_branch }))
;;

type candidate_path_state =
  | Candidate_path_absent
  | Candidate_path_directory
  | Candidate_path_invalid of string

let candidate_path_state path =
  match Unix.lstat path with
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> Candidate_path_absent
  | exception Unix.Unix_error (Unix.ENOTDIR, _, _) -> Candidate_path_absent
  | exception Unix.Unix_error (err, fn, arg) ->
    Candidate_path_invalid
      (Printf.sprintf "%s(%s): %s" fn arg (Unix.error_message err))
  | _ -> (
    match Sys.is_directory path with
    | true -> Candidate_path_directory
    | false -> Candidate_path_invalid "candidate path exists but is not a directory"
    | exception Sys_error reason ->
      Candidate_path_invalid
        (Printf.sprintf "candidate path could not be inspected as directory: %s" reason))
;;

type repository_id_clone_probe =
  | No_clone_candidate
  | Clone_candidate of registration_candidate
  | Invalid_clone_candidate of string

let registration_candidate_of_repository_id ~keeper_id ~base_path ~repository_id =
  let candidate_roots =
    Keeper_sandbox_repo_path.candidate_repo_roots_no_create
      ~base_path
      ~keeper_id
      ~repository_id
  in
  let rec loop invalid = function
    | [] ->
      (match invalid with
       | [] -> No_clone_candidate
       | errors ->
         Invalid_clone_candidate
           (errors
            |> List.rev
            |> List.map (fun (path, reason) -> Printf.sprintf "%s: %s" path reason)
            |> String.concat "; "))
    | repo_root :: rest ->
      (match candidate_path_state repo_root with
       | Candidate_path_absent -> loop invalid rest
       | Candidate_path_invalid reason -> loop ((repo_root, reason) :: invalid) rest
       | Candidate_path_directory -> (
        match
          registration_candidate_of_path
            ~repository_id
            ~expected_repo_root:(Some repo_root)
            ~path:repo_root
        with
        | Ok candidate -> Clone_candidate candidate
        | Error reason -> loop ((repo_root, reason) :: invalid) rest))
  in
  loop [] candidate_roots
;;

let pending_operator_action_message detail =
  Printf.sprintf
    "%s; operator approval pending for %s"
    detail
    repository_registration_kind
;;

let deterministic_policy_blocked_fields =
  Keeper_tool_deterministic_error.(deterministic_retry_fields Policy_blocked)
;;

let repository_registration_action_fields =
  [ "operator_action_required", `Bool true
  ; "operator_action_kind", `String repository_registration_kind
  ; "operator_action_reason", `String repository_registration_reason
  ; "recoverability", `String repository_registration_disposition
  ; "next_action", `String repository_registration_next_action
  ]
;;

let repository_registration_lane_policy = Keeper_approval_queue.Blocking

let approval_pending_json approval_id =
  let non_blocking =
    match repository_registration_lane_policy with
    | Keeper_approval_queue.Nonblocking -> true
    | Keeper_approval_queue.Blocking -> false
  in
  `Assoc
    [ "id", `String approval_id
    ; "kind", `String repository_registration_kind
    ; "reason", `String repository_registration_reason
    ; ( "lane_policy"
      , `String
          (Keeper_approval_queue.lane_policy_to_string
             repository_registration_lane_policy) )
    ; "non_blocking", `Bool non_blocking
    ]
;;

let request_repository_access ~keeper_id ~base_path ~repository_id =
  match Keeper_repo_mapping.access_decision ~keeper_id ~repository_id ~base_path with
  | Keeper_repo_mapping.Access_allowed -> Access_allowed
  | Keeper_repo_mapping.Access_denied denial ->
    let detail = Keeper_repo_mapping.access_denial_to_string denial in
    (match denial with
     | Keeper_repo_mapping.Access_denied_unregistered_repository repository_id ->
       (match
          registration_candidate_of_repository_id ~keeper_id ~base_path ~repository_id
        with
        | Clone_candidate candidate ->
          let operation = registration_operation ~keeper_id ~base_path candidate in
          (match submit_registration_hitl ~keeper_id ~base_path operation with
           | Ok approval_id -> Access_denied_hitl_pending { detail; approval_id }
           | Error err ->
             Access_denied
               (Printf.sprintf
                  "%s; repository approval could not be durably submitted: %s"
                  detail
                  err))
        | No_clone_candidate -> Access_denied detail
        | Invalid_clone_candidate reason ->
          Access_denied
            (Printf.sprintf
               "%s; playground clone candidate could not be verified: %s"
               detail
               reason))
     | Access_denied_load_error _ | Access_denied_repository_store_error _ ->
       Access_denied detail)
;;

let request_path_access ~keeper_id ~base_path ~path =
  match Keeper_repo_mapping.repository_resolution_of_path ~base_path ~path with
  | Keeper_repo_mapping.No_repository -> Access_allowed
  | Keeper_repo_mapping.Repository { repository_id; repo_root = expected_repo_root } ->
    (match request_repository_access ~keeper_id ~base_path ~repository_id with
     | Access_denied detail ->
       (match registration_candidate_of_path ~repository_id ~expected_repo_root ~path with
        | Ok candidate ->
          let operation = registration_operation ~keeper_id ~base_path candidate in
          (match submit_registration_hitl ~keeper_id ~base_path operation with
           | Ok approval_id -> Access_denied_hitl_pending { detail; approval_id }
           | Error err ->
             Access_denied
               (Printf.sprintf
                  "%s; repository approval could not be durably submitted: %s"
                  detail
                  err))
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
      ([ "ok", `Bool false
       ; "error", `String detail
       ; "path", `String path
       ]
       @ deterministic_policy_blocked_fields)
  | Access_denied_hitl_pending { detail; approval_id } ->
    `Assoc
      ([ "ok", `Bool false
       ; "error", `String (pending_operator_action_message detail)
       ; "policy_error", `String detail
       ; "path", `String path
       ; "approval_pending", approval_pending_json approval_id
       ]
       @ repository_registration_action_fields
       @ deterministic_policy_blocked_fields)
;;
