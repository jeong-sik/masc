(** Server_routes_http_routes_verification — HTTP routes for the
    TLA+ verification dashboard surface.

    - [GET /api/v1/verification/requests] — pending / approved /
      rejected verification requests.
    - [GET /api/v1/verification/summary] — bucket counts.
    - [GET /api/v1/verification/specs] — TLA+ spec index.
    - [GET /api/v1/verification/tlc-results] — latest observed TLC
      log projection.

    Async Task verification is a read-only dashboard surface. *)

val add_routes :
  Http_server_eio.Router.t -> Http_server_eio.Router.t
