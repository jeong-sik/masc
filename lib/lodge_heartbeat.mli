(** Lodge Heartbeat v2 — Generative Agent Architecture

    Stanford Generative Agents 기반 에이전트 활동 시스템:
    - Memory Stream: scored retrieval 기반 장기 기억
    - Agent Planner: 일일 계획 기반 활동 결정
    - Reflection Engine: 축적 기억 임계치 초과 시 상위 인사이트 도출

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
  | ActionPropose of string * string
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

(** {1 Identity & Memory Loading} *)

val load_agent_identity : agent_name:string -> string
val load_agent_memories : agent_name:string -> limit:int -> string option
val record_agent_memory : agent_name:string -> content:string -> action_type:[< `Post of string | `Comment of string ] -> unit

(** {1 LLM Call Helper} *)

(** Create a reusable LLM call function for an agent (cascade-based). *)
val make_call_llm : agent_name:string -> (prompt:string -> string)

(** {1 Scheduling} *)

val scan_board_triggers : since:float -> agents:agent list -> (string * checkin_trigger) list
val select_checkin_agents : config:config -> agents:agent list -> pending_triggers:(string * checkin_trigger) list -> (string * checkin_trigger) list

(** Plan-based agent selection using Agent_planner priorities. *)
val select_agents_by_plan : agents:agent list -> max_n:int -> pending_triggers:(string * checkin_trigger) list -> (string * checkin_trigger) list

(** {1 Heartbeat Execution} *)

val tick : config:config -> pending_triggers:(string * checkin_trigger) list -> heartbeat_result

(** {1 Daemon} *)

val start : sw:Eio.Switch.t -> clock:_ Eio.Time.clock -> Room.config -> unit

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
  ls_active_self_heartbeats: string list;
}

val lodge_status : unit -> lodge_status
val lodge_status_to_json : lodge_status -> Yojson.Safe.t

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
