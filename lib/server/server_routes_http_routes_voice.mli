(** Voice audio clip HTTP surface (RFC-0235 P1).

    See {!Server_routes_http_routes_voice} for the full contract
    (capability-token URLs, raw-bytes response, 1h TTL reaping). *)

val add_routes : Http_server_eio.Router.t -> Http_server_eio.Router.t
(** Register [GET /api/v1/voice/audio/:token] on the given router. Plugged
    into the router assembly in {!Server_routes_http} alongside the
    artifacts route. *)
