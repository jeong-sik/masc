(** Recover the original job's complete result, then durably enqueue one typed
    notification before acknowledging its canonical owner. A later maintenance
    pulse cleans only that acknowledged terminal owner's saved resources and
    retires discovery after cleanup. Result delivery never joins cleanup I/O. *)
type t
val create : config:Workspace.config -> ?on_result_ready:(Keeper_owned_job_store.record -> unit) -> unit -> t
(** [on_result_ready] observes an already-ready canonical result after durable
    notification enqueue. It is a lifecycle hint, not delivery or execution
    authority. Observer failures cannot discard the notification or result. *)
val pulse : sw:Eio.Switch.t -> t -> (unit, Keeper_owned_job_store.error) result
(** Server startup/maintenance entrypoint. Reserve independent lifecycle fibers
    for pending jobs; the pulse does not wait for backend I/O. A live worker is
    reserved once until it settles or is cancelled. No timer or timeout is added.
    Unchanged previously absent owners use an exact-label presence hint until
    a positive observation requires full reconciliation. A changed owner or a
    new supervisor cannot reuse that process-local held evidence.
    A pulse shares one inventory per equivalent frozen backend route among
    unchanged held owners; each owner checks its own private directory/CLI
    authority. The batch uses a separate empty CLI scope and never advances a
    job phase. Full inspection and new jobs remain independent of this read.
    Single-domain Eio caller; reservations and hints are not effect authority. *)

type report =
  { inspected : int; waiting : int; delivered : int; retired : int
  ; failures : (string * Keeper_owned_job_store.error) list }
val reconcile : config:Workspace.config -> (report, Keeper_owned_job_store.error) result
(** Structured one-round entrypoint using the same recovery workers. Waits for
    the selected round. Only pending discovery markers are read. No current
    task/channel, TTL, process registry or replacement job is used. *)
