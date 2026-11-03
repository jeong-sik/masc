(** Says that a workspace's repository catalog was written (RFC-0480 §3.4).

    The event is [{"type":"repositories_changed","ts_unix":...}] and goes to
    the observers of [base_path]'s runtime only. A reader that lists the
    repositories ([GET /api/v1/repositories]) reads them again.

    {!install} makes {!Repo_store} report every catalog write to {!changed},
    after it attempts to write the file and under the catalog file lock, so
    {!changed} must not yield and must not raise. An exception from
    [Sse.broadcast_to] or from resolving the runtime, a [Cancelled] included,
    is counted on [keeper_sse_broadcast_failures] and logged at WARN. *)

val changed_event : string

val changed : base_path:string -> unit

val install : unit -> unit
