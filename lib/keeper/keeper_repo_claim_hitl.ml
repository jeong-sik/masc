type access_result =
  | Access_allowed
  | Access_pending_approval of
      { approval_id : string
      ; repository_id : Repo_manager_types.repository_id
      }
  | Access_denied of string

let repository_claim_tool_name = "keeper_repo_claim_request"
let repository_claim_request_type = "keeper_repository_scope_claim"

let claim_denial_label = function
  | Keeper_repo_mapping.Access_denied_not_in_mapping _ -> "not_in_mapping"
  | Keeper_repo_mapping.Access_denied_unregistered_repository _ ->
    "unregistered_repository"
  | Keeper_repo_mapping.Access_denied_load_error _ -> "mapping_load_error"
  | Keeper_repo_mapping.Access_denied_repository_store_error _ ->
    "repository_store_error"
;;

let repository_claim_input ~keeper_id ~repository_id denial =
  `Assoc
    [ "request_type", `String repository_claim_request_type
    ; "keeper_id", `String keeper_id
    ; "repository_id", `String repository_id
    ; "denial", `String (claim_denial_label denial)
    ; "mapping_source", `String Keeper_repo_mapping.mappings_toml_basename
    ]
;;

let repository_ids_with_claim repository_ids repository_id =
  if List.exists (String.equal repository_id) repository_ids
  then repository_ids
  else repository_ids @ [ repository_id ]
;;

let grant_repository_access ~base_path ~keeper_id ~repository_id =
  match Keeper_repo_mapping.lookup_mapping ~base_path ~keeper_id with
  | Keeper_repo_mapping.Mapping_found mapping ->
    let repository_ids =
      repository_ids_with_claim mapping.repository_ids repository_id
    in
    Keeper_repo_mapping.save_mapping
      ~base_path
      (Repo_manager_types.make_keeper_repo_mapping ~keeper_id ~repository_ids)
  | Keeper_repo_mapping.Mapping_missing _ ->
    Keeper_repo_mapping.save_mapping
      ~base_path
      (Repo_manager_types.make_keeper_repo_mapping
         ~keeper_id
         ~repository_ids:[ repository_id ])
  | Keeper_repo_mapping.Mapping_load_error detail -> Error detail
;;

let on_resolution ~base_path ~keeper_id ~repository_id = function
  | Agent_sdk.Hooks.Approve -> (
    match grant_repository_access ~base_path ~keeper_id ~repository_id with
    | Ok () ->
      Log.Keeper.info
        ~keeper_name:keeper_id
        "repo claim approved keeper=%s repository=%s"
        keeper_id
        repository_id
    | Error detail ->
      Log.Keeper.warn
        ~keeper_name:keeper_id
        "repo claim approval could not update mapping keeper=%s repository=%s \
         detail=%s"
        keeper_id
        repository_id
        detail)
  | Agent_sdk.Hooks.Reject reason ->
    Log.Keeper.info
      ~keeper_name:keeper_id
      "repo claim rejected keeper=%s repository=%s reason=%s"
      keeper_id
      repository_id
      reason
  | Agent_sdk.Hooks.Edit _ ->
    Log.Keeper.warn
      ~keeper_name:keeper_id
      "repo claim edit decision ignored keeper=%s repository=%s"
      keeper_id
      repository_id
;;

let submit_claim_request ~base_path ~keeper_id ~repository_id denial =
  Keeper_approval_queue.submit_pending
    ~keeper_name:keeper_id
    ~tool_name:repository_claim_tool_name
    ~input:(repository_claim_input ~keeper_id ~repository_id denial)
    ~risk_level:Keeper_approval_queue.High
    ~base_path
    ~sandbox_target:repository_id
    ~disposition:"repo_claim_pending"
    ~disposition_reason:"keeper repository mapping requires operator approval"
    ~on_resolution:(on_resolution ~base_path ~keeper_id ~repository_id)
    ()
;;

let request_repository_access ~keeper_id ~base_path ~repository_id =
  match Keeper_repo_mapping.access_decision ~keeper_id ~repository_id ~base_path with
  | Keeper_repo_mapping.Access_allowed -> Access_allowed
  | Keeper_repo_mapping.Access_denied
      (Keeper_repo_mapping.Access_denied_not_in_mapping _ as denial) ->
    let approval_id =
      submit_claim_request ~base_path ~keeper_id ~repository_id denial
    in
    Access_pending_approval { approval_id; repository_id }
  | Keeper_repo_mapping.Access_denied denial ->
    Access_denied (Keeper_repo_mapping.access_denial_to_string denial)
;;

let request_path_access ~keeper_id ~base_path ~path =
  match Keeper_repo_mapping.repository_resolution_of_path ~base_path ~path with
  | Keeper_repo_mapping.No_repository -> Access_allowed
  | Keeper_repo_mapping.Repository repository_id ->
    request_repository_access ~keeper_id ~base_path ~repository_id
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
  | Access_pending_approval { approval_id; repository_id } ->
    `Assoc
      [ "ok", `Bool false
      ; "error", `String "repository access requires operator approval"
      ; "path", `String path
      ; "repository_id", `String repository_id
      ; "approval_id", `String approval_id
      ; ( "hitl"
        , `Assoc
            [ "status", `String "pending"
            ; "request_type", `String repository_claim_request_type
            ] )
      ; ( "deterministic_retry"
        , `Assoc
            [ "reason", `String "approval_pending"
            ; "retry_same_args", `Bool false
            ] )
      ]
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
;;
