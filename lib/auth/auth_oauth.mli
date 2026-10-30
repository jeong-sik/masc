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

type client_listing = {
  client : client;
  live_families : int;
      (** Token families issued to the client that are neither revoked nor
          past their refresh expiry. *)
}

val oauth_store_path : string -> string
(** Where the OAuth store of a base path lives. *)

val list_clients : base_path:string -> (client_listing list option, error) result
(** Every client Dynamic Client Registration stored. [None] when the base
    path has no OAuth store, which is not created. Client ID Metadata
    Document clients are not stored and are not listed. An unreadable record
    fails with its file path. *)

type client_revocation = { revoked_families : int }
(** [revoked_families] counts the live families, as {!list_clients} does.
    Families already past their refresh expiry are marked revoked too. *)

val revoke_client :
  base_path:string -> client_id:string -> (client_revocation option, error) result
(** Release a stored client's registration slot. Every token family still
    open for it is revoked, so its access and refresh tokens stop working,
    then its record is deleted; a code issued to it before can no longer be
    exchanged. [None] when no stored client has that id or the base path has
    no OAuth store. Nothing selects clients by age: the operator names the
    client (#26702). *)

type client_verification =
  | Registered_client
      (** Stored by Dynamic Client Registration; the redirect_uri equals a
          registered one. *)
  | Verified_document
      (** A Client ID Metadata Document was fetched for this request and lists
          the redirect_uri. *)
  | Unverified_document
      (** A document client on the consent form: nothing was fetched, so no
          code may be issued from this request. *)

type authorization_request = private {
  client_id : string;
  client_name : string option;
  redirect_uri : string;
  resource : string;
  scopes : scope list;
  state : string option;
  code_challenge : string;
  client_verification : client_verification;
}

type client_document_check =
  | Fetch_and_verify of
      (Auth_oauth_client_metadata.document_url -> (string, string) result)
      (** Fetch the document and require it to list the redirect_uri. *)
  | Show_unverified
      (** Fetch nothing. For the consent form, which any page can make a
          browser request, so its URL must not make this server fetch. *)

val validate_authorization_request :
  base_path:string ->
  expected_resource:string ->
  client_document:client_document_check ->
  response_type:string option ->
  client_id:string option ->
  redirect_uri:string option ->
  resource:string option ->
  scope:string option ->
  state:string option ->
  code_challenge:string option ->
  code_challenge_method:string option ->
  (authorization_request, error) result
(** A [client_id] that is an https URL names a Client ID Metadata Document
    (MCP 2026-07-28). Its [redirect_uri] must be a loopback HTTP URI. With
    [Fetch_and_verify], once the rest of the request checks out, the
    document is fetched and read with {!Auth_oauth_client_metadata}, and it
    must list the [redirect_uri], whatever its port. With [Show_unverified]
    the result is [Unverified_document] and carries no client name. Any other
    [client_id] must be one Dynamic Client Registration stored, and its
    [redirect_uri] must equal a registered one. *)

val issue_authorization_code :
  base_path:string ->
  request:authorization_request ->
  bootstrap_credential:Masc_domain.agent_credential ->
  (string, error) result
(** Mint a process-local, one-time authorization code.  The bootstrap raw
    bearer is not accepted by or retained in this function. An
    [Unverified_document] request is refused. *)

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
    [with_expected_resource] with an exact resource match. Present unreadable
    or nonregular records return a store error rather than static fallback;
    symlinks to regular records are accepted and cancellation propagates. *)

val with_expected_resource : string -> (unit -> 'a) -> 'a
(** Bind the exact admitted MCP resource for credential verification in the
    current request fiber. OAuth access tokens fail closed outside this scope. *)
