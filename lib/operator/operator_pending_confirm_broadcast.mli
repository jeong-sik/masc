(** Signals that the confirmations waiting for an operator changed: one was
    written or removed, or one passed its deadline. Signal-only: consumers
    re-fetch them with a query that names its parts, such as
    [/api/v1/operator?view=summary&include_messages=0&include_keepers=0],
    which is computed for each request. The default query serves a snapshot
    kept for a while, which a change does not drop. A broadcast exception is
    logged; {!Eio.Cancel.Cancelled} propagates. *)

val changed_event : string

val changed : base_path:string -> unit
(** [pending_confirms_changed]. [base_path] names the workspace in the log
    line a failed broadcast leaves. *)
