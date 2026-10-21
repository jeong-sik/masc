(** Recover the original job's complete result, then durably enqueue one typed
    notification before acknowledging its canonical owner. A later maintenance
    pulse cleans only that acknowledged terminal owner's saved resources and
    retires discovery after cleanup. Result delivery never joins cleanup I/O. *)
type t
val create :
  config:Workspace.config ->
  ?on_result_ready:(Keeper_owned_job_store.record -> unit) ->
  ?on_discovery:(base_path:string -> (unit, Keeper_owned_job_store.error) result -> unit) ->
  unit -> t
(** [on_result_ready] observes an already-ready canonical result after durable
    notification enqueue. It is a lifecycle hint, not delivery or execution
    authority. Observer failures cannot discard the notification or result.

    [on_discovery] receives the actual original discovery/worker-reservation
    result with its base path. [Ok ()] means the pass returned, not that all
    markers were readable or job results delivered. Per-marker failures retain
    their original diagnostics. The default observer logs whole-pass failure.
    Observation is not delivery, Task progress or physical worker-exit proof. *)
val pulse : sw:Eio.Switch.t -> t -> unit
(** Server startup/maintenance entrypoint. Reserve one switch-owned discovery
    child and return without joining the scan. Return is scheduling only; the
    original typed result reaches [on_discovery]. The discovery child yields
    before the original pass. Discovery stays active through observation and
    cleanup; active pulses coalesce and later maintenance scans afresh. Failed
    discovery does not cancel previously admitted job workers or prove absence.

    Within that child, reserve independent lifecycle fibers for each validated
    pending marker before reading later markers. Each job child
    yields inside its reservation cleanup before canonical recovery or backend
    I/O. The scan may yield to admitted children;
    it does not join them or guarantee that the full scan precedes their
    work. A late discovery error retains already reserved workers and their
    switch-owned cleanup. Held hints absent from
    discovery are pruned only after a successful complete scan. A live worker is
    reserved once until it settles or is cancelled. No timer or timeout is added.
    Unchanged previously absent owners use an exact-label presence hint until
    a positive observation requires full reconciliation. A changed owner or a
    new supervisor cannot reuse that process-local held evidence.
    A pulse shares one inventory per equivalent frozen backend route among
    unchanged held owners; each owner checks its own private directory/CLI
    authority. The batch uses a separate empty CLI scope and never advances a
    job phase. Full inspection and new jobs remain independent of this read.
    Single-domain Eio caller; reservations and hints are not effect authority.
    A cancelled or finished switch is rejected before discovery scheduling and
    before each new reservation. Failed scheduling releases the discovery flag;
    a declined [fork] must not leave an active job with no worker to release it.
    Cancellation is not a store error. Protected physical I/O can still delay
    shutdown; discovery/observer cleanup is not backend worker-exit proof. *)

type report =
  { inspected : int; waiting : int; delivered : int; retired : int
  ; failures : (string * Keeper_owned_job_store.error) list }
val reconcile : config:Workspace.config -> (report, Keeper_owned_job_store.error) result
(** Structured one-round entrypoint using the same recovery workers. Waits for
    the selected round. Only pending discovery markers are read. No current
    task/channel, TTL, process registry or replacement job is used. *)
