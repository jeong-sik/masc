(** Smart Heartbeat - Token-saving heartbeat logic

    OpenClaw-style adaptive heartbeat that reduces unnecessary emissions:
    - Skip heartbeats when agent is busy (working on a task)
    - Use longer intervals when agent has been idle for extended periods

    Token Savings:
    - Busy agents: 100% skip (no heartbeat during active work)
    - Idle > 5min: 3x interval (33% of normal emissions)
    - Combined: Significant reduction in SSE/broadcast traffic
*)

(** Smart heartbeat configuration *)
type config = {
  base_interval_s: float;    (** Base heartbeat interval (default: 30s) *)
  idle_multiplier: float;    (** Interval multiplier when idle > 5min (default: 3x) *)
  busy_skip: bool;           (** Skip heartbeats entirely when agent is busy (default: true) *)
  idle_threshold_s: float;   (** Seconds before considering agent "idle" (default: 300s = 5min) *)
}

(** Decision result from should_emit *)
type decision =
  | Emit                     (** Send heartbeat now *)
  | Skip_busy                (** Skip: agent is busy with a task *)
  | Skip_idle of float       (** Skip: in extended idle interval, next emit at float *)

(** Default smart config: 30s base, 3x idle multiplier, skip when busy *)
val default_config : config

(** Create a custom config with validation *)
val make_config :
  ?base_interval_s:float ->
  ?idle_multiplier:float ->
  ?busy_skip:bool ->
  ?idle_threshold_s:float ->
  unit -> config

(** Determine if a heartbeat should be emitted

    @param config Smart heartbeat configuration
    @param agent_status Current agent status (from Types.agent_status)
    @param last_activity Unix timestamp of last agent activity
    @param last_heartbeat Unix timestamp of last heartbeat emission
    @return Decision indicating whether to emit or skip
*)
val should_emit :
  config:config ->
  agent_status:Types.agent_status ->
  last_activity:float ->
  last_heartbeat:float ->
  decision

(** Calculate the effective interval based on idle time

    @param config Smart heartbeat configuration
    @param last_activity Unix timestamp of last agent activity
    @return Effective interval in seconds
*)
val effective_interval : config:config -> last_activity:float -> float

(** Convert decision to human-readable string (for logging) *)
val decision_to_string : decision -> string

(** Check if decision means we should emit *)
val should_emit_now : decision -> bool
