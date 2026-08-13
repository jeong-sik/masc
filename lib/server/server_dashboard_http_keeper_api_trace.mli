(** Runtime trace trajectory helpers for keeper dashboard API. *)

val line_ts : Trajectory.trajectory_line -> float

val dedupe_thinking_lines
  :  Trajectory.trajectory_line list
  -> Trajectory.trajectory_line list

val order_keeper_trace_lines
  :  Trajectory.trajectory_line list
  -> Trajectory.trajectory_line list

val chat_trace_block_by_turn_ref
  :  max_lines:int
  -> config:Workspace.config
  -> keeper_name:string
  -> allowed_trace_ids:string list
  -> Ids.Turn_ref.t
  -> Keeper_chat_blocks.chat_block option
