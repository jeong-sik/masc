(** Voice_session_manager — multi-agent voice session tracking.

    Maintains an in-memory map [agent_id -> session] with on-disk
    mirror under [<config_path>/voice_sessions/<agent_id>.json].
    One atomic immutable map snapshot lives behind {!type-t}; the cooperative
    effect lock and file-IO helpers ([with_mutation] / [ensure_session_dir] /
    [session_file] / [save_session] / [load_session] /
    [delete_session_file]) are hidden. Mutations persist the next immutable
    session before publishing its map snapshot; readers take one lock-free
    snapshot and cannot receive mutable aliases. *)

(** {1 Types} *)

type session_status =
  | Active
  | Idle
  | Suspended
(** Wire-format strings: ["active"] / ["idle"] / ["suspended"]. See
    {!status_of_string_opt}. *)

type conversation_mode =
  | Turn_based
  | Realtime_bridge of { endpoint : string }
  | Realtime_unavailable
(** Voice loop transport mode. [Realtime_bridge] is only valid when an
    operator-provided realtime bridge endpoint is configured; MASC still owns
    session state and Keeper tool visibility, while the bridge owns live audio
    frames. [Realtime_unavailable] retains realtime intent without a configured
    endpoint and always produces a suspended session. A configured endpoint
    or an active local session does not establish audio connection health. *)

type session
(** An immutable snapshot of one agent's voice session. *)

type t
(** Session manager handle. Wraps an atomic immutable session map, a
    cooperative cross-context effect lock, and the on-disk session directory. *)

(** {1 ID + status helpers} *)

val string_of_conversation_mode : conversation_mode -> string
val transport_mode_of_conversation_mode : conversation_mode -> string
val realtime_supported : conversation_mode -> bool
(** Configured transport capability, not a live connection check. *)
val realtime_bridge_env : string

val realtime_bridge_endpoint : ?getenv:(string -> string option) -> unit -> string option
(** Configured realtime voice bridge endpoint from [MASC_VOICE_REALTIME_WS_URL].
    Blank, non-[ws://], and non-[wss://] values are treated as unavailable. *)

val realtime_bridge_public_json : ?endpoint:string -> unit -> Yojson.Safe.t
(** Keeper-visible bridge metadata. The raw websocket endpoint stays
    internal-only and is never serialized into this JSON. *)

val session_conversation_mode : session -> conversation_mode
val session_is_active : session -> bool
(** Whether the local lifecycle status is [Active]. A registered Idle or
    Suspended session is retained but inactive; this is not audio health. *)

(** {1 JSON conversion} *)

val session_to_json : session -> Yojson.Safe.t
(** Includes the durable session fields plus the dashboard/keeper-visible
    voice-loop contract. Realtime bridge JSON exposes configured metadata only;
    the raw websocket endpoint is intentionally redacted. *)

val voice_loop_json : session_active:bool -> conversation_mode -> Yojson.Safe.t

(** {1 Lifecycle} *)

val create : config_path:string -> t
(** Initialises an empty manager. Session identifiers use the shared
    cryptographic [Random_id] boundary. Does not load existing sessions from
    disk — call {!restore} for that. *)

val start_session :
  t -> agent_id:string -> ?voice:string -> ?conversation_mode:conversation_mode -> unit -> session
(** Re-activates an existing session if one is registered for
    [agent_id]; otherwise creates a fresh session with [voice]
    (defaulting to [Voice_bridge.get_voice_for_agent agent_id]) and
    persists it to disk. [Realtime_unavailable] suspends both new and existing
    sessions while preserving realtime intent. *)

val end_session : t -> agent_id:string -> bool
(** [true] if a session was removed, [false] if [agent_id] had none. *)

(** {1 Query} *)

val get_session : t -> agent_id:string -> session option
val list_sessions : t -> session list
val session_count : t -> int

(** {1 Activity tracking} *)

val increment_turn : t -> agent_id:string -> unit
(** Bumps [turn_count] and [last_activity]. *)

(** {1 Persistence} *)

val restore : t -> unit
(** Loads every [*.json] under the session directory into the
    in-memory map. Malformed files, unknown or missing conversation modes,
    blank session IDs and agent IDs that differ from their file name are
    skipped. Valid session ID bytes are preserved. *)

(** {1 Status} *)
