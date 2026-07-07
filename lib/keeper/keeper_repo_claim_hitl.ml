type access_result =
  | Access_allowed
  | Access_denied of string

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
