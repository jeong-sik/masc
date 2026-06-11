(** Dashboard_ops_iteration — ops iteration dashboard for keeper recovery tracking.

    Aggregates keeper-level iteration metrics (heartbeat gaps, crash history,
    recovery latency, task completion trends) into a compact JSON snapshot
    for the dashboard SPA and CLI ops views. *)

(** {1 Types} *)

type iteration_summary = {
  keeper_name : string;
  fitness : float;
  total_tasks : int;
  completed_tasks : int;
  failed_tasks : int;
  task_completion_rate : float;
  error_rate : float;
  avg_completion_time_s : float;
  handoff_success_rate : float;
  unique_collaborators : string list;
}

type recovery_health = {
  keeper_name : string;
  recent_crash_count : int;
  restart_count : int;
  max_restarts : int;
  recovery_health_score : float;
  has_recent_crash : bool;
  is_stable : bool;
}

type ops_iteration_snapshot = {
  generated_at : float;
  keeper_count : int;
  active_keeper_count : int;
  degraded_keeper_count : int;
  iterations : iteration_summary list;
  recovery_entries : recovery_health list;
  fleet_health_score : float;
  degraded_agents : string list;
  avg_completion_rate : float;
  avg_error_rate : float;
}

(** {1 Builders} *)

val build_iteration_summary :
  agent_name:string ->
  fitness:float ->
  total_tasks:int ->
  completed_tasks:int ->
  failed_tasks:int ->
  avg_completion_time_s:float ->
  task_completion_rate:float ->
  error_rate:float ->
  handoff_success_rate:float ->
  unique_collaborators:string list ->
  iteration_summary

val build_recovery_health :
  keeper_name:string ->
  recent_crash_count:int ->
  restart_count:int ->
  max_restarts:int ->
  recovery_health

val compute_fleet_health_score :
  iterations:iteration_summary list ->
  recovery_entries:recovery_health list ->
  float

val compute_degraded_agents :
  iterations:iteration_summary list ->
  recovery_entries:recovery_health list ->
  string list

(** {1 JSON} *)

val iteration_summary_to_json : iteration_summary -> Yojson.Safe.t

val recovery_health_to_json : recovery_health -> Yojson.Safe.t

val ops_iteration_snapshot_to_json : ops_iteration_snapshot -> Yojson.Safe.t

(** {1 Aggregation} *)

val aggregate_agent_data :
  agent_name:string ->
  fitness:float ->
  metrics_total_tasks:int ->
  metrics_completed:int ->
  metrics_failed:int ->
  metrics_avg_time:float ->
  metrics_completion_rate:float ->
  metrics_error_rate:float ->
  metrics_handoff_rate:float ->
  metrics_collaborators:string list ->
  ops_iteration_snapshot