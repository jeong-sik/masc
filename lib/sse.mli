(** Sse — Server-Sent Events hub for MASC.

    Manages SSE client sessions, event broadcasting, and external subscribers.
    Uses Atomic.t for lock-free session state and Eio.Stream for event delivery.

    @since 0.1.0 *)

(** {1 Types} *)

module SMap : Map.S with type key = string

type session_kind = Transport_metrics.sse_session_kind =
  | Observer
  | Agent_stream
  | Presence
[@@deriving tla]

type broadcast_target =
  | All
  | Observers
  | Agent_streams
  | Presence_only

type delivery_audience =
  | Broadcast_audience of broadcast_target
  | Session_audience of string

type delivery =
  { event_id : int
  ; frame : string
  ; payload : Yojson.Safe.t
  ; emitted_at : float
  ; audience : delivery_audience
  }
(** Canonical occurrence shared by the replay store and live queues.
    Its id, typed payload, wire frame, producer timestamp, and exact audience
    are allocated once. Transport adapters consume [payload] rather than
    reparsing [frame]. *)

type client = {
  id : int;
  kind : session_kind;
  event_stream : delivery Eio.Stream.t;
  last_event_id : int Atomic.t;
  created_at : float;
  last_seen_at : float Atomic.t;
}

type client_registry_state = {
  entries : client SMap.t;
  count : int;
}

type session_snapshot = {
  session_id : string;
  kind : session_kind;
  queue_depth : int;
  last_event_id : int;
  idle_seconds : float;
}

(** {1 Constants} *)

val max_clients : int
val max_buffer_size : int
val buffer_ttl_seconds : float

(** {1 Registration Authentication} *)

(** Authentication context supplied by SSE transport callers.
    [config] is the workspace base path used by [Auth] credential lookup.
    [token] is the raw bearer token presented by the connecting client,
    or [None] when no token was supplied. *)
type registration_auth = {
  config : string;
  token : string option;
}

(** Failure modes for SSE registration.  Transport callers translate these
    into typed HTTP responses and close the connection cleanly. *)
type registration_error =
  | Missing_token
  | Invalid_token of { reason : string }
  | Token_expired of { agent_name : string }
  | Auth_lookup_error of { reason : Masc_domain.masc_error }
  | Unknown_session of { session_id : string }
  | Session_expired of { session_id : string }
  | Session_owner_mismatch of { session_agent : string; token_agent : string }

val registration_error_to_string : registration_error -> string

(** {1 Session Management} *)

val register :
  ?kind:session_kind -> ?on_disconnect:(unit -> unit) ->
  auth:registration_auth -> string -> last_event_id:int ->
  (int * delivery Eio.Stream.t * string option, registration_error) result
(** [register ~auth session_id ~last_event_id] validates the supplied
    bearer token and MCP session pair before admitting the client.

    [?on_disconnect] is installed atomically with registration via
    {!set_disconnect_hook} before the client becomes broadcast-visible,
    so a concurrent queue-overflow [unregister] always finds the hook.

    On validation failure a typed [registration_error] is returned so the
    transport layer can respond with an auth error and close the connection
    without leaking a half-registered SSE client. *)

val unregister : string -> unit
val unregister_if_current : string -> int -> unit

val exists : string -> bool
val touch : string -> unit
val update_last_event_id : string -> int -> unit
val client_count : unit -> int
val client_count_by_kind : session_kind -> int
val close_all_clients : unit -> int
val cleanup_stale : ?max_age_s:float -> unit -> string list

(** {1 Events} *)

type data_payload_error = Missing_data_payload

val data_payload_of_frame : string -> (string, data_payload_error) result
(** Extracts and joins the payloads of every [data:] field in one SSE frame.
    The parser accepts the optional single space after the colon and the
    LF/CRLF line endings emitted on the wire.  A frame without a [data:]
    field is rejected; bare JSON is not an SSE frame. *)

val format_event : ?id:int -> ?event_type:string -> string -> string
(** [format_event] prefixes every logical line of [data] with [data:] so
    embedded newlines cannot escape the SSE field framing. An omitted [id]
    produces a transport-only frame and does not advance the replay cursor;
    only deliveries inside the ordered publication boundary may supply an
    [id]. *)

val format_event_yojson
  :  ?id:int
  -> ?event_type:string
  -> Yojson.Safe.t
  -> string
(** JSON counterpart of [format_event]. It writes the JSON value directly to
    the canonical SSE buffer without an intermediate string allocation. *)

val current_id : unit -> int

(** {1 Broadcast} *)

val broadcast : Yojson.Safe.t -> unit
val broadcast_to : broadcast_target -> Yojson.Safe.t -> unit
val broadcast_presence : Yojson.Safe.t -> unit
val send_to : string -> Yojson.Safe.t -> unit
val pop : string -> string option
val try_pop : string -> string option

(** {1 External Subscribers} *)

type external_event = {
  ext_frame : string;
      (** The SSE wire framing of this event. For subscribers that forward the
          frame verbatim. *)
  ext_payload : Yojson.Safe.t;
      (** The value passed to [broadcast], before framing. A subscriber that
          wants the data reads this; recovering it by parsing [ext_frame] costs
          one [Yojson.Safe.from_string] per broadcast per transport. *)
  ext_event_id : int;
  ext_emitted_at : float;  (** Broadcast time, not subscriber arrival time. *)
}

val subscribe_external :
  id:string
  -> callback:(external_event -> unit)
  -> ?is_alive:(unit -> bool)
  -> unit
  -> unit
val unsubscribe_external : string -> unit
val external_subscriber_count : unit -> int
val external_subscriber_count_with_prefix : string -> int
val reap_dead_external_subscribers : unit -> int

(** {1 Event Buffer} *)

val clients : client_registry_state Atomic.t
val buffer_event : delivery -> unit
val get_events_after_for_session :
  session_id:string -> kind:session_kind -> int -> delivery list
(** Replay-buffer lookup for one exact session. Targeted deliveries are visible
    only to their named agent-stream session; broadcasts use the same target
    and JSON-RPC filtering rules as live fan-out. *)

type replay_handoff

val create_replay_handoff : delivery list -> replay_handoff
val accept_live_delivery : replay_handoff -> delivery -> bool
(** [accept_live_delivery handoff delivery] returns [false] exactly once for
    each delivery already sent from the replay snapshot. This closes the
    register/replay/live overlap without assuming event ids commit in order. *)

val cleanup_expired_events : unit -> int
val get_events_after_for_test : int -> delivery list
val event_buffer_events_for_test : unit -> delivery list
val set_event_buffer_for_test : delivery list -> unit
val rewrite_event_buffer_for_test : unit -> unit

(** {1 Snapshots} *)

val sync_transport_snapshot : ?force:bool -> unit -> unit
(** {1 Test Hooks} *)

val register_commit_test_hook : (unit -> unit) option Atomic.t
val buffer_commit_test_hook : (unit -> unit) option Atomic.t
