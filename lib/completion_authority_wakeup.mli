(** Reactive wake-up after a completion authority rejects submitted evidence.

    The completion authority remains a system operator; this module only
    delivers the result to the producer Keeper when a live lane exists. *)

val wake_rejected_producer :
  config:Workspace_utils_backend_setup.config -> producer:string -> task_id:string -> unit
