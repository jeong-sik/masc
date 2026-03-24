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
  mutable status : status;
  mutable error_message : string option;
  mutable current_cycle : int;
  mutable baseline : float;
  mutable best_score : float;
  mutable best_cycle : int;
  mutable queued_hypothesis : string option;
  mutable history : cycle_record list;  (** Most recent first *)
  mutable total_keeps : int;
  mutable total_discards : int;
  mutable insights : string list;  (** Accumulated experiment insights, FIFO max 10 *)
  start_time : float;
  mutable updated_at : float;
  cycle_timeout_s : float;
  max_cycles : int;
  mutable workdir : string;
  source_workdir : string;
  mutable program_note : string option;
  mutable warnings : string list;
}

type swarm_link = {
  loop_id : string;
  session_id : string;
  operation_id : string option;
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
  workdir : string;
  cycle_timeout_s : float;
  max_cycles : int;
  error_message : string option;
  elapsed_s : float;
  updated_at : float option;
  source_workdir : string;
  program_note : string option;
  warnings : string list;
}
