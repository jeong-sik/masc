(* HIGH-RISK-UNREVIEWED: OAuth discovery and resource binding. *)

let base_url authority =
  Printf.sprintf
    "%s://%s"
    (Server_request_authority.scheme authority
     |> Server_request_authority.scheme_to_string)
    (Server_request_authority.rendered authority)
;;

let resource authority = base_url authority ^ "/mcp"

let protected_resource_metadata_url authority =
  base_url authority ^ "/.well-known/oauth-protected-resource"
;;

let authorization_endpoint authority = base_url authority ^ "/oauth/authorize"
let token_endpoint authority = base_url authority ^ "/oauth/token"
let registration_endpoint authority = base_url authority ^ "/oauth/register"

let challenge authority =
  Printf.sprintf
    "Bearer resource_metadata=%S, scope=%S"
    (protected_resource_metadata_url authority)
    (Auth_oauth.scope_to_string Auth_oauth.Mcp_tools)
;;

let protected_resource_json authority =
  `Assoc
    [ "resource", `String (resource authority)
    ; "authorization_servers", `List [ `String (base_url authority) ]
    ; ( "scopes_supported"
      , `List
          (List.map
             (fun scope -> `String (Auth_oauth.scope_to_string scope))
             Auth_oauth.scopes_supported) )
    ; "bearer_methods_supported", `List [ `String "header" ]
    ]
;;

let authorization_server_json authority =
  `Assoc
    [ "issuer", `String (base_url authority)
    ; "authorization_endpoint", `String (authorization_endpoint authority)
    ; "token_endpoint", `String (token_endpoint authority)
    ; "registration_endpoint", `String (registration_endpoint authority)
    ; "response_types_supported", `List [ `String "code" ]
    ; "grant_types_supported", `List [ `String "authorization_code"; `String "refresh_token" ]
    ; "code_challenge_methods_supported", `List [ `String "S256" ]
    ; "token_endpoint_auth_methods_supported", `List [ `String "none" ]
    ; ( "scopes_supported"
      , `List
          (List.map
             (fun scope -> `String (Auth_oauth.scope_to_string scope))
             Auth_oauth.scopes_supported) )
    ]
;;

let loopback_authority authority =
  match Server_request_authority.trust_class authority with
  | Explicit_trusted_host -> false
  | Configured_bind ->
    (* One answer to "is this loopback" (#27576). *)
    Masc_network_defaults.is_loopback_host
      (Server_request_authority.host authority)
;;

let challenge_for_authority authority =
  if Auth_oauth.enabled () && loopback_authority authority
  then challenge authority
  else "Bearer"
;;
