(** Server_routes_http_routes_verification — HTTP routes for the
    TLA+ verification dashboard surface.

    - [GET /api/v1/verification/requests] — pending / approved /
      rejected verification requests.
    - [GET /api/v1/verification/summary] — bucket counts.
    - [GET /api/v1/verification/specs] — TLA+ spec index.
    - [POST /api/v1/verification/resolve] — dashboard-initiated
      approve/reject (bearer token required). *)

val add_routes :
  Http_server_eio.Router.t -> Http_server_eio.Router.t

val verifier_of_request :
  base_path:string -> Httpun.Request.t -> string
(** Derive the ["operator:<actor>"] verifier identity for a resolve
    request. Falls back to ["operator:dashboard"] when no
    sanitizable actor hint is present. Tested directly by
    [test_dashboard_http_core] for the token-owner canonicalization
    path. *)
