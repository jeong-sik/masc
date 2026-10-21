module Recovery = Masc.Keeper_event_queue_recovery

type source = Startup | Maintenance
type t

val create :
  base_path:string -> budget:Recovery.owner_budget ->
  ?on_page:(source:source -> base_path:string -> Recovery.sweep_page -> unit) ->
  unit -> t
(** One server-lifetime cursor and active-page owner, bound to the original
    base path and validated page size. The observer receives the exact returned
    page after its next cursor is committed, before active cleanup. Observer
    failure cannot roll back durable effects or the committed cursor. *)

val pulse : sw:Eio.Switch.t -> t -> source -> unit
(** Reserve one switch-owned worker and return without joining the existing
    strict executor's discovery/owner-page operation. The worker yields first;
    the original owner ordering, process claims, shutdown fences, transfer
    target-before-source retirement and executor policy remain authoritative.
    Active pulses coalesce without replacing the captured cursor/source.

    Commit only the cursor returned by the actual page. Executor unavailability
    keeps its original typed empty-page/unchanged-cursor result. If cancellation
    or an exception prevents observing a page, retain the prior cursor for a
    fresh durable retry; completed effects may already exist. Keep active through
    the observer and cancellation cleanup. Reject cancelled/finished switches
    before reservation/fork and propagate structural cancellation. Physical
    worker cleanup remains with the original strict executor. Single-domain
    Eio caller; no timer, retry interval, inline fallback or result cache. *)
