(** Server_routes_http_routes_dashboard — HTTP routes for the
    operator dashboard surface.

    Top-level router builder for [/api/v1/broadcast],
    [/api/v1/dashboard/*], and the broader operator-facing JSON
    surface. Cascade-profile gate accessors are exposed for
    [test_cascade_catalog_runtime] to lock the runtime catalog
    contract independently of the route pipeline. *)

val add_routes :
  sw:Eio.Switch.t ->
  clock:float Eio.Time.clock_ty Eio.Resource.t ->
  Http_server_eio.Router.t -> Http_server_eio.Router.t

val available_cascade_profiles : unit -> string list
(** Snapshot of cascade profiles currently considered valid by the
    runtime gate. Recomputed on each call. *)

val invalid_cascade_profiles : unit -> (string * string list) list
(** Snapshot of [(profile_name, violations)] pairs for cascade
    profiles rejected by the runtime gate. *)

val dashboard_dev_token_path : string -> string
(** [<base_path>/.masc/auth/dashboard.token] — the canonical
    dashboard dev-token file written on boot. *)

val legacy_dashboard_dev_token_path : string -> string
(** [<base_path>/.masc/auth/dashboard-dev.token]. Exposed so the
    dashboard-keeper-routes test can locate (and clean up) the legacy
    file the runtime now removes on boot. *)

val ensure_dashboard_dev_token : string -> (string, string) result
(** Idempotent boot helper: returns the canonical dashboard dev token
    string, generating + persisting one to {!dashboard_dev_token_path}
    on first call and removing the legacy file at
    {!legacy_dashboard_dev_token_path} when present. [Error msg] when
    the auth dir is unwritable. Exposed so the dashboard-keeper-routes
    test can drive the boot path directly. *)
