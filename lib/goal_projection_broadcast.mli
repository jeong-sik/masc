(** Says that a workspace's Goal projection changed (RFC-0480 §3.4).

    The event is [{"type":"goal_projection_changed","ts_unix":...}] and goes to
    the observer sessions of [base_path]'s runtime only, not to external
    subscribers: an external callback may wait, and this runs under the
    writer's lock. A reader that shows Goals
    ([GET /api/v1/dashboard/planning], [GET /api/v1/dashboard/goals]) reads them
    again.

    The server's Goal projection mutation hook
    ({!Workspace_hooks.on_goal_projection_mutation_fn}) sends it after it drops
    the planning cache. The Goal store, the verification ledger and the
    measurement store run that hook after their primary write, under their
    lock, so this must not yield and must not raise. An exception from
    [Sse.broadcast_to] or from resolving the runtime, a [Cancelled] included,
    is counted on [keeper_sse_broadcast_failures] and logged at WARN. *)

val changed_event : string

val changed : base_path:string -> unit
