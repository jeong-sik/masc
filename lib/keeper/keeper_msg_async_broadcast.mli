(** Signals that a Keeper's durable async message requests changed: a record
    was written, or removed from the active inventory. Signal-only: consumers
    re-fetch [/api/v1/async-requests]. A broadcast exception is logged;
    {!Eio.Cancel.Cancelled} propagates. *)

val requests_changed_event : string

val requests_changed : keeper_name:string -> unit
(** [keeper_async_requests_changed]: a request record of the Keeper was
    written or removed, or may have been (a write whose publication is
    uncertain). *)
