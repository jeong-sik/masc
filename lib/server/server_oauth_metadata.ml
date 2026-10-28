(* HIGH-RISK-UNREVIEWED: OAuth discovery and resource binding. *)

let base_url authority =
  Printf.sprintf
    "%s://%s"
    (Server_request_authority.scheme authority
     |> Server_request_authority.scheme_to_string)
    (Server_request_authority.rendered authority)
;;

(* RFC 8414 section 2: the issuer has no query or fragment. The same value
   is the [iss] of every authorization response (RFC 9207 section 2), so the
   two cannot drift apart. *)
let issuer = base_url
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

(* MCP 2026-07-28 Scope Challenge Handling: a 403 names the scope the
   operation needs and points at the protected resource metadata. *)
let insufficient_scope_challenge authority scope =
  Printf.sprintf
    "Bearer error=\"insufficient_scope\", scope=%S, resource_metadata=%S"
    (Auth_oauth.scope_to_string scope)
    (protected_resource_metadata_url authority)
;;

let protected_resource_json authority =
  `Assoc
    [ "resource", `String (resource authority)
    ; "authorization_servers", `List [ `String (issuer authority) ]
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
    [ "issuer", `String (issuer authority)
    ; "authorization_endpoint", `String (authorization_endpoint authority)
    ; "token_endpoint", `String (token_endpoint authority)
    ; "registration_endpoint", `String (registration_endpoint authority)
    ; "response_types_supported", `List [ `String "code" ]
    ; "grant_types_supported", `List [ `String "authorization_code"; `String "refresh_token" ]
    ; "code_challenge_methods_supported", `List [ `String "S256" ]
    ; "authorization_response_iss_parameter_supported", `Bool true
    ; "token_endpoint_auth_methods_supported", `List [ `String "none" ]
    ; "client_id_metadata_document_supported", `Bool true
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
    Server_request_authority.listener_is_loopback authority
    && Masc_network_defaults.is_loopback_host
         (Server_request_authority.host authority)
;;

let challenge_for_authority authority =
  if loopback_authority authority
  then challenge authority
  else "Bearer"
;;
