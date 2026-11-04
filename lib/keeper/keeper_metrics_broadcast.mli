(** Says that a Keeper's metrics file gained a row (RFC-0480 §3.4).

    The event is [{"type":"keeper_metrics_appended","name":...,"ts_unix":...}]
    and goes to the observers of [base_path]'s runtime only. It carries no row:
    a reader that shows the metrics (the TUI's logs view and Info tab) reads
    the file again.

    {!Keeper_types_support.append_keeper_metrics} sends it after the row is
    written. Its writers are the heartbeat snapshot and the finished turn. An
    exception from resolving the runtime or from [Sse.broadcast_to] is counted
    on [keeper_sse_broadcast_failures] and logged at WARN; [Cancelled] is
    raised again. *)

val appended_event : string

val appended : base_path:string -> name:string -> unit
