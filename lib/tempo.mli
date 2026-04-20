(** MASC Tempo Control — Dynamic Orchestrator Interval.

    Cluster tempo control for adaptive orchestration:
    - Urgent tasks (priority 1-2) → Fast tempo (min_interval_s)
    - Normal tasks (priority 3) → Normal tempo (default_interval_s)
    - Idle (no pending tasks) → Slow tempo (max_interval_s)

    Storage: [.masc/tempo.json]. *)

(** {1 Types} *)

type tempo_config = {
  min_interval_s : float;      (** Minimum interval (fast tempo) *)
  max_interval_s : float;      (** Maximum interval (slow tempo) *)
  default_interval_s : float;
  adaptive : bool;             (** Enable adaptive tempo *)
}

type tempo_state = {
  current_interval_s : float;
  last_adjusted : float;
  reason : string;
}

(** {1 Configuration} *)

(** Loaded from [Env_config.Tempo.*_interval_seconds]. [adaptive = true]. *)
val default_config : tempo_config

(** [tempo_file config] = [<masc_dir(config)>/tempo.json]. *)
val tempo_file : Coord_utils.config -> string

(** {1 State serialisation} *)

val state_to_json : tempo_state -> Yojson.Safe.t

(** Returns [None] on [Yojson.Safe.Util.Type_error] (logged). *)
val state_of_json : Yojson.Safe.t -> tempo_state option

(** {1 State I/O} *)

(** Reads [.masc/tempo.json]. On missing file or load/parse failure
    returns a [default_config.default_interval_s] state with reason
    ["default"]. *)
val load_state : Coord_utils.config -> tempo_state

(** Persists [state] to [tempo_file config] (creates parent dir). *)
val save_state : Coord_utils.config -> tempo_state -> unit

(** {1 Tempo adjustment} *)

(** [set_tempo config ~interval_s ~reason] clamps [interval_s] to
    [[min_interval_s; max_interval_s]], updates [last_adjusted], and
    persists. *)
val set_tempo :
  Coord_utils.config -> interval_s:float -> reason:string -> tempo_state

(** Alias for {!load_state}. *)
val get_tempo : Coord_utils.config -> tempo_state

val is_pending_task : Types.task -> bool

(** [(interval, reason)] derived from priority mix:
    - any task with [priority <= 2] → [min_interval_s]
    - else any task with [priority = 3] → [default_interval_s]
    - else → [max_interval_s]
    - empty list → [max_interval_s] with ["idle - no pending tasks"]. *)
val calculate_adaptive_tempo : Types.task list -> float * string

(** Adjusts tempo from [Coord.get_tasks_raw config] via
    {!calculate_adaptive_tempo} and persists. *)
val adjust_tempo : Coord_utils.config -> tempo_state

(** {1 Presentation} *)

(** Human-readable status line:
    ["⏱️ Tempo: <Ns|N.Nm> (<reason>, adjusted <just now|Nm ago|N.Nh ago>)"]. *)
val format_state : tempo_state -> string

(** Writes [default_interval_s] with reason ["reset to default"]. *)
val reset_tempo : Coord_utils.config -> tempo_state
