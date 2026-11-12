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

type runtime_authority
(** Canonical workspace base path identity, constructed with the same
    Config_dir_resolver authority used by Keeper runtime registries. *)

val runtime_authority_exn : base_path:string -> runtime_authority
(** Rejects invalid server configuration with [Invalid_argument]. *)
val equal_runtime_authority : runtime_authority -> runtime_authority -> bool

type observer_scope
(** A workspace authority and the instance advertised to its Observer.
    Capture the instance from the source's admitted workspace before an
    operation; constructing it later does not identify that operation's owner. *)

val observer_scope : runtime_authority:runtime_authority -> instance_id:string -> observer_scope

type broadcast_target =
  | All
  | Observers
  | Runtime_observers of runtime_authority
  | Scoped_runtime_observers of observer_scope
  (** Only Observers that registered for this workspace and instance. *)
  | Presence_only
  | Runtime_presence of runtime_authority

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

type delivery_stream
(** A registered client's queue, observed whenever a delivery is taken. *)

type client = {
  id : int;
  kind : session_kind;
  agent_name : string;
  role : Masc_domain.agent_role;
  runtime_authority : runtime_authority;
  observer_scope : observer_scope option;
  event_stream : delivery_stream;
  last_event_id : int Atomic.t;
  created_at : float;
  last_seen_at : float Atomic.t;
  on_disconnect : (unit -> unit) option;
}

type client_registry_state = {
  entries : client SMap.t;
  count : int;
  queue_inventory : Sse_queue_inventory.t;
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
  | Registration_stale of { session_id : string }

val registration_error_to_string : registration_error -> string

(** {1 Session Management} *)

val fresh_client_id : unit -> int
(** Reserve a process-global connection generation. Dedicated SSE adapters
    share this allocator with registered MCP observers so presence replacement
    and disconnect compare generations from the same sequence. Reserving an
    id alone neither registers a client nor admits a credential. *)

val register :
  ?kind:session_kind -> ?on_disconnect:(unit -> unit) -> ?observer_instance_id:string ->
  auth:registration_auth -> string -> last_event_id:int ->
  (int * delivery_stream * string option, registration_error) result
(** [register ~auth session_id ~last_event_id] validates the supplied
    bearer token and MCP session pair before admitting the client.

    [last_event_id] is the client's delivery floor. One above {!current_id}
    was handed out by an earlier process, since ids only grow within one, and
    is registered as 0: every new event reaches the client.

    [?on_disconnect] is part of the client published atomically in the
    registry, so a removal wakes that client even if its session is reused.

    [?observer_instance_id] binds an Observer to its server-advertised
    workspace generation. The authenticated base path is always derived from
    [auth], not from the instance supplied by the transport. The transport
    must derive the instance from the workspace it actually admitted.

    On validation failure a typed [registration_error] is returned so the
    transport layer can respond with an auth error and close the connection
    without leaking a half-registered SSE client. *)

val register_with_client :
  ?kind:session_kind -> ?on_disconnect:(unit -> unit) -> ?observer_instance_id:string ->
  auth:registration_auth -> string -> last_event_id:int ->
  (client * client option * string option, registration_error) result
(** As {!register}, but returns the exact committed client, the replaced
    same-session client, and any cap-evicted session. An older registration
    cannot replace a newer same-session client and returns [Registration_stale]. *)

type 'admission_error standalone_observer_error =
  | Credential_refused of registration_error
  | Admission_refused of 'admission_error

val register_standalone_observer_with_client :
  ?on_disconnect:(unit -> unit) -> observer_instance_id:string ->
  admit:(Masc_domain.agent_credential -> (unit, 'admission_error) result) ->
  auth:registration_auth -> string -> last_event_id:int ->
  (client * client option * string option, 'admission_error standalone_observer_error) result
(** Register a read-only Observer on a fresh server-generated connection id.
    The transport must authenticate and admit the workspace before calling
    this entrypoint, and must not pass a client-supplied session id. Bearer
    validation, role, workspace scope and client lifetime are the same as
    {!register_with_client}; no initialized MCP session is required or created.
    [admit] receives the exact validated credential once, before any client is
    published. A refusal creates no client, queue or cap eviction. On success
    that same credential is used for publication, without a second lookup.
    Client-supplied ids and agent streams use {!register_with_client}, which
    retains the existing session, expiry and owner checks. *)

val unregister : string -> unit
val unregister_if_current : string -> int -> unit

val exists : string -> bool
val touch : string -> unit
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

val stream_capacity : int
(** The most events one client's stream holds. A client that leaves this many
    unread is closed and reconnects: the {!delivery_stream} of a
    {!register}ed client, and an MCP [subscriptions/listen] stream in
    [Server_mcp_listen_stream]. Read from
    [MASC_SSE_STREAM_CAPACITY], clamped to 8-1024, default 256. *)

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

val broadcast_to_sse_runtime_observers : runtime_authority -> Yojson.Safe.t -> unit
(** Send to [authority]'s observer sessions only, without external
    subscribers. It does not suspend: the fan-out holds a [Stdlib.Mutex],
    checks each session's queue capacity before adding to it, and
    disconnects a full session instead of waiting. A caller holding a lock
    may call it. *)
(** Send a replayable event to this runtime's SSE observers without invoking
    external subscriber callbacks on the publisher's path. *)

val broadcast_to_with_commit
  : broadcast_target -> on_committed:(unit -> unit) -> Yojson.Safe.t -> unit
(** The non-yielding callback runs once the replay buffer and live queues have
    accepted the delivery and failed sessions have been unregistered. A later
    diagnostic or external-subscriber exception does not undo that receipt.
    This callback is not a receipt for external subscribers. [Presence_only]
    and [Runtime_presence] are rejected because presence is not replayable. *)

val broadcast_encoded_to_with_receipts :
  broadcast_target -> on_fanout:(int -> unit) -> on_committed:(int -> unit) ->
  Sse_wire.encoded_json -> unit
(** Send pre-encoded replayable data. [on_fanout] runs after replay insertion
    and queue attempts, before failed sessions are unregistered. [on_committed]
    has the stronger receipt documented by {!broadcast_to_with_commit}. Both
    callbacks receive the event ID and must not yield. *)

val broadcast_presence : Yojson.Safe.t -> unit
val broadcast_presence_to_runtime : runtime_authority -> Yojson.Safe.t -> unit
(** Deliver an ephemeral presence event only to sessions in this runtime.
    It is not replay-buffered and does not reach external subscribers.
    [Runtime_presence] cannot be passed to the generic broadcast functions. *)
val send_to : string -> Yojson.Safe.t -> unit
val take_delivery : delivery_stream -> delivery
val take_delivery_nonblocking : delivery_stream -> delivery option
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

val subscribe_publication_inputs :
  runtime_authority:runtime_authority ->
  ?observer_instance_id:string ->
  (external_event -> unit) -> (unit -> unit)
(** Observe committed observer publications inside the server, including
    [broadcast_to_sse_runtime_observers] which bypasses external transports.
    This is a synchronous after-publication hook, with the same authority,
    instance and visibility selection as external subscribers. It adds no
    queue, replay log or transport registration. Presence-only publications
    never call it. Subscribe before the initial authoritative read.

    Callbacks must not block or yield. Their exceptions, cancellation
    included, are logged without replacing the original publication outcome;
    the caller's next suspension still sees its own cancellation. The returned
    unsubscribe removes only this subscription and is idempotent. *)

val subscribe_external :
  ?runtime_authority:runtime_authority ->
  ?observer_instance_id:string ->
  id:string
  -> callback:(external_event -> unit)
  -> ?is_alive:(unit -> bool)
  -> unit
  -> unit
(** An absent authority receives only unscoped broadcasts. Runtime-scoped
    broadcasts are delivered only to an exact matching authority. An
    instance-scoped event also requires the matching Observer instance;
    subscribers must derive that instance from their admitted workspace. *)
val unsubscribe_external : string -> unit
val external_subscriber_count : unit -> int
val external_subscriber_count_with_prefix : string -> int
val reap_dead_external_subscribers : unit -> int

(** {1 Event Buffer} *)

val clients : client_registry_state Atomic.t
val buffer_event : delivery -> unit
type replay_continuity =
  | Continuous  (** No event after the cursor has left the buffer. *)
  | After_gap of { missed_through : int }
      (** The buffer dropped events up to [missed_through], past the cursor,
          by count or by age. Any of them may have been for this session. *)

type replay = { deliveries : delivery list; continuity : replay_continuity }

val replay_after_for_session :
  ?runtime_authority:runtime_authority ->
  ?observer_instance_id:string ->
  ?client_id:int ->
  session_id:string -> kind:session_kind -> int -> replay
(** Replay-buffer lookup for one exact session, read from one snapshot.
    Targeted deliveries are visible only to their named agent-stream session;
    broadcasts use the same target and JSON-RPC filtering rules as live
    fan-out. Without a runtime authority, scoped events are excluded. An
    instance-scoped event also requires its Observer instance.

    Private Add-on deliveries require the exact [client_id] returned by
    {!register}, still registered under this session and [kind]. An absent or
    stale id, or a session replaced by different credentials, receives only
    unrestricted/shared events. *)

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

val sync_transport_snapshot : unit -> unit
(** {1 Test Hooks} *)

val register_commit_test_hook : (unit -> unit) option Atomic.t
val buffer_commit_test_hook : (unit -> unit) option Atomic.t
