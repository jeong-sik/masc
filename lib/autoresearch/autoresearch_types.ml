(** Autoresearch types — shared type definitions for autonomous experiment loop.

    @since 2.80.0 *)

type decision = Keep | Discard

type cycle_record = {
  cycle : int;
  hypothesis : string;
  score_before : float;
  score_after : float;
  delta : float;
  decision : decision;
  commit_hash : string option;
  elapsed_ms : int;
  model_used : string;
  timestamp : float;
}

type status = Running | Completed | Stopped | Error

type loop_state = {
  loop_id : string;
  goal : string;
  metric_fn : string;
  model_model : string;
  target_file : string;  (** File the MODEL reads and modifies, relative to workdir *)
  target_score : float option;  (** Optional success threshold for the metric *)
  status : status;
  error_message : string option;
  current_cycle : int;
  baseline : float;
  best_score : float;
  best_cycle : int;
  queued_hypothesis : string option;
  history : cycle_record list;  (** Most recent first *)
  total_keeps : int;
  total_discards : int;
  insights : string list;  (** Accumulated experiment insights, FIFO max 10 *)
  start_time : float;
  updated_at : float;
  cycle_timeout_s : float;
  max_cycles : int;
  workdir : string;
  source_workdir : string;
  program_note : string option;
  warnings : string list;
  patience : int;  (** Max consecutive discards before early stop *)
  consecutive_discards : int;  (** Counter for consecutive discards without improvement *)
  build_verify_fn : string option;  (** Optional shell command that must exit 0 for a Keep to succeed *)
  lower_is_better : bool;  (** When true, lower metric scores are better (e.g., val_bpb, loss) *)
}

type swarm_link = {
  loop_id : string;
  session_id : string;
  operation_id : string option;
  task_id : string option;
  target_file : string;
  program_note : string option;
  created_by : string option;
  linked_at : float;
}

type persisted_summary = {
  loop_id : string;
  status : status;
  current_cycle : int;
  baseline : float;
  best_score : float;
  best_cycle : int;
  queued_hypothesis : string option;
  total_keeps : int;
  total_discards : int;
  goal : string;
  metric_fn : string;
  model_model : string;
  target_file : string;
  target_score : float option;
  workdir : string;
  cycle_timeout_s : float;
  max_cycles : int;
  error_message : string option;
  elapsed_s : float;
  updated_at : float option;
  source_workdir : string;
  program_note : string option;
  warnings : string list;
  patience : int;
  consecutive_discards : int;
  build_verify_fn : string option;
  lower_is_better : bool;
}
