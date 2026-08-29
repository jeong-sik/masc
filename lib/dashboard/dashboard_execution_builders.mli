(** Dashboard_execution_builders — agent / keeper brief builders
    for the execution dashboard.

    {b Runtime chain}: starts with [include Dashboard_execution_helpers].
    {!Dashboard_execution} does
    [include Dashboard_execution_builders] to make the four brief
    builders visible bare in the dashboard JSON dispatcher.

    Internal: 17 entries stay private — 2 module-local types
    ([keeper_lifecycle] / [keeper_execution_state]) + their string
    converters, 7 env-cached threshold constants
    ([signal_*_sec] / [ctx_*] / [keeper_action_stale_sec]),
    3 task / message / agent helpers.  Future "expose threshold
    constants" PR can reopen explicitly. *)

include module type of struct
  include Dashboard_execution_helpers
end

(** {1 Brief builders (runtime-visible)} *)

val task_assignee : Masc_domain.task -> string option
(** [task_assignee task] returns [Some assignee] when [task] is in
    a status that carries an assignee ([Claimed] / [InProgress] /
    [AwaitingVerification] / [Done]); else [None].  Pinned at the
    contract seam — adding a new task status that should also
    carry an assignee requires extending this match. *)

val build_operation_contexts : tasks:Masc_domain.task list -> operation_context list
(** [build_operation_contexts ~tasks] projects non-terminal tasks into
    operation rows. Task contracts may provide an operation id; otherwise
    the task id is used as the stable operation id. *)

val build_worker_support_briefs :
  now_ts:float ->
  tasks:Masc_domain.task list ->
  agents:Masc_domain.agent list ->
  messages:Masc_domain.message list ->
  worker_context list
(** [build_worker_support_briefs ~now_ts ~tasks ~agents ~messages]
    returns one {!worker_context} per agent, cross-referencing current tasks
    and messages. Used by {!Dashboard_execution}'s worker-support
    section. *)

val continuity_row_of_keeper :
  now_ts:float ->
  Yojson.Safe.t ->
  continuity_context
(** [continuity_row_of_keeper ~now_ts keeper] is the
    typed primitive shared by the full execution render and live keeper-row
    reconciliation. The primitive owns lifecycle, severity, and wire-field
    derivation. *)

val build_continuity_briefs :
  now_ts:float ->
  Yojson.Safe.t list ->
  continuity_context list
(** [build_continuity_briefs ~now_ts keepers]
    returns one {!continuity_context} per keeper, classifying its
    lifecycle / exec-state against the env-cached thresholds
    ([signal_stale_sec] / [signal_quiet_sec] / [signal_live_sec]
    + [ctx_handoff_imminent] / [ctx_preparing] / [ctx_high]).

    Threshold values are env-cached at module init — runtime env
    mutation does not affect the classification.  Pinned at the
    contract seam so operators understand why "I changed
    SIGNAL_STALE_SEC and nothing happened" — restart required. *)
