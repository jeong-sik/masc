(** MASC Resilience - Single Source of Truth for Failure Handling *)

(** Default zombie threshold in seconds - from Env_config. *)
val default_zombie_threshold : float

(** Default inactivity warning threshold in seconds (2 minutes). *)
val default_warning_threshold : float

(** Timestamp utilities for resilience checks *)
module Time : sig
  (** Get current time as Unix float. *)
  val now : unit -> float

  (** Parse ISO 8601 UTC timestamp ("YYYY-MM-DDTHH:MM:SSZ") to Unix epoch.
      Returns None on parse failure. *)
  val parse_iso8601_opt : string -> float option

  (** Check if a timestamp string is older than threshold.
      Treats invalid timestamps as stale. *)
  val is_stale : ?threshold:float -> string -> bool
end

(** Zombie detection logic *)
module Zombie : sig
  (** Check if agent name matches keeper pattern: "keeper-*-agent" (case-insensitive). *)
  val is_keeper_name : string -> bool

  (** Check if an agent is a zombie based on last_seen ISO timestamp. *)
  val is_zombie : ?threshold:float -> string -> bool

  (** Check if agent is a keeper by name pattern AND/OR agent_type field. *)
  val is_keeper : name:string -> agent_type:string -> bool

  (** Check if an agent is a zombie, using keeper threshold for keeper agents. *)
  val is_zombie_for_agent : agent_name:string -> string -> bool
end

(** {1 Zero-Zombie Protocol} *)

module ZeroZombie : sig
  type stats =
    { mutable total_cleanups : int
    ; mutable last_cleanup_ts : float
    ; mutable last_cleaned_agents : string list
    }

  (** Global cleanup statistics. *)
  val global_stats : stats

  (** Run a cleanup cycle using provided cleanup function.
      Returns list of cleaned agent names. *)
  val cleanup : cleanup_fn:(unit -> string list) -> string list

  (** Check if error is benign (e.g., not initialized - normal at startup). *)
  val is_benign_error : exn -> bool

  (** Eio-native background loop for automatic cleanup. *)
  val run_loop
    :  ?interval:float
    -> clock:float Eio.Time.clock_ty Eio.Resource.t
    -> cleanup_fn:(unit -> string list)
    -> unit
    -> unit
end
