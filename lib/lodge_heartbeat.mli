(** Lodge Heartbeat v2 — Reaction-First Social Loop

    Mainline heartbeat architecture:
    - Lodge_reaction: reaction history/signature based identity
    - Agent Planner: 일일 계획 기반 selection
    - Reflection Engine: self-summary 갱신용 reflection

    Default 4h tick interval (configurable via MASC_LODGE_TICK_INTERVAL_SEC).
    ~28-33 LLM calls/day (down from ~1440-1920 in v1).

    @since 4.0.0
*)

(** {1 Configuration} *)

type config = {
  interval_s: float;
  enabled: bool;
  agents_per_tick: int;
  min_checkin_gap_s: float;
  quiet_hours: int * int;
}

val default_config : config
val load_config : unit -> config

(** {1 Types} *)

type agent = {
  name: string;
  preferred_hours: int list;
  peak_hour: int option;
  traits: string list;
  interests: string list;
  personality_hint: string option;
  activity_level: float;
}

type checkin_trigger =
  | Scheduled
  | ContentAlert of string
  | Mentioned of string
  | ManualTrigger

type checkin_result =
  | Acted of { action: agent_action; summary: string }
  | Passed of string
  | Skipped of string

and agent_action =
  | ActionPost of string
  | ActionComment of string * string
  | ActionUpvote of string
  | ActionVoice of string
  | ActionSkip

type heartbeat_result = {
  timestamp: float;
  current_hour: int;
  agents_checked: int;
  checkins: (string * checkin_trigger * checkin_result) list;
  agents_woken: (string * string) list;
  encounter_rolled: string option;
  activity_report: string;
}

(** {1 Time Utilities} *)

val current_hour_kst : unit -> int
val time_modifier : agent -> float

(** {1 Agent Data} *)

val load_agents_from_neo4j : unit -> agent list
val get_agents : unit -> agent list

(** {1 Identity} *)

val load_agent_identity : agent_name:string -> string

(** {1 LLM Call Helper} *)

(** Create a reusable LLM call function for an agent (cascade-based). *)
val make_call_llm : agent_name:string -> (prompt:string -> string)

(** {1 Scheduling} *)

val scan_board_triggers : since:float -> agents:agent list -> (string * checkin_trigger) list
val select_checkin_agents :
  ignore_quiet_hours:bool ->
  config:config ->
  agents:agent list ->
  pending_triggers:(string * checkin_trigger) list ->
  (string * checkin_trigger) list

(** Plan-based agent selection using Agent_planner priorities. *)
val select_agents_by_plan :
  ignore_quiet_hours:bool ->
  agents:agent list ->
  max_n:int ->
  pending_triggers:(string * checkin_trigger) list ->
  (string * checkin_trigger) list

(** {1 Heartbeat Execution} *)

val tick :
  ignore_quiet_hours:bool ->
  config:config ->
  pending_triggers:(string * checkin_trigger) list ->
  heartbeat_result

(** {1 Daemon} *)

(** Inject the OAS Event_bus for lifecycle event publishing. *)
val set_bus : Agent_sdk.Event_bus.t -> unit

val start : ?bus:Agent_sdk.Event_bus.t -> sw:Eio.Switch.t -> clock:_ Eio.Time.clock -> Room.config -> unit

(** {1 Manual Trigger} *)

val trigger_heartbeat : Room.config -> heartbeat_result

(** {1 Observable State} *)

type lodge_status = {
  ls_enabled: bool;
  ls_interval_s: float;
  ls_agent_count: int;
  ls_agent_names: string list;
  ls_last_tick: float;
  ls_total_ticks: int;
  ls_total_checkins: int;
  ls_last_result: heartbeat_result option;
  ls_manual_tick_running: bool;
  ls_active_self_heartbeats: string list;
}

val lodge_status : unit -> lodge_status
val lodge_status_to_json : lodge_status -> Yojson.Safe.t
val record_tick_result : heartbeat_result -> unit

val trigger_heartbeat_async :
  sw:Eio.Switch.t -> Room.config -> [ `Started | `Already_running ]

[@@@warning "-32"]
(** {1 REST API — Lodge Agent management} *)

val load_lodge_agents_full : unit -> (Yojson.Safe.t, string) result

val create_agent_graphql :
  name:string ->
  emoji:string ->
  korean_name:string option ->
  traits:string list ->
  interests:string list ->
  activity_level:float ->
  preferred_hours:int list ->
  peak_hour:int option ->
  model:string ->
  personality_hint:string option ->
  primary_value:string option ->
  unit ->
  (Yojson.Safe.t, string) result

[@@@warning "+32"]

(** {1 Formatting} *)

val string_of_trigger : checkin_trigger -> string
val string_of_checkin_result : checkin_result -> string

(** {1 Gap Signal Detection — Ecosystem Evolution}

    Delegated to {!Lodge_ecosystem}. Types and key functions re-exported here
    for backward compatibility.
    @since 4.1.0 *)

(** A gap signal indicates a detected need for a new agent role *)
type gap_signal_t = Lodge_ecosystem.gap_signal_t = {
  gs_topic: string;
  gs_detected_by: string;
  gs_context: string;
  gs_timestamp: float;
}

(** Check if any topic has accumulated enough signals to trigger spawn *)
val check_gap_threshold : unit -> (string * int) list

(** Get all signals for a specific topic *)
val get_signals_for_topic : topic:string -> gap_signal_t list

(** Clear signals for a topic (after agent is created) *)
val clear_gap_signals : topic:string -> unit

(** Spawn a new agent from accumulated gap signals *)
val spawn_agent_from_gap : topic:string -> signals:gap_signal_t list -> bool

(** {1 Rate Limiting (delegated to Lodge_rate_limit)} *)

val check_rate_limit : agent_name:string -> [< `Post | `Comment | `Vote | `Voice ] -> bool
val record_rate_action : agent_name:string -> [< `Post | `Comment | `Vote | `Voice ] -> unit

(** {1 Heartbeat Tool Surface} *)

val heartbeat_allowed_tools :
  agent_name:string ->
  trigger:checkin_trigger ->
  recent_posts:Board.post list ->
  ?voice_enabled:bool ->
  unit ->
  string list
