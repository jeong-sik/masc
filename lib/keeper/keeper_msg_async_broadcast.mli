(** Signals that a Keeper's durable async message requests changed: a record
    was written or removed from the active inventory, or one of the Keeper's
    composition execution journals was written. Signal-only: consumers
    re-fetch [/api/v1/async-requests] and an open request's detail. A
    broadcast exception is logged; {!Eio.Cancel.Cancelled} propagates. *)

val requests_changed_event : string

val requests_changed : keeper_name:string -> unit
(** [keeper_async_requests_changed]: a request record or execution journal
    of the Keeper was written or removed, or may have been (a write whose
    publication is uncertain). *)
