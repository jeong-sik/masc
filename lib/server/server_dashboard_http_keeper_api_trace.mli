(** Runtime trace trajectory helpers for keeper dashboard API. *)

val line_ts : Trajectory.trajectory_line -> float

val dedupe_thinking_lines
  :  Trajectory.trajectory_line list
  -> Trajectory.trajectory_line list

val read_internal_history_lines
  :  config:Coord.config
  -> trace_id:string
  -> Trajectory.trajectory_line list

val merge_keeper_trace_lines
  :  config:Coord.config
  -> trace_id:string
  -> Trajectory.trajectory_line list
  -> Trajectory.trajectory_line list
