
(** Workspace_status_rendering — rendering logic for [masc_status].

    Pure-text status summary for the [masc_status] tool.  The
    main entry point ({!status_summary_string}) renders the
    full operator-visible terminal block (cluster header,
    snapshot line, you-line, task-binding line, planning state,
    credential state, suggestions, attention items, players,
    quest board, messages).

    Two additional helpers
    ({!active_task_assignee}, {!assigned_task_ids}) are used by
    [tool_workspace] for assignee-aware filtering outside the
    rendering path. Deliverable completion-claim detection now
    lives in {!Task_completion_claim} (shared with
    {!Verification_protocol}).

    All formatting helpers (icons, badges, take-items,
    bool-flag) stay private — the rendered string is the
    operator contract; intermediate atoms are not. *)

val active_task_assignee : Masc_domain.task_status -> string option
(** [active_task_assignee status] returns the assignee for the
    active states ([Claimed] / [InProgress] /
    [AwaitingVerification]), and [None] for the terminal /
    unclaimed states ([Todo] / [Done] / [Cancelled]).

    Distinct from [task_assignee] (private): [task_assignee]
    returns ["unclaimed"] for [Todo] and the [cancelled_by]
    name for [Cancelled], which is fine for display but wrong
    for set-membership filtering — this exposed function is
    the canonical "who currently owns the task" predicate. *)

val assigned_task_ids :
  matches_you:(string -> bool) ->
  Masc_domain.task list ->
  string list
(** [assigned_task_ids ~matches_you tasks] filters [tasks] to
    those whose {!active_task_assignee} satisfies [matches_you],
    returning their ids.  [matches_you] is caller-supplied so
    callers can match by name OR by alias set without this
    module knowing the identity model.

    Used by [tool_workspace] to compute "the tasks assigned to you"
    for the [masc_status] response. *)

val status_summary_string :
  task_list_projection:Tool_capability_projection.task_list ->
  ctx:Workspace_types.context ->
  bound:bool ->
  actual_name:string ->
  credential_state:Workspace_types.credential_state ->
  credential_blocked:bool ->
  current_task:string option ->
  effective_cluster_name:string ->
  agents_with_state:(Masc_domain.agent * bool) list ->
  active_tasks:Masc_domain.task list ->
  todo_count:int ->
  claimed_count:int ->
  in_progress_count:int ->
  done_count:int ->
  cancelled_count:int ->
  todo_conflict_task_ids:string list ->
  binding:Workspace_types.current_binding ->
  planning_state:Workspace_types.planning_context_state ->
  suggested_next:string list ->
  attention_items:string list ->
  state:Masc_domain.workspace_state ->
  backlog:Masc_domain.backlog ->
  string
(** [status_summary_string] renders the full [masc_status]
    operator-visible string.  All 22 named arguments are
    required — there is no convenience overload because every
    line is a deliberate operator surface.

    [task_list_projection] is the typed audience projection for follow-up
    guidance: external callers receive [masc_tasks], Keeper models receive
    [keeper_tasks_list].

    {2 Display caps}

    - [agents_with_state]: capped at 40 displayed (with "and N
      more" footer when exceeded).
    - [active_tasks]: capped at 30 displayed (with "and N more"
      footer).

    The 40 / 30 caps are pinned at the contract seam — a
    larger cap would push the snapshot off-screen on standard
    80x24 terminals.

    {2 Output structure (line order pinned)}

    1. Cluster header (icon + name)
    2. Project line (only when project ≠ cluster)
    3. Scope + path
    4. Snapshot line (counters)
    5. You-line (agent / bound / owned / current)
    6. Task binding line (assigned set / drift reason)
    7. Planning lines (missing-task / deliverable-conflict)
    8. Credential line (only when required)
    9. Suggested-next line (only when non-empty)
    10. Attention block (only when non-empty)
    11. Players block (capped at 40)
    12. Quest Board (capped at 30)
    13. Summary line
    14. Messages line

    The icon set (🏢 / 📦 / 📍 / 📁 / ⚡ / 🧭 / 🔎 / 📝 / 🔐 /
    💡 / ⚠️ / 📌 / 📋 / 💬) is operator-visible — runbook
    screenshots reference these symbols. *)
