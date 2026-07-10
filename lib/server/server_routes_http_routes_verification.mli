(** Server_routes_http_routes_verification — HTTP routes for the
    TLA+ verification dashboard surface.

    - [GET /api/v1/verification/requests] — pending / approved /
      rejected verification requests.
    - [GET /api/v1/verification/summary] — bucket counts.
    - [GET /api/v1/verification/specs] — TLA+ spec index.
    - [GET /api/v1/verification/tlc-results] — latest observed TLC
      log projection.
    - [POST /api/v1/verification/resolve] — dashboard-initiated
      approve/reject (bearer token required). *)

val add_routes :
  Http_server_eio.Router.t -> Http_server_eio.Router.t

val verifier_of_authenticated_actor : string -> string
(** Namespace the authenticated credential actor as an operator verifier.
    Callers must obtain the actor from [Server_auth.with_tool_auth]. *)
