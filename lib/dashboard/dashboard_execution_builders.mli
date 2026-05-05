(** Dashboard_execution_builders — agent / keeper brief builders
    for the execution dashboard.

    {b Cascade chain}: starts with
    [include Dashboard_execution_sessions] (which itself includes
    Dashboard_execution_helpers).
    {!Dashboard_execution} does
    [include Dashboard_execution_builders] to make the four brief
    builders visible bare in the dashboard JSON dispatcher.

    Internal: 17 entries stay private — 2 module-local types
    ([keeper_lifecycle] / [keeper_exec_state]) + their string
    converters, 7 env-cached threshold constants
    ([signal_*_sec] / [ctx_*] / [keeper_action_stale_sec]),
    3 task / message / agent helpers, and 1 continuity-row
    builder.  Future "expose threshold constants" PR can reopen
    explicitly. *)

include module type of struct
  include Dashboard_execution_sessions
end

(** {1 Brief builders (cascade-visible)} *)

val task_assignee : Masc_domain.task -> string option
(** [task_assignee task] returns [Some assignee] when [task] is in
    a status that carries an assignee ([Claimed] / [InProgress] /
    [AwaitingVerification] / [Done]); else [None].  Pinned at the
    contract seam — adding a new task status that should also
    carry an assignee requires extending this match. *)

val build_operation_contexts : tasks:Masc_domain.task list -> operation_context list
(** [build_operation_contexts ~tasks] projects non-terminal tasks into
    operation rows.  Task contracts provide operation/session links when
    present; otherwise the task id is used as a stable operation id. *)

val build_worker_support_briefs :
  now_ts:float ->
  tasks:Masc_domain.task list ->
  agents:Masc_domain.agent list ->
  messages:Masc_domain.message list ->
  session_context list ->
  worker_context list
(** [build_worker_support_briefs ~now_ts ~tasks ~agents ~messages
      session_contexts] returns one {!worker_context} per agent,
    cross-referencing tasks, messages, and the resolved session
    membership.  Used by {!Dashboard_execution}'s worker-support
    section. *)

val build_continuity_briefs :
  now_ts:float ->
  Yojson.Safe.t list ->
  session_context list ->
  continuity_context list
(** [build_continuity_briefs ~now_ts keepers session_contexts]
    returns one {!continuity_context} per keeper, classifying its
    lifecycle / exec-state against the env-cached thresholds
    ([signal_stale_sec] / [signal_quiet_sec] / [signal_live_sec]
    + [ctx_handoff_imminent] / [ctx_preparing] / [ctx_compacting]).

    Threshold values are env-cached at module init — runtime env
    mutation does not affect the classification.  Pinned at the
    contract seam so operators understand why "I changed
    SIGNAL_STALE_SEC and nothing happened" — restart required. *)
