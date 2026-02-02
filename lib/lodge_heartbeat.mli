(** Lodge Heartbeat - 세계의 맥박

    @since 2.14.0
*)

(** {1 Configuration} *)

type config = {
  interval_s: float;
  enabled: bool;
  matching_weight: float;
  discovery_weight: float;
  random_weight: float;
  wake_threshold: float;
}

val default_config : config
val load_config : unit -> config

(** {1 Types} *)

type agent = {
  name: string;
  preferred_hours: int list;
  peak_hour: int option;
  traits: string list;
  activity_level: float;
}

type wake_reason =
  | Matching of { score: float; topic: string }
  | Discovery of { connection: string }
  | Random

type heartbeat_result = {
  timestamp: float;
  current_hour: int;
  agents_checked: int;
  agents_woken: (string * wake_reason) list;
  encounter_rolled: string option;
}

(** {1 Time Utilities} *)

val current_hour_kst : unit -> int
val time_modifier : agent -> float

(** {1 Agent Data} *)

val default_agents : agent list

(** {1 Wake Logic} *)

val should_wake : config -> agent -> 'a list -> wake_reason option

(** {1 Heartbeat Execution} *)

val tick : config:config -> recent_posts:'a list -> heartbeat_result

(** {1 Daemon} *)

val start : sw:Eio.Switch.t -> clock:_ Eio.Time.clock -> Room.config -> unit

(** {1 Manual Trigger} *)

val trigger_heartbeat : Room.config -> heartbeat_result
