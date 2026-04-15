(** MASC Resilience - Single Source of Truth for Failure Handling *)

val default_zombie_threshold : float
(** Default zombie threshold in seconds - from Env_config. *)

val default_warning_threshold : float
(** Default inactivity warning threshold in seconds (2 minutes). *)

(** Timestamp utilities for resilience checks *)
module Time : sig
  val now : unit -> float
  (** Get current time as Unix float. *)

  val parse_iso8601_opt : string -> float option
  (** Parse ISO 8601 UTC timestamp ("YYYY-MM-DDTHH:MM:SSZ") to Unix epoch.
      Returns None on parse failure. *)

  val is_stale : ?threshold:float -> string -> bool
  (** Check if a timestamp string is older than threshold.
      Treats invalid timestamps as stale. *)
end

(** Zombie detection logic *)
module Zombie : sig
  val is_keeper_name : string -> bool
  (** Check if agent name matches keeper pattern: "keeper-*-agent" (case-insensitive). *)

  val is_zombie : ?threshold:float -> string -> bool
  (** Check if an agent is a zombie based on last_seen ISO timestamp. *)

  val is_keeper : name:string -> agent_type:string -> bool
  (** Check if agent is a keeper by name pattern AND/OR agent_type field. *)

  val is_zombie_for_agent : agent_name:string -> string -> bool
  (** Check if an agent is a zombie, using keeper threshold for keeper agents. *)
end

(** {1 Zero-Zombie Protocol} *)

module ZeroZombie : sig
  type stats = {
    mutable total_cleanups: int;
    mutable last_cleanup_ts: float;
    mutable last_cleaned_agents: string list;
  }

  val global_stats : stats
  (** Global cleanup statistics. *)

  val cleanup : cleanup_fn:(unit -> string list) -> string list
  (** Run a cleanup cycle using provided cleanup function.
      Returns list of cleaned agent names. *)

  val is_benign_error : exn -> bool
  (** Check if error is benign (e.g., not initialized - normal at startup). *)

  val run_loop :
    ?interval:float ->
    clock:float Eio.Time.clock_ty Eio.Resource.t ->
    cleanup_fn:(unit -> string list) ->
    unit -> unit
  (** Eio-native background loop for automatic cleanup. *)
end
