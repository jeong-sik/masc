(** Voice audio clip HTTP surface (RFC-0235 P1).

    See {!Server_routes_http_routes_voice} for the full contract
    (capability-token URLs, raw-bytes response, 24h TTL reaping). *)

val add_routes : Http_server_eio.Router.t -> Http_server_eio.Router.t
(** Register voice HTTP routes on the given router:

    - [GET /api/v1/voice/audio/:token] for capability-token TTS clip fetches.
    - [POST /api/v1/voice/transcribe] for admin-gated browser STT uploads.

    Plugged into the router assembly in {!Server_routes_http} alongside the
    artifacts route. *)
