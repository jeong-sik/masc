open Base

(** Coord_status_rendering — rendering logic for [masc_status].

    Pure-text status summary for the [masc_status] tool.  The
    main entry point ({!status_summary_string}) renders the
    full operator-visible terminal block (cluster header,
    snapshot line, you-line, task-binding line, planning state,
    credential state, suggestions, attention items, players,
    quest board, messages).

    Three additional helpers
    ({!active_task_assignee}, {!assigned_task_ids},
    {!deliverable_claims_completion}) are used by [tool_coord]
    for assignee-aware filtering and deliverable-completion
    detection outside the rendering path.

    All formatting helpers (icons, badges, take-items,
    bool-flag) stay private — the rendered string is the
    operator contract; intermediate atoms are not. *)

val active_task_assignee : Types.task_status -> string option
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
  Types.task list ->
  string list
(** [assigned_task_ids ~matches_you tasks] filters [tasks] to
    those whose {!active_task_assignee} satisfies [matches_you],
    returning their ids.  [matches_you] is caller-supplied so
    callers can match by name OR by alias set without this
    module knowing the identity model.

    Used by [tool_coord] to compute "the tasks assigned to you"
    for the [masc_status] response. *)

val deliverable_claims_completion :
  task_id:string -> string -> bool
(** [deliverable_claims_completion ~task_id deliverable] returns
    [true] iff [deliverable]'s normalised first line claims
    completion of [task_id].

    {2 Detection rules (case-insensitive on a trimmed first line)}

    | Pattern | Match |
    |---|---|
    | [["<task_id> completed"]] | yes |
    | [["completed"]] (any task) | yes |
    | empty | no |
    | otherwise | no |

    The "completed" prefix-match is intentional — it catches
    LLM-generated text that uses "completed: ..." or
    "completed and verified by ..." while not mistaking
    "completion was attempted" for a real claim.  Pinning at
    the contract seam so a future "stricter pattern" PR must
    touch this explicitly. *)

val status_summary_string :
  ctx:Coord_types.context ->
  joined:bool ->
  actual_name:string ->
  credential_state:Coord_types.credential_state ->
  credential_blocked:bool ->
  current_task:string option ->
  worktree_active:bool ->
  effective_cluster_name:string ->
  agents_with_state:(Types.agent * bool) list ->
  active_tasks:Types.task list ->
  todo_count:int ->
  claimed_count:int ->
  in_progress_count:int ->
  done_count:int ->
  cancelled_count:int ->
  todo_conflict_task_ids:string list ->
  binding:Coord_types.current_binding ->
  planning_state:Coord_types.planning_context_state ->
  suggested_next:string list ->
  attention_items:string list ->
  state:Types.room_state ->
  backlog:Types.backlog ->
  string
(** [status_summary_string] renders the full [masc_status]
    operator-visible string.  All 21 named arguments are
    required — there is no convenience overload because every
    line is a deliberate operator surface.

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
    5. You-line (agent / joined / owned / current / worktree)
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
