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
  tool_utilization_rate : float;
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
    Reads a tail of the file sized to [window_hours] (≈3 turns/min × 60 min/h
    × window_hours + buffer, capped at 10 000 lines) to bound I/O, then
    filters parsed entries by timestamp.  Entries older than the window are
    excluded.  Returns [empty_stats] on I/O errors or missing files. *)

val get_cached_stats : keeper_name:string -> behavioral_stats option
(** Read cached stats for a keeper. O(1), no file I/O.
    Returns [None] on cache miss (before first refresh cycle). *)

val get_cache_age_sec : keeper_name:string -> float option
(** Seconds since the cache was last refreshed.
    Returns [None] if no cache entry exists. *)

val refresh_stats :
  keeper_name:string ->
  decision_log_path:string ->
  window_hours:int ->
  unit
(** Refresh a keeper's stats and store in cache. *)

val start_refresh_loop :
  sw:Eio.Switch.t ->
  clock:_ Eio.Time.clock ->
  keeper_name:string ->
  decision_log_path:string ->
  window_hours:int ->
  interval_sec:int ->
  stop:bool Atomic.t ->
  unit
(** Fork a background fiber that refreshes cached stats at a fixed interval.
    The loop exits when [stop] is set to [true].
    [Eio.Cancel.Cancelled] is re-raised; other exceptions are logged and the
    loop continues. *)

val render_feedback_block : stats:behavioral_stats -> string
(** Render a "### Behavioral Self-Assessment" prompt block.
    Presents data without judgment — the model interprets the numbers. *)
