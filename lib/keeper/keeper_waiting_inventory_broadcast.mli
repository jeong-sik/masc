(** Invalidate the dashboard Keeper waiting-inventory read model after a
    durable queue mutation. The event carries no queue rows or revision ID;
    consumers re-read the authoritative waiting inventory. *)

type source = Chat_operation | Event_queue

val changed : keeper_name:string -> source:source -> unit
