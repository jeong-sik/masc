(** Signals that the confirmations waiting for an operator changed: one was
    written or removed, or one passed its deadline. Signal-only: consumers
    re-fetch them from the operator snapshot, such as
    [/api/v1/operator?view=summary&include_messages=0&include_keepers=0].
    Every operator snapshot query is cached for a while
    ({!Operator_control_snapshot_cache}), so {!changed} drops the cached
    snapshots before it signals; a reader it wakes computes the change. A
    broadcast exception is logged; {!Eio.Cancel.Cancelled} propagates. *)

val changed_event : string

val changed : base_path:string -> unit
(** [pending_confirms_changed]. [base_path] names the workspace in the log
    line a failed broadcast leaves. *)
