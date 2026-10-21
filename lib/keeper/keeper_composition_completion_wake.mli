(** Keeper_composition_completion_wake — tell a Keeper that the async
    composition it submitted has finished.

    An async [keeper_compose_*] call returns a request id and does not wait.
    Before this module the result reached the submitter only if it went back
    and read that id. Measured over 2026-08-18..26 on the live store: 22
    submissions produced 12 reads, and a settled result waited a median of
    21.9s to be collected against a median 2.7ms of work — one waited 47
    minutes. The wrapper meant to keep a turn free was making the answer
    arrive later than running it inline would have.

    The stimulus is committed through the same fail-closed durable path the
    delegation answer uses, so a failed write is reported rather than
    swallowed. The live wake that follows is a hint: it only reaches a
    [Running] Keeper, and its failure is logged, because the committed
    stimulus is already in the queue the Keeper drains on its next admitted
    turn.

    The result body is not carried. It is already durable in the async
    request record and [keeper_composition_status] reads it by request id;
    copying it here would put the same bytes in two durable stores.
    A composition records its completion-delivery obligation before starting
    the worker. Failed delivery is reconciled from exact canonical terminal
    proof on startup and the existing maintenance pulse, without replay. *)

val deliver
  :  not_before:float
  -> base_path:string
  -> keeper_name:string
  -> request_id:string
  -> composition_tool:string
  -> terminal:Keeper_event_queue.composition_terminal
  -> (unit, string) result
(** [not_before] is the request's submission time as a Unix timestamp; it is
    forwarded as the floor of the negative-delivery-evidence scan so a torn
    write in an older, unrelated ledger partition cannot reject this
    delivery. Both production callers pass the canonical request's
    [submitted_at]; [0.] means no floor and scans the whole ledger. *)

val terminal_of_status :
  Keeper_msg_async.request_status -> Keeper_event_queue.composition_terminal option
(** Canonical settled outcome used by delivery and result projection.
    Active request states have no terminal completion. *)

val on_worker_settled
  :  base_path:string
  -> composition_tool:string
  -> Keeper_msg_async.worker_settlement
  -> unit
(** Adapter for {!Keeper_msg_async.submit_with_request_id}'s
    [?on_worker_settled]. A settlement that is not durably canonical, or that
    reports a projection error, is logged and not delivered: telling a Keeper
    its work succeeded on evidence the store does not hold would be worse than
    leaving it to read the record itself. A non-terminal status is not a
    settlement to announce and is ignored. *)

val reconcile : base_path:string -> (Keeper_composition_completion_outbox.report,
                                     Keeper_composition_completion_outbox.error) result
(** Recover pending completion deliveries from canonical request records on
    startup and the existing maintenance pulse. Does not replay worker effects. *)

type t
val create :
  base_path:string ->
  ?on_report:(keeper_name:string -> Keeper_composition_completion_outbox.report -> unit) ->
  ?on_discovery:(base_path:string ->
    (unit, Keeper_composition_completion_outbox.error) result -> unit) ->
  unit -> t
(** Server-lifetime supervisor. [on_report] covers settled original-owner
    batches, before observer/active cleanup, not consumption, logical
    Composition progress or worker-exit proof. Observer failure cannot undo
    committed delivery.

    [on_discovery] receives the actual outbox discovery and owner-reservation
    result with the original base path. [Ok ()] means that pass returned, not
    that owner delivery finished or every pending record was readable. Partial
    malformed/unreadable records retain their original diagnostics while
    healthy owners can recover. The default observer logs whole-discovery
    failure. No obligation or canonical result body reaches this observer. *)

val pulse : sw:Eio.Switch.t -> t -> unit
(** Reserve a switch-owned discovery child and return without joining outbox
    discovery. Return is scheduling only; the original typed discovery result
    reaches [on_discovery]. The child yields before the original pass. One
    discovery remains active through observation and cleanup; active pulses
    coalesce. Complete discovery still precedes owner reservations within the
    child. A failed discovery neither cancels existing owners nor proves absence.

    Validated original obligations reserve one worker per non-active Keeper
    under the original supplied switch. Owner workers yield before delivery
    and preserve that owner's original discovery order. Each obligation is
    reread and must match its original root/request/recipient, then current
    terminal/journal/waiting proof and once-only queue checks apply.
    New obligations for an active owner wait for a later admitted discovery.
    No captured obligation/result is reused across owner workers. Active owners
    remain until worker/cancellation cleanup. Check the supplied lifetime switch
    before discovery scheduling and each owner reservation. Failed discovery
    scheduling releases its active flag. Cancellation is not a storage failure;
    protected physical I/O can still delay shutdown. No new timer, retry cap,
    pool, execution permission or replacement request. Single-domain Eio caller;
    active flags are scheduling hints only. *)
