(** Autoresearch — Autonomous experiment loop inspired by Karpathy's autoresearch.

    Facade module re-exporting sub-modules for backward compatibility.
    Implementation is split across [Autoresearch_types], [Autoresearch_serde],
    [Autoresearch_storage], [Autoresearch_metric], [Autoresearch_git],
    [Autoresearch_file], and [Autoresearch_codegen].

    @since 2.80.0 *)

(** {1 Types} (re-exported from [Autoresearch_types]) *)

type decision = Autoresearch_types.decision = Keep | Discard
type cycle_record = Autoresearch_types.cycle_record = {
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
type status = Autoresearch_types.status = Running | Completed | Stopped | Error
type loop_state = Autoresearch_types.loop_state = {
  loop_id : string;
  author : string option;
  goal : string;
  metric_fn : string;
  model_model : string;
  target_file : string;
  target_score : float option;
  status : status;
  error_message : string option;
  current_cycle : int;
  baseline : float;
  best_score : float;
  best_cycle : int;
  queued_hypothesis : string option;
  history : cycle_record list;
  total_keeps : int;
  total_discards : int;
  insights : string list;
  start_time : float;
  updated_at : float;
  cycle_timeout_s : float;
  max_cycles : int;
  workdir : string;
  source_workdir : string;
  program_note : string option;
  warnings : string list;
  patience : int;
  consecutive_discards : int;
  build_verify_fn : string option;
  lower_is_better : bool;
}
type execution_link = Autoresearch_types.execution_link = {
  loop_id : string;
  session_id : string;
  operation_id : string option;
  task_id : string option;
  target_file : string;
  program_note : string option;
  created_by : string option;
  linked_at : float;
}
type persisted_summary = Autoresearch_types.persisted_summary = {
  loop_id : string;
  author : string option;
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

(** {1 Global State} *)

val active_loops : (string, loop_state) Hashtbl.t
val latest_loop_id : string option ref

val with_loops_rw : (unit -> 'a) -> 'a
val with_loops_ro : (unit -> 'a) -> 'a

(** {1 Serde} *)

val decision_to_string : decision -> string
val decision_of_string_result : string -> (decision, string) result
val status_to_string : status -> string
val status_of_string_result : string -> (status, string) result
val cycle_to_yojson : cycle_record -> Yojson.Safe.t
val cycle_of_yojson_result : Yojson.Safe.t -> (cycle_record, string) result
val state_to_yojson : loop_state -> Yojson.Safe.t
val state_of_yojson_result : Yojson.Safe.t -> (persisted_summary, string) result
val execution_link_to_yojson : execution_link -> Yojson.Safe.t
val execution_link_of_yojson_result : Yojson.Safe.t -> (execution_link, string) result

(** {1 Storage} *)

val results_dir : base_path:string -> string -> string
val results_file : base_path:string -> string -> string
val state_file : base_path:string -> string -> string
val loop_link_file : base_path:string -> string -> string
val managed_worktree_dir : base_path:string -> string -> string
val session_link_file : base_path:string -> string -> string
val ensure_dir : string -> unit
val append_cycle : base_path:string -> string -> cycle_record -> unit
val save_state : base_path:string -> loop_state -> unit
val save_execution_link : base_path:string -> execution_link -> unit
val load_execution_link_by_loop :
  base_path:string -> string -> execution_link option
val load_execution_link_by_session :
  base_path:string -> string -> execution_link option
val load_execution_link_by_loop_result :
  base_path:string -> string -> (execution_link, string) result option
val load_execution_link_by_session_result :
  base_path:string -> string -> (execution_link, string) result option
val load_state : base_path:string -> string -> persisted_summary option
val load_state_result :
  base_path:string -> string -> (persisted_summary, string) result option
val latest_cycle_record : base_path:string -> string -> cycle_record option
val load_cycle_history : base_path:string -> string -> cycle_record list
val scan_persisted_loop_ids : base_path:string -> string list

(** {1 Metric} *)

val validate_metric_fn : string -> (string, string) result
val measure_metric :
  workdir:string -> timeout_s:float -> string -> (float * int, string) result
val measure_metric_with_retry :
  workdir:string -> timeout_s:float -> ?max_retries:int ->
  string -> (float * int, string) result

(** {1 Git} *)

val is_in_git_repo : string -> bool
val run_capture_lines :
  workdir:string -> ?timeout_sec:float -> string list ->
  Unix.process_status * string list
val git_head_short : workdir:string -> string option
val git_commit :
  workdir:string -> message:string -> (string option, string) result
val git_restore_head : workdir:string -> unit
val git_reset_last : workdir:string -> unit
val git_commit_cycle :
  workdir:string -> cycle:int -> hypothesis:string -> baseline:float ->
  (string option, string) result
val git_tag_best : workdir:string -> cycle:int -> score:float -> unit
val git_top_level : workdir:string -> (string, string) result
val git_current_branch : workdir:string -> string option
val git_is_dirty : workdir:string -> bool
val managed_branch_name : string -> string
val prepare_managed_worktree :
  base_path:string -> source_workdir:string -> loop_id:string ->
  (string * string * string list, string) result

(** {1 File} *)

val has_path_traversal : string -> bool
val resolve_target_file_path : workdir:string -> string -> (string, string) result
val validate_target_file : workdir:string -> string -> (string, string) result
val read_file : string -> string
val apply_code_change :
  workdir:string -> target_file:string -> new_content:string ->
  (string, string) result

(** {1 Codegen} *)

val build_code_change_prompt :
  goal:string -> baseline:float -> lower_is_better:bool ->
  history:cycle_record list -> insights:string list ->
  file_content:string -> target_file:string -> string
val parse_model_code_response : string -> (string * string, string) result
val generate_code_change :
  goal:string -> baseline:float -> lower_is_better:bool ->
  history:cycle_record list -> insights:string list ->
  target_file:string -> file_content:string ->
  (string * string, string) result

(** {1 Lifecycle} *)

val create_state :
  goal:string -> metric_fn:string -> ?model_model:string -> ?author:string ->
  target_file:string -> ?target_score:float ->
  cycle_timeout_s:float -> max_cycles:int -> ?patience:int ->
  ?build_verify_fn:string -> ?lower_is_better:bool ->
  workdir:string -> unit -> loop_state

val add_insight : loop_state -> string -> loop_state
val record_cycle :
  loop_state -> hypothesis:string -> score_before:float -> score_after:float ->
  commit_hash:string option -> elapsed_ms:int -> model_used:string ->
  loop_state * cycle_record
val target_reached : loop_state -> bool
val completion_reason : loop_state -> string option
val complete_if_finished : loop_state -> loop_state
val should_continue : loop_state -> bool
val stop_loop : base_path:string -> ?reason:string -> string -> loop_state option
val linked_status_json : base_path:string -> execution_link -> Yojson.Safe.t
val summary : loop_state -> Yojson.Safe.t
