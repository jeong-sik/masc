(** Signals that a workspace's schedules changed. Signal-only: consumers
    re-fetch [/api/v1/dashboard/scheduled-automation]. A broadcast exception
    is logged; {!Eio.Cancel.Cancelled} propagates. A broadcast also runs the
    external subscribers' callbacks, which write to WebSocket and gRPC
    streams, so it never runs on a schedule store writer. *)

val changed_event : string

val changed : base_path:string -> unit
(** [schedules_changed]. [base_path] names the workspace in the log line a
    failed broadcast leaves. *)

val install_store_announcer : sw:Eio.Switch.t -> unit
(** Installs the schedule store's change observer and the fiber that
    announces for it. The observer drops the workspace's cached [/health]
    snapshot and fleet schedule list on the writer, then wakes the fiber,
    which signals {!changed}: a reader that answers the signal reads the
    write. Writes that land before the fiber runs are announced once. *)
