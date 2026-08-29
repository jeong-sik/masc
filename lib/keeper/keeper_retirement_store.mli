(** Durable record of Keeper incarnations removed by a finalized shutdown.

    One retirement names the exact incarnation (name + trace) a shutdown
    operation removed. [Keeper_registry_event_queue.authorize_durable_intake_owner]
    reads it to keep durable intake closed for the removed incarnation, and
    for the bare name until a new incarnation exists. The fact used to be
    inferred from retained [Finalized { meta_removed = true }] shutdown
    operation records, which forced every such record to survive forever and
    made boot recovery walk them at every start (masc#31686). *)

type entry =
  { trace_id : Keeper_id.Trace_id.t
  ; operation_id : Keeper_shutdown_types.Operation_id.t
  }

val record :
  config:Workspace.config
  -> keeper_name:string
  -> entry
  -> (unit, string) result
(** Append one retirement. Recording a pair that is already present is a
    no-op, so a finalize replayed across a crash converges on one entry. *)

val list_for_keeper :
  config:Workspace.config
  -> keeper_name:string
  -> (entry list, string) result
(** Every recorded retirement for the name, oldest first; [] when the name
    has never been retired. A malformed store document is an explicit error,
    never an empty list. *)
