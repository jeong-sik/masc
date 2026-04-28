(** Server_routes_http_routes_channel_gate — HTTP routes for the
    channel-gate connector dashboard surface.

    Wires read-only operator endpoints exposing connector state
    (Discord, iMessage). Daemon-side fetch fibers are spawned under
    [~sw]; periodic refresh uses [~clock]. *)

val add_routes :
  sw:Eio.Switch.t ->
  clock:float Eio.Time.clock_ty Eio.Resource.t ->
  Http_server_eio.Router.route list ->
  Http_server_eio.Router.route list

val record_validation_error_metric :
  duration_ms:int -> string -> string -> unit
(** Record a [Validation_error] attempt against [Channel_gate_metrics]
    using the channel/room/keeper extracted from the request body
    (best-effort: invalid JSON falls back to [unknown / empty / empty]).
    Exposed so [test_channel_gate_metrics] can lock the request-metadata
    extraction contract independently from the HTTP route. *)

val resolve_connector_status_name :
  ?name:string -> ?channel:string -> unit -> string option
(** Pick the connector identity for the [/connector/status] endpoint:
    accepts the canonical [?name] form, falls back to the legacy
    [?channel] alias, returns [None] when both are empty / blank.
    Result is trimmed and lowercased. Exposed so
    [test_channel_gate_connector_routes] can pin the legacy-fallback
    contract. *)
