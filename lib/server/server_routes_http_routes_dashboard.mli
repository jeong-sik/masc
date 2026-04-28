(** Server_routes_http_routes_dashboard — HTTP routes for the
    operator dashboard surface.

    Top-level router builder for [/api/v1/broadcast],
    [/api/v1/dashboard/*], and the broader operator-facing JSON
    surface. Cascade-profile gate accessors are exposed for
    [test_cascade_catalog_runtime] to lock the runtime catalog
    contract independently of the route pipeline. *)

val add_routes :
  sw:Eio.Switch.t ->
  clock:[> float Eio.Time.clock_ty ] Eio.Resource.t ->
  Http_server_eio.Router.t -> Http_server_eio.Router.t

val available_cascade_profiles : unit -> string list
(** Snapshot of cascade profiles currently considered valid by the
    runtime gate. Recomputed on each call. *)

val invalid_cascade_profiles : unit -> (string * string list) list
(** Snapshot of [(profile_name, violations)] pairs for cascade
    profiles rejected by the runtime gate. *)
