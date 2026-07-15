(** Phase 5: wire task/board context with keeper tool results.
    Extracted from [Keeper_agent_run.run_turn] Step 8 body (RFC-0147 PR-9). *)

val run :
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  acc:Keeper_run_tools.hook_accumulator ->
  unit ->
  unit
(** Link execution artifacts to the current task if one exists.

    Skipped when the (keeper, task, trace_id) tuple has already been
    linked — [Keeper_agent_run_turn_helpers.task_link_already_recorded]
    guards the call so that repeated linking does not produce backlog
    lock contention or event-feed noise.

    Best-effort: non-cancel exceptions are converted into [Error] and
    logged; [Eio.Cancel.Cancelled] is re-raised. *)
