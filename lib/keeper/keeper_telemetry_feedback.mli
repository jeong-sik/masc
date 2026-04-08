(** Keeper_telemetry_feedback — compute behavioral statistics from
    decision logs and render them as a prompt block for keeper
    self-assessment.

    Reads {keeper_name}.decisions.jsonl, filters entries within a
    configurable time window, and produces aggregate stats.
    The rendered block presents data only — the LLM decides how to act. *)

type behavioral_stats = {
  window_hours : int;
  total_turns : int;
  silent_turns : int;
  silent_ratio : float;
  tool_use_turns : int;
  text_response_turns : int;
  unique_tools_used : string list;
  tool_success_rate : float;
  last_visible_action_age_sec : int;
  pr_workflow_attempts : int;
  work_discovery_count : int;
}

val empty_stats : window_hours:int -> behavioral_stats
(** Zero-valued stats for the given window. *)

val compute_stats :
  decision_log_path:string ->
  window_hours:int ->
  behavioral_stats
(** Read decision log and compute stats for entries within the window.
    Returns [empty_stats] on I/O errors or missing files. *)

val render_feedback_block : stats:behavioral_stats -> string
(** Render a "### Behavioral Self-Assessment" prompt block.
    Presents data without judgment — the model interprets the numbers. *)
