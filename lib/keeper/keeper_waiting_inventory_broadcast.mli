(** Invalidate the dashboard Keeper waiting-inventory read model after a
    durable queue mutation. The event carries no queue rows or revision ID;
    consumers in the matching workspace re-read the authoritative inventory. *)

type source = Chat_operation | Event_queue | Approval_count | Approval_detail

val install_health_change_observer : (base_path:string -> unit) -> unit
(** Install the callback for a committed [Approval_count] change. Existing
    queue and Owner projections have their own health observers; approval
    detail changes do not change the health inventory counts. *)

val changed : base_path:string -> keeper_name:string -> source:source -> unit
