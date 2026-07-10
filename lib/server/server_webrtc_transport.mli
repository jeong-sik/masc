(** Server_webrtc_transport — WebRTC signaling +
    DataChannel transport for MASC.

    Reached via dotted call from server modules (agent_card,
    server_bootstrap_http / _loops,
    server_h2_gateway, routes_frontend,
    runtime_bootstrap, transport_metrics) and via the [module Wrtc =
    Masc.Server_webrtc_transport] alias from the WS
    + signaling regression tests.

    External surface (20 entries + 2 records):
    - {b records} ({!pending_offer}, {!peer_conn})
      reached by record-pattern access from the
      regression test suite.
    - {b enable check} ({!is_enabled}).
    - {b ICE config}
      ({!configured_ice_servers},
      {!configured_ice_server_urls}).
    - {b signaling exchange}
      ({!create_offer}, {!get_offer},
      {!accept_offer}, {!handle_offer_request},
      {!handle_answer_request}).
    - {b peer lifecycle}
      ({!mark_connected}, {!remove_peer},
      {!start_webrtc_connection}, {!send_to_peer}).
    - {b registry observation}
      ({!pending_offer_count},
      {!active_peer_count},
      {!live_webrtc_count},
      {!connected_channel_count}).
    - {b janitor}
      ({!cleanup_expired_offers}, {!cleanup_stale_peers}).
    - {b callback registration}
      ({!set_message_handler},
      {!set_connection_starter}).

    Internal helpers stay private at this boundary
    (~17 internal lets — [trim_nonempty] /
    [getenv_nonempty] / [split_csv],
    [ice_server_urls] / [parse_ice_servers_json] /
    [configured_ice_config], registries
    [pending_offers] / [active_peers] /
    [peer_webrtc_map] / [peer_channel_map],
    [registry_mutex] / [with_registry], [next_id]
    counter, [message_handler] /
    [connection_starter] forward refs,
    [normalize_candidate_string],
    [add_remote_ice_candidate]). *)

(** {1 Records} *)

type pending_offer = {
  offer_id : string;
  from_agent : string;
  ice_candidates : string list;
  dtls_fingerprint : string;
  created_at : float;
}
(** Pending signaling offer.  Returned by
    {!get_offer}; field-accessed by
    [test/test_webrtc_signaling] when verifying
    [from_agent] / [ice_candidates] round-trip. *)

type peer_conn = {
  peer_id : string;
  remote_agent : string;
  channel_label : string;
  mutable connected : bool;
  mutable last_activity : float;
}
(** Active DataChannel peer record returned by
    {!accept_offer}.  [connected] flips to [true] once
    {!mark_connected} fires for this [peer_id]; tests
    pattern-match on [peer_id] / [remote_agent]. *)

(** {1 Enable check} *)

val is_enabled : unit -> bool
(** Returns the resolved [MASC_WEBRTC_ENABLED]
    environment gate.  Off by default; flipping requires
    a process restart. *)

(** {1 ICE config} *)

val configured_ice_servers : unit -> Webrtc.Ice.ice_server list
(** Resolves [MASC_WEBRTC_ICE_SERVERS_JSON] into a list
    of {!Webrtc.Ice.ice_server} entries.  Returns
    [\[\]] on unset / parse failure. *)

val configured_ice_server_urls : unit -> string list
(** Flattens {!configured_ice_servers} to its [.urls]
    fields. *)

(** {1 Signaling exchange} *)

val create_offer :
  admission:Server_transport_admission.admission ->
  ice_candidates:string list ->
  dtls_fingerprint:string ->
  string
(** Registers a new offer under the token-bound admission and returns its
    unguessable
    [offer_id].  [ice_candidates] / [dtls_fingerprint]
    are stored verbatim for the answerer to consume. *)

val get_offer : string -> pending_offer option
(** Returns the registered {!pending_offer} for
    [offer_id], or [None] when the offer has expired or
    was never registered. *)

val accept_offer :
  offer_id:string ->
  admission:Server_transport_admission.admission ->
  (peer_conn, string) result
(** Completes the signaling exchange: drops the offer
    from the pending registry, materializes the
    {!Webrtc.Webrtc_eio.t} server-side peer, and
    registers the resulting {!peer_conn} in the active
    table.  [Error msg] when the offer is unknown or
    already accepted. *)

val handle_offer_request :
  admission:Server_transport_admission.admission ->
  string ->
  (string, string) result
(** HTTP handler for [POST /webrtc/offer] — parses the
    JSON body and returns a JSON response with the
    [offer_id] / [status:pending] envelope, or
    [Error msg] on malformed input. *)

val handle_answer_request :
  admission:Server_transport_admission.admission ->
  string ->
  (string, string) result
(** HTTP handler for [POST /webrtc/answer] — accepts an
    existing offer and returns the server's ICE
    credentials so the client can complete the handshake. *)

(** {1 Peer lifecycle} *)

val mark_connected : string -> unit
(** Flips [.connected = true] / refreshes
    [.last_activity] on the active-peer record for
    [peer_id].  No-op when the peer is not in the
    table. *)

val remove_peer : string -> unit
(** Drops the peer from every registry (active +
    webrtc + datachannel maps).  Idempotent. *)

val start_webrtc_connection :
  sw:Eio.Switch.t ->
  env:Eio_unix.Stdenv.base ->
  string ->
  unit
(** Wires the lifecycle callbacks for [peer_id] and
    starts the connection state machine.  Threads net /
    clock from the supplied [env].  No-op when the peer
    is not in {!peer_webrtc_map}. *)

val send_to_peer : string -> string -> (int, string) result
(** Pushes [msg] onto [peer_id]'s DataChannel.  On
    success returns [Ok bytes_sent].  [Error msg] when
    the peer is missing or no DataChannel has
    materialized. *)

(** {1 Registry observation} *)

val pending_offer_count : unit -> int
val active_peer_count : unit -> int
val admitted_remote_agent : string -> string option
(** Credential owner retained for inbound DataChannel authorization. This must
    match {!peer_conn.remote_agent}, never the answerer's signaling identity. *)
val live_webrtc_count : unit -> int
val connected_channel_count : unit -> int

(** {1 Janitor} *)

val cleanup_expired_offers : ?max_age_s:float -> unit -> int
(** Drops offers older than [?max_age_s] (default 60.0)
    from the pending registry.  Returns the number of
    offers expired.  Used by the periodic janitor in
    the bootstrap loops. *)

val cleanup_stale_peers : ?max_idle_s:float -> unit -> int
(** Drops active peers idle longer than [?max_idle_s]
    (default 300.0) from every WebRTC registry and closes
    their WebRTC stack.  Returns the number of peers
    removed.  Used by the periodic janitor in the
    bootstrap loops. *)

(** {1 Callback registration} *)

val set_message_handler :
  (Server_transport_admission.admission -> string -> string -> unit) -> unit
(** Installs the callback invoked on every inbound
    DataChannel message — [(peer_id, payload)].  Set
    once at server bootstrap. *)

val set_connection_starter : (string -> unit) -> unit
(** Installs the callback invoked when the bootstrap
    side decides a peer should start a connection.
    Set once at server bootstrap to avoid the circular
    dependency between this module and the bootstrap
    fiber. *)
