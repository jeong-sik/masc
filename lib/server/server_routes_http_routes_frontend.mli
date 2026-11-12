(** Server_routes_http_routes_frontend — HTTP routes for the static
    frontend assets and the canonical-host redirect path.

    Registers [/] and [/dashboard] entry points plus asset routes for
    the SPA bundle. {!canonical_loopback_location} and
    {!canonical_root_dashboard_location} are exposed as pure helpers
    so [test_http_server_eio] can lock the host-canonicalization
    contract independently of the route pipeline. *)

val add_routes :
  ?clock:float Eio.Time.clock_ty Eio.Resource.t ->
  Http_server_eio.Router.t -> Http_server_eio.Router.t

val websocket_upgrade_unavailable_reason : unit -> string option
(** [None] when the [/ws] transport on the HTTP listener is enabled and
    ready, otherwise the 503 response body that should be returned.  Exposed
    for the route policy regression test; production requests still go
    through {!add_routes}. *)

val websocket_upgrade_authorized :
  base_path:string ->
  request_authority:Server_request_authority.authority ->
  Httpun.Request.t ->
  (unit, Masc_domain.masc_error) result
(** Admission for [/ws] upgrades: the two checks of a [/mcp] POST, in its
    order. The [Origin] check comes first
    ([ensure_same_origin_if_browser_request], which admits what the [/mcp]
    ingress admits): another site's [Origin] is refused whether or not the
    request carries a credential, and a native client that sends no [Origin]
    passes. Then the credential verdict ([verify_mcp_auth_for_authority]),
    with no fallback: an [Origin] header does not replace the bearer.

    A refusal is answered with the status of [http_status_of_auth_error]:
    403 for another site's [Origin] (as on [/mcp]), 401 for a missing or
    invalid credential, 403 for a credential without the permission and 503
    when the credential store cannot be read. A [/mcp] POST answers the last
    two with 401, since every auth error there is a JSON-RPC [Auth_error].

    [base_path] locates the auth config; the production caller resolves it
    from the live server state. Exposed for the admission parity regression
    tests; production requests still go through {!add_routes}. *)

val canonical_loopback_location :
  request_authority:Server_request_authority.authority ->
  Httpun.Request.t ->
  string option
(** [Some redirect_url] when the admitted authority advertises a non-canonical
    loopback host that should redirect, [None] when it already matches the
    canonical advertisement. The redirect keeps the admitted authority's
    scheme and port, or the scheme default when the request named none. *)

val canonical_root_dashboard_location :
  request_authority:Server_request_authority.authority ->
  string option
(** Like {!canonical_loopback_location} but rewrites the path to
    [/dashboard] for root-route redirects. *)
