(** Lodge Heartbeat - 세계의 맥박

    @since 2.14.0
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

type agent_action =
  | ActionPost of string
  | ActionComment of string * string
  | ActionUpvote of string
  | ActionPropose of string * string
  | ActionSkip

type checkin_result =
  | Acted of { action: agent_action; summary: string }
  | Passed of string
  | Skipped of string

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

(** {1 Heartbeat Execution} *)

val tick : config:config -> recent_posts:Board.post list -> heartbeat_result

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
  ls_total_wakes: int;
  ls_last_result: heartbeat_result option;
  ls_active_self_heartbeats: string list;
}

val lodge_status : unit -> lodge_status
val lodge_status_to_json : lodge_status -> Yojson.Safe.t
