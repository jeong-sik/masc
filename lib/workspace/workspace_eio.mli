(** Workspace_eio -- OCaml 5.x Eio-native Workspace implementation.

    Direct-style async I/O using Eio for multi-agent workspace:
    agent registration/heartbeat, file locking, message broadcasting,
    task management, and persistent event logging.

    Migration path: Workspace -> Workspace_eio. *)

(** {1 Types} *)

(** Workspace configuration for the Eio file-system backend. *)
type config = {
  base_path: string;
  lock_expiry_minutes: int;
  backend: Backend.FileSystem.t;
  fs: Eio.Fs.dir_ty Eio.Path.t;
}

(** Agent state within a workspace. *)
type agent_state = {
  name: string;
  last_seen: float;
  capabilities: string list;
  status: string;
}

(** Workspace-level state (protocol version, active agents, pause, etc.). *)
type workspace_state = {
  protocol_version: string;
  started_at: float;
  last_updated: float;
  active_agents: string list;
  message_seq: int;
  event_seq: int;
  mode: string;
  paused: bool;
  paused_by: string option;
  paused_at: float option;
  pause_reason: string option;
}

(** Event types for the persistent audit log. *)
type event_type =
  | AgentSessionBound
  | AgentSessionEnded
  | Broadcast
  | LockAcquire
  | LockRelease

(** A single audit-log event. *)
type event = {
  event_seq: int;
  event_type: event_type;
  agent: string;
  payload: Yojson.Safe.t;
  timestamp: float;
}

(** File-lock metadata. *)
type lock_info = {
  resource: string;
  owner: string;
  acquired_at: float;
  expires_at: float;
}

(** Broadcast message. *)
type message = {
  seq: int;
  from_agent: string;
  content: string;
  mention: string option;
  timestamp: float;
}

(** {1 Helpers} *)

(** Current time as ISO-8601 string (UTC, millisecond precision). *)
val now_iso : unit -> string

(** {1 Configuration} *)

(** Create an Eio-native workspace configuration rooted at [base_path]. *)
val create_config :
  fs:Eio.Fs.dir_ty Eio.Path.t ->
  ?clock:float Eio.Time.clock_ty Eio.Resource.t ->
  string ->
  config

(** Create a test configuration (short TTLs, isolated node id). *)
val test_config : fs:Eio.Fs.dir_ty Eio.Path.t -> string -> config

(** {1 Key Utilities} *)

(** Key prefix for agents namespace. *)
val agents_key : string

(** Key prefix for messages namespace. *)
val messages_key : string

(** Key prefix for locks namespace. *)
val locks_key : string

(** Key for workspace state. *)
val state_key : string

(** Key prefix for events namespace. *)
val events_key : string

(** Key for a specific agent. *)
val agent_key : string -> string

(** Key for a specific message by sequence. *)
val message_key : int -> string

(** Key for a specific lock resource. *)
val lock_key : string -> string

(** Key for a specific event by sequence. *)
val event_key : int -> string

(** {1 State Management} *)

(** Return a fresh default workspace state. *)
val default_workspace_state : unit -> workspace_state

(** Serialize workspace state to JSON. *)
val workspace_state_to_json : workspace_state -> Yojson.Safe.t

(** Deserialize workspace state from JSON. *)
val workspace_state_of_json : Yojson.Safe.t -> (workspace_state, string) result

(** Read workspace state from the backend (defaults if absent). *)
val read_state : config -> (workspace_state, string) result

(** Write workspace state to the backend. *)
val write_state : config -> workspace_state ->
  (unit, Backend.error) result

(** Atomically read-modify-write workspace state.
    [f] receives the current state and returns the new state. *)
val atomic_update_state :
  config -> f:(workspace_state -> workspace_state) -> (workspace_state, string) result

(** {1 Agent Operations} *)

(** Serialize agent state to JSON. *)
val agent_state_to_json : agent_state -> Yojson.Safe.t

(** Deserialize agent state from JSON. *)
val agent_state_of_json : Yojson.Safe.t -> (agent_state, string) result

(** Register an agent or update its heartbeat.
    Auto-subscribes to Messages for A2A communication. *)
val register_agent :
  config -> name:string -> ?capabilities:string list -> unit ->
  (agent_state, string) result

(** Retrieve agent state by name. *)
val get_agent : config -> name:string -> (agent_state, string) result

(** Remove an agent from the workspace. *)
val remove_agent : config -> name:string -> (unit, string) result

(** {1 Lock Operations} *)

(** Serialize lock info to JSON. *)
val lock_info_to_json : lock_info -> Yojson.Safe.t

(** Deserialize lock info from JSON. *)
val lock_info_of_json : Yojson.Safe.t -> (lock_info, string) result

(** Acquire a lock on [resource] for [owner].
    Returns [Ok (Some lock)] on success, [Ok None] if held by another. *)
val acquire_lock :
  config -> resource:string -> owner:string ->
  (lock_info option, string) result

(** Release a lock.  Fails if [owner] does not hold it. *)
val release_lock :
  config -> resource:string -> owner:string -> (unit, string) result

(** Extend a lock's TTL. *)
val extend_lock :
  config -> resource:string -> owner:string -> (unit, string) result

(** {1 Message Operations} *)

(** Serialize a message to JSON. *)
val message_to_json : message -> Yojson.Safe.t

(** Deserialize a message from JSON. *)
val message_of_json : Yojson.Safe.t -> (message, string) result

(** Broadcast a message from [from_agent] with [content].
    Extracts @mention automatically. *)
val broadcast :
  config -> from_agent:string -> content:string ->
  (message, string) result

(** Retrieve a message by sequence number. *)
val get_message : config -> seq:int -> (message, string) result

(** {1 Event Log} *)

(** Convert event type to its string tag. *)
val event_type_to_string : event_type -> string

(** Serialize an event to JSON. *)
val event_to_json : event -> Yojson.Safe.t

(** Log an event to persistent storage.
    Uses file-based atomic increment for cross-process safety. *)
val log_event :
  config -> event_type:event_type -> agent:string ->
  payload:Yojson.Safe.t -> event

(** Retrieve an event by sequence number. [Ok None] means the event key is
    absent; [Error] means the stored event could not be read or decoded. *)
val get_event_result : config -> seq:int -> (Yojson.Safe.t option, string) result

(** Compatibility wrapper around {!get_event_result}. Logs read/decode
    failures before projecting them to [None]. *)
val get_event : config -> seq:int -> Yojson.Safe.t option

(** Retrieve the [limit] most recent events. *)
val get_recent_events : config -> limit:int -> Yojson.Safe.t list

(** {1 Health & Status} *)

(** In-process counters for [atomic_update_state] attempts and failures.
    Returns a JSON object with [state_update_attempts], [state_update_failures],
    and [failure_rate]. *)
val state_health_counters : unit -> Yojson.Safe.t

(** Run a health check against the backend. *)
val health_check : config -> (Backend_types.health_result, string) result

(** Return project status as a JSON object. *)
val status : config -> Yojson.Safe.t
