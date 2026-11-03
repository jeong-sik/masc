(** Says that a workspace's verification request store was written
    (RFC-0480 §3.4).

    The event is [{"type":"verification_requests_changed","ts_unix":...}] and
    goes to the observers of [base_path]'s runtime only. A reader that shows
    the requests ([GET /api/v1/verification/requests]) reads them again.

    {!Verification.save_request} sends it after a request file is written and
    {!Verification.delete_request} after one is removed. Both run inside the
    backlog transaction's lock, so it must not yield and must not raise. An
    exception from [Sse.broadcast_to] or from resolving the runtime, a
    [Cancelled] included, is counted on [keeper_sse_broadcast_failures] and
    logged at WARN. *)

val changed_event : string

val changed : base_path:string -> unit
