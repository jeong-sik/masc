(** Signals that a Keeper's questions to the operator changed: one was asked,
    answered or withdrawn. Signal-only: consumers re-fetch
    [/api/v1/keepers/asks]. A broadcast exception is logged;
    {!Eio.Cancel.Cancelled} propagates. *)

val asks_changed_event : string

val asks_changed : keeper_name:string -> unit
(** [keeper_asks_changed]: an event was appended to the Keeper's question log. *)
