(** Crash-driven pause policy for the keeper supervisor.

    Provides the unified [handle_crash_auto_pause] entrypoint that
    persists [paused=true] + back-off + typed blocker info + releases
    [current_task_id], plus per-cause wrappers and the read-side
    [failure_reason_policy_decision] classifier.

    The phase-event publisher is injected (via [~publish_phase_lifecycle])
    so this module stays free of [Keeper_lifecycle_events] /
    [Cascade_events] dependencies. *)

open Keeper_types
open Keeper_execution

(** Resume policy: whether the supervisor can auto-resume the keeper
    after a back-off delay, or whether an operator must intervene. *)
type crash_pause_resume_policy =
  | Manual_resume_required
  | Auto_resume_with_backoff

(** [handle_crash_auto_pause ~publish_phase_lifecycle ctx entry
      ~reason_tag ~metric_name ~lifecycle_detail ~log_message
      ~blocker_class ~resume_policy] persists [paused=true] on disk,
    sets [auto_resume_after_sec] per [resume_policy], releases
    [current_task_id] so a peer can pick the task up, increments
    [metric_name], publishes a [Paused] phase event via the injected
    publisher, and emits [log_message] at ERROR.

    On disk write failure: increments [keeper_write_meta_failures]
    with the appropriate phase label and falls back to logging — the
    in-memory failure-reason still gates restart, but the persisted
    pause will not survive a server restart. *)
val handle_crash_auto_pause
  :  publish_phase_lifecycle:
       (phase:Keeper_state_machine.phase -> string -> string -> unit -> unit)
  -> _ context
  -> Keeper_registry.registry_entry
  -> reason_tag:string
  -> metric_name:string
  -> lifecycle_detail:string
  -> log_message:string
  -> blocker_class:Keeper_meta_contract.blocker_class option
  -> resume_policy:crash_pause_resume_policy
  -> unit

(** [handle_stale_storm_pause ~publish_phase_lifecycle ctx entry ~count]
    pauses [entry] because the same keeper terminated [count] times in
    a 6h sliding window with [stale_termination]. Manual resume
    required (operator must investigate the cascade/tool/runtime loop
    that caused the storm). *)
val handle_stale_storm_pause
  :  publish_phase_lifecycle:
       (phase:Keeper_state_machine.phase -> string -> string -> unit -> unit)
  -> _ context
  -> Keeper_registry.registry_entry
  -> count:int
  -> unit

(** [handle_oas_timeout_budget_pause ~publish_phase_lifecycle ctx entry
      ~count] pauses [entry] because the OAS provider call timed out
    [count] times in a budget window. Auto-resume with exponential
    back-off (see [MASC_KEEPER_AUTO_RESUME_INITIAL_SEC]). *)
val handle_oas_timeout_budget_pause
  :  publish_phase_lifecycle:
       (phase:Keeper_state_machine.phase -> string -> string -> unit -> unit)
  -> _ context
  -> Keeper_registry.registry_entry
  -> count:int
  -> unit

(** [failure_reason_policy_decision reason] maps a persisted
    [Keeper_registry.failure_reason] back to a
    [Keeper_failure_policy.decision]. Returns [None] for non-policy
    reasons (heartbeat / turn consecutive failures, fleet batch,
    provider runtime error, fiber unresolved, exception) and [None]
    when [reason] itself is [None]. *)
val failure_reason_policy_decision
  :  Keeper_registry.failure_reason option
  -> Keeper_failure_policy.decision option
