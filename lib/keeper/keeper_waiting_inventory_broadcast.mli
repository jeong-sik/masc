(** Invalidate the dashboard Keeper waiting-inventory read model after a
    durable queue mutation. The event carries no queue rows or revision ID;
    consumers in the matching workspace re-read the authoritative inventory. *)

type source = Chat_operation | Event_queue

val changed : base_path:string -> keeper_name:string -> source:source -> unit
