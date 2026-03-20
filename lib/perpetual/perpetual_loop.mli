(** Perpetual_loop — Types, configuration, and state for the perpetual agent.

    The loop runtime has moved to {!Perpetual_oas}.  This module retains
    type definitions, construction helpers, and status queries.

    @since 2.61.0 *)

(** {1 Events} *)

(** Events emitted during the loop for monitoring. *)
type event =
  | TurnStart of int
  | TurnEnd of { turn : int; tokens_used : int; cost : float }
  | Compacted of { before_tokens : int; after_tokens : int; offloaded_path : string option }
  | Prepared of { dna_size : int }
  | Handoff of { to_model : string; generation : int }
  | Verified of { action : string; verdict : string }
  | Heartbeat of { turn : int; context_pct : float }
  | Error of string
  | IdleDetected of int
  | Terminated of string
  | CodingSpawn of { agent : string; exit_code : int; elapsed_ms : int }
  | TaskClaimed of { task_id : string; title : string; priority : int }
  | TaskCompleted of { task_id : string }
  | ClaimSkipped of string

(** {1 Configuration} *)

(** Loop configuration — immutable after creation. *)
type loop_config = {
  initial_goal : string;
  model_cascade : Model_spec.model_spec list;   (** Ordered preference *)
  tools : Types.tool_schema list;
  heartbeat_interval_s : float;                  (** Default: 30.0 *)
  max_idle_turns : int;                          (** Stop after N turns with no progress *)
  feedback_enabled : bool;                       (** Run verifier after each action *)
  verifier_model : Model_spec.model_spec;        (** Cheap model for verification *)
  compact_threshold : float;                     (** Default: 0.5 *)
  prepare_threshold : float;                     (** Default: 0.7 *)
  handoff_threshold : float;                     (** Default: 0.85 *)
  compact_strategies : Compaction_types.compaction_strategy list;
  session_base_dir : string;                     (** Where to store session data *)
  on_event : event -> unit;                      (** Callback for monitoring *)
  event_bus : Agent_sdk.Event_bus.t option;       (** OAS Event_bus for cross-system events *)
  coding_mode : bool;                            (** Spawn Claude Code instead of LLM direct calls *)
  coding_agent : string;                         (** Target agent for coding mode (default: "claude") *)
  coding_timeout_s : int;                        (** Timeout per coding turn in seconds *)
  coding_sw : Eio.Switch.t option;               (** Eio switch for coding mode spawning *)
  coding_proc_mgr : Eio_unix.Process.mgr_ty Eio.Resource.t option;  (** Process manager for coding mode *)
  room_config : Room_utils_backend_setup.config option;             (** Room config for auto-claim *)
  agent_name : string;                                              (** Agent name for auto-claim *)
  auto_claim_cooldown_s : float;                                    (** Cooldown between claim attempts *)
}

(** {1 Loop State} *)

(** Mutable loop state — evolves during execution. *)
type loop_state = {
  mutable context : Context_manager.working_context;
  mutable session : Context_manager.session_context;
  mutable generation : int;
  mutable turn_count : int;
  mutable idle_turns : int;
  mutable total_cost : float;
  mutable total_tokens : int;
  mutable last_heartbeat : float;
  mutable started_at : float;
  mutable last_turn_ts : float;
  mutable last_model_used : string;
  mutable last_usage : Agent_sdk.Types.api_usage;
  mutable last_latency_ms : int;
  mutable compaction_count : int;
  mutable compaction_tokens_saved : int;
  mutable last_compaction_ts : float;
  mutable last_compaction_before_tokens : int;
  mutable last_compaction_after_tokens : int;
  mutable events : (float * event) list;
  mutable running : bool;
  trace_id : string;
  mutable current_task_id : string option;
  mutable last_claim_attempt_ts : float;
  mutable claim_failure_count : int;
}

(** {1 Core Functions} *)

(** Create initial loop state from configuration. *)
val create_state : loop_config -> loop_state

(** Stop the loop gracefully.  Sets running=false. *)
val stop : loop_state -> unit

(** Get current status as JSON. *)
val status : config:loop_config -> loop_state -> Yojson.Safe.t

(** Record an event into the state's event log (capped at 200). *)
val record_event : loop_state -> event -> unit

(** Publish an event to an OAS Event_bus. *)
val publish_to_event_bus : Agent_sdk.Event_bus.t -> event -> unit

(** {1 Defaults} *)

(** Default configuration builder. *)
val default_config :
  goal:string ->
  models:Model_spec.model_spec list ->
  ?verifier:Model_spec.model_spec ->
  ?session_dir:string ->
  unit -> loop_config
