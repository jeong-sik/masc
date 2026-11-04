(** Says that a workspace's lane add-on tool exports may have changed
    (RFC-0480 §3.4).

    The event is [{"type":"lane_addon_exports_changed","ts_unix":...}] and goes
    to the observer sessions of [base_path]'s runtime only, not to external
    subscribers, since the caller may hold a lane add-on mutex. A reader that
    shows the tools a Keeper can call ([GET /api/v1/dashboard/tools]) reads
    them again.

    [Lane_addon_runtime.notify_exports] sends it beside the owner event and the
    MCP [tools/list_changed] it already sends, so every lifecycle step that
    moves an export (attach, observation, failure, detach, recovery) announces.
    Like [tools/list_changed], only a package that exports tools announces: a
    package with none changes no Keeper's tools.
    It must not yield and must not raise: an exception from
    [Sse.broadcast_to_sse_runtime_observers] or from resolving the runtime, a
    [Cancelled] included, is counted on [keeper_sse_broadcast_failures] and
    logged at WARN. This differs from [Keeper_metrics_broadcast], which raises
    [Cancelled] again because the announcement is the last step of its caller.
    Here the caller still has steps after the announcement: it persists the
    entry, wakes its waiters or stops it ([Lane_addon_runtime.detach_entry],
    the operator call's retire). A raise would skip them. The fiber's
    cancellation is still seen at its next suspension point. *)

val changed_event : string

val changed : base_path:string -> unit
