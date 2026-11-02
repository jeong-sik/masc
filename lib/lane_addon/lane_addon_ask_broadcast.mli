(** Signals that a Lane Add-on installation's questions to the operator
    changed: one was asked, answered or withdrawn. Signal-only: consumers
    re-fetch [/api/v1/lane-addons/asks]. A broadcast exception is logged;
    {!Eio.Cancel.Cancelled} propagates. *)

val asks_changed_event : string

val asks_changed : declaration_id:string -> unit
(** [lane_addon_asks_changed]: an event was appended to the declaration's
    question log. *)
