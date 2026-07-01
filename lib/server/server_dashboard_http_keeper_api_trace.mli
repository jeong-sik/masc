(** Runtime trace trajectory helpers for keeper dashboard API. *)

val line_ts : Trajectory.trajectory_line -> float

val dedupe_thinking_lines
  :  Trajectory.trajectory_line list
  -> Trajectory.trajectory_line list

val read_internal_history_lines
  :  config:Workspace.config
  -> trace_id:string
  -> Trajectory.trajectory_line list

val read_internal_history_tail_lines
  :  max_lines:int
  -> config:Workspace.config
  -> trace_id:string
  -> Trajectory.trajectory_line list

val merge_keeper_trace_lines
  :  config:Workspace.config
  -> trace_id:string
  -> Trajectory.trajectory_line list
  -> Trajectory.trajectory_line list

val merge_keeper_trace_lines_bounded
  :  max_internal_lines:int
  -> config:Workspace.config
  -> trace_id:string
  -> Trajectory.trajectory_line list
  -> Trajectory.trajectory_line list
