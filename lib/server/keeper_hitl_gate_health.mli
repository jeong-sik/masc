(* The keeper_hitl_gate section of /health?full=1 (task-1665, design D1).

   One operator-facing projection over the same two sources the product
   already reads: the live waits behind GET /api/v1/keepers/tool-approvals
   (in-memory registry) and the durable asks behind the workspace approval
   queue. The aggregation is pure and closed over the queue's typed states —
   no status string is ever matched — so the server route and the tests read
   one function.

   Status vocabulary is the shared health grade vocabulary so the operator
   rollup picks the section up by its ordinary parse:
   - ok — open asks working as designed: held calls, queued asks, and a
     summary not yet requested. They are visible through the counts and
     [oldest] without raising the workspace's overall grade, because a
     manual-mode workspace owing a human answer is normal operation, not a
     degraded subsystem.
   - warning + operator action — [exact_bound_residual] rows: exact-bound
     asks boot recovery passes over and nothing automatically finalizes
     (design B3's gap). Only an operator unblocks those.
   - unavailable + operator action — the durable queue could not be read;
     an unread authority never counts as an empty gate. *)

val schema : string

val aggregate :
  now:float ->
  is_live:(Keeper_approval_queue_rules_types.pending_approval -> bool) ->
  waits:Keeper_tool_approval_registry.pending list ->
  entries:Keeper_approval_queue_rules_types.pending_approval list ->
  unread_entries:int ->
  answered_total:int ->
  timed_out_total:int ->
  late_uncertain:int ->
  Yojson.Safe.t
(** The section for a readable queue.

    [waits] is the registry listing exactly as the tool-approvals route
    serves it; [entries] is the durable queue read for the asking
    workspace. [answered_total]/[timed_out_total] are the registry's
    process-lifetime outcome counters (design D3's measurement source).
    [late_uncertain] counts the asking workspace's consume-without-deliver
    records in the late-approval journal (design D2). The outcome of those
    calls is unknown, so a non-zero count is an operator-attention reason:
    status [warning] with [operator_action_required].

    [is_live] answers whether this process holds the live admission for an
    entry. An in-flight judgment carries an exact attempt that is
    dispatch-uncertain by construction, so durable state alone cannot tell
    the finalizer's own work from what a restart stranded; the admission
    does. Only an in-flight row without it is a residual.

    [unread_entries] counts pending rows the queue could not read. A
    non-zero value makes the counts a lower bound: [counts_complete] is
    false and the section asks for an operator.

    [oldest] is [null] when nothing is open. Otherwise it is the open ask
    with the smallest timestamp across both sources: a live wait carries its
    [timeout_sec] and call id, a durable entry carries [null] for both,
    because a durable row is not itself a held call.

    A live wait never drives attention: a wait that outlives its budget is
    already off the registry, so the attention threshold in the design draft
    (age over [timeout_sec * 2]) has nothing to fire on. The durable counts
    are what can go stale, so they are what the status reads. *)

val no_workspace_json :
  now:float ->
  waits:Keeper_tool_approval_registry.pending list ->
  answered_total:int ->
  timed_out_total:int ->
  late_uncertain:int ->
  unit ->
  Yojson.Safe.t
(** The section when the server has no workspace state to scope the durable
    queue read with. The live-wait side stays real; the durable counts are
    not zeros and say so through ["counts_complete": false]. *)

val queue_unreadable_json : error:string -> Yojson.Safe.t
(** The section when the durable queue could not be read. An unread
    authority is not an empty gate: status is unavailable and the section
    demands an operator, rather than reporting counts that would silently
    read as "nothing pending". *)

val late_journal_unavailable_json : error:string -> Yojson.Safe.t
(** The section when the late-approval journal is fenced (corrupt or
    unavailable). Every late-answer write is refused meanwhile, so the
    section is unavailable and demands an operator through
    [operator_action_required], which the rollup reads. *)
