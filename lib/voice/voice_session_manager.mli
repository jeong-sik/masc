(** Voice_session_manager — multi-agent voice session tracking.

    Maintains an in-memory map [agent_id -> session] with on-disk
    mirror under [<config_path>/voice_sessions/<agent_id>.json].
    Internal Hashtbl + [Eio.Mutex] live behind {!type-t}; the lock and
    file-IO helpers ([with_lock] / [ensure_session_dir] /
    [session_file] / [save_session] / [load_session] /
    [delete_session_file]) are hidden so callers cannot mutate session
    state without going through the lifecycle functions.

    The [session] record carries mutable fields ([last_activity],
    [turn_count], [status]) under that same lock, so {!type-session} is
    abstract — callers route reads through {!session_to_json} and
    writes through {!heartbeat} / {!increment_turn} /
    {!suspend_session} / {!resume_session}. *)

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
(** Voice loop transport mode. [Realtime_bridge] is only valid when an
    operator-provided realtime bridge endpoint is configured; MASC still owns
    session state and Keeper tool visibility, while the bridge owns live audio
    frames. *)

type session
(** A single agent's active voice session. Mutable internals
    ([last_activity], [turn_count], [status]) are guarded by the
    parent {!type-t}'s mutex. *)

type t
(** Session manager handle. Wraps a [(string, session) Hashtbl.t] +
    [Eio.Mutex.t] + on-disk session directory. *)

(** {1 ID + status helpers} *)

val generate_session_id : unit -> string
(** Random 16-byte hex prefixed with ["vs-"]. *)

val string_of_status : session_status -> string
(** Inverse of {!status_of_string_opt}. *)

val status_of_string_opt : string -> session_status option
(** [Some] only for the three wire-format names; any other input
    returns [None] (#8612 — never silently maps unknowns to [Idle]). *)

val string_of_conversation_mode : conversation_mode -> string
val transport_mode_of_conversation_mode : conversation_mode -> string
val realtime_supported : conversation_mode -> bool
val realtime_bridge_env : string

val realtime_bridge_endpoint : ?getenv:(string -> string option) -> unit -> string option
(** Configured realtime voice bridge endpoint from [MASC_VOICE_REALTIME_WS_URL].
    Blank, non-[ws://], and non-[wss://] values are treated as unavailable. *)

val realtime_bridge_public_json : ?endpoint:string -> unit -> Yojson.Safe.t
(** Keeper-visible bridge metadata. The raw websocket endpoint stays
    internal-only and is never serialized into this JSON. *)

val session_conversation_mode : session -> conversation_mode

(** {1 JSON conversion} *)

val session_to_json : session -> Yojson.Safe.t
(** Includes the durable session fields plus the dashboard/keeper-visible
    voice-loop contract. Realtime bridge JSON exposes configured metadata only;
    the raw websocket endpoint is intentionally redacted. *)

val turn_based_voice_loop_json : session_active:bool -> Yojson.Safe.t
(** Structured capability contract for the current voice implementation.
    MASC voice sessions are batch STT/TTS loops: operator audio is first
    transcribed to text, then delivered through the normal keeper turn;
    keeper output uses [keeper_voice_speak] and dashboard audio clips. *)

val voice_loop_json : session_active:bool -> conversation_mode -> Yojson.Safe.t

val session_of_json : Yojson.Safe.t -> session
(** Decode failures on individual fields raise [Yojson] exceptions.
    A corrupt [status] field defaults to [Suspended] (fail-closed —
    the session stays visible to operators instead of being skipped
    by the [Idle]-aware GC; #8612). *)

(** {1 Lifecycle} *)

val create : config_path:string -> t
(** Initialises an empty manager. Calls [Random.self_init ()] for
    {!generate_session_id}. Does not load existing sessions from
    disk — call {!restore} for that. *)

val start_session :
  t -> agent_id:string -> ?voice:string -> ?conversation_mode:conversation_mode -> unit -> session
(** Re-activates an existing session if one is registered for
    [agent_id]; otherwise creates a fresh session with [voice]
    (defaulting to [Voice_bridge.get_voice_for_agent agent_id]) and
    persists it to disk. *)

val end_session : t -> agent_id:string -> bool
(** [true] if a session was removed, [false] if [agent_id] had none. *)

val suspend_session : t -> agent_id:string -> unit
val resume_session : t -> agent_id:string -> unit

(** {1 Query} *)

val get_session : t -> agent_id:string -> session option
val list_sessions : t -> session list
val has_session : t -> agent_id:string -> bool
val session_count : t -> int

(** {1 Activity tracking} *)

val heartbeat : t -> agent_id:string -> unit
(** Touches [last_activity] without bumping [turn_count]. *)

val increment_turn : t -> agent_id:string -> unit
(** Bumps [turn_count] and [last_activity]. *)

val cleanup_zombies : t -> ?timeout:float -> unit -> int
(** Removes sessions whose [last_activity] is older than [timeout]
    (default {!Workspace_resilience.default_zombie_threshold}). Returns the
    number of evicted sessions. *)

(** {1 Persistence} *)

val persist : t -> unit
(** Writes every in-memory session back to disk. *)

val restore : t -> unit
(** Loads every [*.json] under the session directory into the
    in-memory map. Malformed files are silently skipped. *)

(** {1 Status} *)

val status_json : t -> Yojson.Safe.t
(** [{ session_count, config_path, sessions: [...] }]. *)
