(** RFC-0145 PR-3: extract thinking-block extraction & trajectory
    persistence from [keeper_agent_run.run_turn] Step 8 body
    (L791-L858).

    Iterates over the model response content; for each
    [Agent_sdk.Types.Thinking { content; _ }] / [RedactedThinking _]
    item, builds a [Trajectory.thinking_entry] and appends to the
    JSONL via {!Trajectory.append_thinking}.

    Side effects only.  [Eio.Cancel.Cancelled] is re-raised; other
    exceptions log an error and increment
    [Keeper_metrics.metric_keeper_thinking_persist_failures].

    No-op when [trajectory_acc = None]. *)
val persist
  :  trajectory_acc:Trajectory.accumulator option
  -> content:Agent_sdk.Types.content list
  -> keeper_name:string
  -> unit
