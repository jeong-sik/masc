(** Lodge Heartbeat v2 — Check-in Model

    에이전트가 라운드로빈으로 "체크인"하는 모델.
    Wake LLM 호출 제거 → LLM은 에이전트 행동 결정에만 사용.

    @since 3.0.0
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

(** {1 Scheduling} *)

val scan_board_triggers : since:float -> agents:agent list -> (string * checkin_trigger) list
val select_checkin_agents : config:config -> agents:agent list -> pending_triggers:(string * checkin_trigger) list -> (string * checkin_trigger) list

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

(** {1 Formatting} *)

val string_of_trigger : checkin_trigger -> string
val string_of_checkin_result : checkin_result -> string
