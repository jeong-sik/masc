(** Signals that the tool calls a Keeper holds for an operator, or the
    Keeper's tool approval mode, changed. Both are signal-only: consumers
    re-fetch [/api/v1/keepers/tool-approvals] or
    [/api/v1/keepers/tool-approval-mode]. A broadcast exception is logged;
    {!Eio.Cancel.Cancelled} propagates. *)

val waits_changed_event : string
val waits_changed : keeper_name:string -> unit
(** [keeper_tool_approval_waits_changed]: a wait was added, answered, timed
    out or ended with its turn. *)

val mode_changed_event : string
val mode_changed : keeper_name:string -> unit
(** [keeper_tool_approval_mode_changed]: a write to the Keeper's mode ran. *)
