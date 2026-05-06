(** Keeper tool-call failure and recovery proof helpers for dashboard read models. *)

type tool_keeper_stat = {
  name : string;
  calls : int;
  successes : int;
  success_pct : float;
  keepers : string list;
  successful_keepers : string list;
  failed_keepers : string list;
  sandbox_profiles : string list;
  network_modes : string list;
  task_ids : string list;
  goal_ids : string list;
  latest_ts : float option;
  latest_success_ts : float option;
  latest_failure_ts : float option;
}

type failure_table

val tool_success_of_record : Yojson.Safe.t -> bool

val output_text : Yojson.Safe.t -> string

val read_records :
  ?window_hours:float ->
  n:int ->
  unit ->
  Yojson.Safe.t list

val keeper_stats_and_failures_by_tool :
  ?window_hours:float ->
  n:int ->
  keeper_names:string list ->
  unit ->
  (string, tool_keeper_stat) Hashtbl.t * failure_table

val classes_json : failure_table -> string -> Yojson.Safe.t

val keeper_evidence_json :
  (string, tool_keeper_stat) Hashtbl.t ->
  keeper_names:string list ->
  required_tools:string list ->
  Yojson.Safe.t
