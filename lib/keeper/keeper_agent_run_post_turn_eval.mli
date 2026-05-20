(** RFC-0145 PR-4-4: extract post-turn quality metrics from
    [keeper_agent_run.run_turn] Step 8 body (L1617-L1713).

    Computes goal-alignment score, optional memory-recall evaluation
    (when [keeper_memory_search] was used), and emits a single
    [post_turn_eval] JSONL line to
    [Keeper_types_support.keeper_decision_log_path] for feedback-loop
    analysis.

    Side effects only.  [Eio.Cancel.Cancelled] re-raised; other
    exceptions counter ([site=post_turn_eval]) + warn log.

    [recall_eval] is only computed when [used_search = true]; loading
    the history file is best-effort (counter + warn on read failure;
    [candidates] falls back to []). *)
val log_post_turn_eval
  :  config:Coord.config
  -> meta:Keeper_types.keeper_meta
  -> manifest_keeper_turn_id:int
  -> oas_turn_count:int
  -> response_text:string
  -> actual_keeper_tool_names:string list
  -> post_turn_t0:float
  -> telemetry:Agent_sdk.Types.inference_telemetry option
  -> unit
