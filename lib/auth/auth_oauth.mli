(** Local OAuth 2.1 authorization state for the HTTP MCP transport.

    This module owns OAuth client, grant, and token state.  It deliberately
    does not own HTTP parsing or MASC permission policy: HTTP handlers adapt
    wire values into these typed operations, while [Masc_domain.agent_role]
    remains the sole RBAC authority. *)

type scope =
  | Mcp_tools
  | Mcp_admin
[@@deriving show { with_path = false }, eq]

val scope_to_string : scope -> string
val scopes_to_string : scope list -> string
val scopes_supported : scope list

type error =
  | OAuth_disabled
  | Invalid_request of string
  | Invalid_client
  | Invalid_grant
  | Invalid_scope
  | Access_denied
  | Temporarily_unavailable
  | Store_error of string
[@@deriving show { with_path = false }]

val protocol_error_code : error -> string
(** Stable OAuth wire error code.  [Store_error] is intentionally lowered to
    [server_error] without exposing its detail. *)

val enabled : unit -> bool
val access_token_ttl_sec : unit -> int
val refresh_token_ttl_sec : unit -> int

val pkce_s256 : string -> string
(** RFC 7636 S256 transform using unpadded base64url. *)

val parse_scopes : string option -> (scope list, error) result
(** Parse a space-delimited scope request.  Missing/blank means
    [[Mcp_tools]]. Duplicate scopes are collapsed in declaration order, and
    [Mcp_admin] is canonicalized to include [Mcp_tools] because the Admin RBAC
    role includes tool permission. Durable family decoding requires that exact
    canonical closure and rejects non-canonical stored scope sets. *)

val effective_role :
  bootstrap_role:Masc_domain.agent_role ->
  scope list ->
  (Masc_domain.agent_role, error) result
(** OAuth scopes may preserve or reduce the bootstrap role, never increase it. *)

type client = {
  client_id : string;
  client_name : string option;
  redirect_uris : string list;
  created_at_unix : float;
}

val register_client :
  base_path:string ->
  client_name:string option ->
  redirect_uris:string list ->
  (client, error) result

val find_client :
  base_path:string -> client_id:string -> (client option, error) result

type authorization_request = {
  client_id : string;
  client_name : string option;
  redirect_uri : string;
  resource : string;
  scopes : scope list;
  state : string option;
  code_challenge : string;
}

val validate_authorization_request :
  base_path:string ->
  expected_resource:string ->
  response_type:string option ->
  client_id:string option ->
  redirect_uri:string option ->
  resource:string option ->
  scope:string option ->
  state:string option ->
  code_challenge:string option ->
  code_challenge_method:string option ->
  (authorization_request, error) result

val issue_authorization_code :
  base_path:string ->
  request:authorization_request ->
  bootstrap_credential:Masc_domain.agent_credential ->
  (string, error) result
(** Mint a process-local, one-time authorization code.  The bootstrap raw
    bearer is not accepted by or retained in this function. *)

type token_pair = {
  access_token : string;
  refresh_token : string;
  token_type : string;
  expires_in : int;
  scope : string;
}

val exchange_authorization_code :
  base_path:string ->
  expected_resource:string ->
  code:string ->
  client_id:string ->
  redirect_uri:string ->
  resource:string option ->
  code_verifier:string ->
  (token_pair, error) result

val rotate_refresh_token :
  base_path:string ->
  expected_resource:string ->
  refresh_token:string ->
  client_id:string ->
  scope:string option ->
  resource:string option ->
  (token_pair, error) result

val find_access_credential :
  base_path:string ->
  token:string ->
  (Masc_domain.agent_credential option, Masc_domain.masc_error) result
(** Resolve a valid current OAuth access token to the existing credential
    projection consumed by all MASC permission gates. [Ok None] means the
    token is not owned by the OAuth store; callers may try static bearer
    resolution. An owned OAuth token is accepted only inside
    [with_expected_resource] with an exact resource match. *)

val with_expected_resource : string -> (unit -> 'a) -> 'a
(** Bind the exact admitted MCP resource for credential verification in the
    current request fiber. OAuth access tokens fail closed outside this scope. *)
