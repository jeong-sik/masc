(** Signals that the Gate snapshot ([/api/v1/dashboard/gate]) changed. *)

val install_before_gate_changed : (base_path:string -> unit) -> unit
(** Install the function {!before_gate_changed} runs. The server installs one
    that drops the cached Gate snapshots of [base_path], so a reader that
    fetches the snapshot on a Gate event computes it again. *)

val before_gate_changed : base_path:string -> unit
(** Run the installed function. An exception from it is logged and the caller
    still sends its event; {!Eio.Cancel.Cancelled} propagates. *)

val approval_rules_changed_event : string
(** The [type] of the event {!approval_rules_changed} sends. *)

val approval_rules_changed : base_path:string -> unit
(** Drop the cached Gate snapshot, then broadcast a signal-only
    [approval_rules_changed] event: the standing approval rules changed.
    Consumers re-fetch [/api/v1/dashboard/gate]. A broadcast exception is
    logged; {!Eio.Cancel.Cancelled} propagates. *)
