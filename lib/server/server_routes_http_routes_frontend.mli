(** Server_routes_http_routes_frontend — HTTP routes for the static
    frontend assets and the canonical-host redirect path.

    Registers [/] and [/dashboard] entry points plus asset routes for
    the SPA bundle. {!canonical_loopback_location} and
    {!canonical_root_dashboard_location} are exposed as pure helpers
    so [test_http_server_eio] can lock the host-canonicalization
    contract independently of the route pipeline. *)

val add_routes :
  ?sw:Eio.Switch.t ->
  ?clock:float Eio.Time.clock_ty Eio.Resource.t ->
  port:int ->
  host:string ->
  Http_server_eio.Router.t -> Http_server_eio.Router.t

val websocket_upgrade_unavailable_reason : unit -> string option
(** [None] when same-origin [/ws] upgrades can be admitted, otherwise the
    503 response body that should be returned.  Exposed for the route policy
    regression test; production requests still go through {!add_routes}. *)

val websocket_upgrade_authorized :
  base_path:string ->
  Httpun.Request.t ->
  (Server_transport_admission.admission, Masc_domain.masc_error) result
(** Token-bound read-role admission gate for [/ws] upgrades. Same-origin never
    grants admission, while an explicit valid bearer remains sufficient for
    cross-origin/non-browser clients. [base_path] locates the auth config and
    the production caller resolves it only from the live server state.  The
    admitted credential is carried by the per-connection message closure so
    protected MCP requests reauthorize instead of trusting the upgrade alone.
    Exposed for the admission parity regression tests; production requests
    still go through {!add_routes}. *)

val canonical_loopback_location :
  default_port:int -> Httpun.Request.t -> string option
(** [Some redirect_url] when the request's [Host] header advertises a
    non-canonical loopback host that should redirect, [None] when the
    current host already matches canonical advertisement. *)

val canonical_root_dashboard_location :
  default_port:int -> Httpun.Request.t -> string option
(** Like {!canonical_loopback_location} but rewrites the path to
    [/dashboard] for root-route redirects. *)
