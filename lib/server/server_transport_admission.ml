open Result.Syntax

type requirement =
  | Permission of Masc_domain.permission
  | Tool of string

type identity =
  { agent_name : string
  ; role : Masc_domain.agent_role
  }

type admission =
  { identity : identity
  ; auth_token : string
  }

let unauthorized reason message =
  Masc_domain.Auth (Masc_domain.Auth_error.Unauthorized { reason; message })
;;

let normalized_nonempty value =
  match Option.map String.trim value with
  | Some value when not (String.equal value "") -> Some value
  | Some _ | None -> None
;;

let require_strict_auth_config base_path =
  let config = Auth.load_auth_config base_path in
  if not config.Masc_domain.enabled
  then
    Error
      (unauthorized
         Masc_domain.Auth_error.Missing_token
         "Protected transport requires workspace auth to be enabled.")
  else if not config.require_token
  then
    Error
      (unauthorized
         Masc_domain.Auth_error.Missing_token
         "Protected transport requires workspace bearer auth (require_token=true).")
  else Ok ()
;;

let identity_of_token ~base_path ~token ~claimed_agent =
  let* credential = Auth.find_credential_by_token base_path ~token in
  let* () =
    match normalized_nonempty claimed_agent with
    | None -> Ok ()
    | Some claimed when String.equal claimed credential.Masc_domain.agent_name -> Ok ()
    | Some _ ->
      Error
        (unauthorized
           Masc_domain.Auth_error.Actor_mismatch
           "Bearer credential owner does not match the claimed agent.")
  in
  Ok
    { agent_name = credential.Masc_domain.agent_name
    ; role = credential.role
    }
;;

let check_requirement identity = function
  | Permission permission ->
    if Masc_domain.has_permission identity.role permission
    then Ok ()
    else
      Error
        (Masc_domain.Auth
           (Masc_domain.Auth_error.Forbidden
              { agent = identity.agent_name
              ; action = Masc_domain.permission_to_string permission
              }))
  | Tool tool_name ->
    Auth.authorize_tool_for_role
      ~agent_name:identity.agent_name
      ~role:identity.role
      ~tool_name
;;

let admit ~base_path ~token ~claimed_agent ~requirement =
  let* () = require_strict_auth_config base_path in
  let* auth_token =
    match normalized_nonempty token with
    | Some token -> Ok token
    | None ->
      Error
        (unauthorized
           Masc_domain.Auth_error.Missing_token
           "Authentication required. Provide a bearer token.")
  in
  let* identity = identity_of_token ~base_path ~token:auth_token ~claimed_agent in
  let+ () = check_requirement identity requirement in
  { identity; auth_token }
;;

let authorize ~base_path ~token ~claimed_agent ~requirement =
  let+ admission = admit ~base_path ~token ~claimed_agent ~requirement in
  admission.identity
;;
