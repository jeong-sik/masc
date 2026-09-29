(** Candle policy, appraiser availability and ledger recovery
    (RFC-goal-candle-ledger 3.9).

    [configured] reads configuration and checks the appraiser without touching
    the ledger. [current] adds ledger recovery to that availability check.
    [for_recording] reads the same configuration and owns the same recovery
    without checking the appraiser: its temporary absence cannot discard
    Snapshot or PayoutOwed facts. Thus an availability-related [Disabled]
    returned by [configured] or [current] does not disable those writers.

    The first eligible recovery call for a base path in this process runs
    {!Candle_ledger.recover_at_start}: a tail left by an append that never
    finished is cut, and a ledger that cannot be read makes the answer
    [Disabled] instead of blocking
    what asked. A failed recovery is not remembered, so the next call tries
    again and a repaired ledger clears the answer without a restart.

    A ledger that another process is writing right now is not one that cannot
    be read. The recovery is skipped and not remembered, and the answer stays
    [Enabled], so [Enabled] means the ledger was recovered or its recovery is
    waiting for that lock. A Goal that passes meanwhile is refused by the
    Snapshot step (it asks the ledger for the same lock) and not let through
    without a Snapshot.

    Recovery runs once per process. A tail left later refuses every transition
    until the server restarts. Two things leave one: a second writer that died
    mid-append, and an append of this process whose rollback failed too. *)

val configured : base_path:string -> Candle_config.t
(** Current configuration and appraiser availability only. Does not recover,
    truncate or otherwise change the ledger. Read and purchase surfaces use
    this before their authoritative ledger read. *)

val current : base_path:string -> Candle_config.t

val for_recording : base_path:string -> Candle_config.t
(** Configuration and ledger recovery for the durable Snapshot and PayoutOwed
    steps, without consulting appraiser availability. An unpublished, busy or
    unavailable appraiser may postpone settlement, but must not let a Goal pass
    or complete without these facts when its Candle policy is enabled.
    Configuration and recovery failures retain the same Off/Disabled semantics
    as {!current}; the ledger still arbitrates each following append. *)

val report_at_start : base_path:string -> unit
(** Reports {!current}, including the reason when unavailable. When the
    appraiser is available, this performs recovery before Goal writers start.
    Otherwise the first {!for_recording} call performs the same recovery
    before appending a durable Goal fact. *)

val install_appraiser_check : (unit -> (unit, string) result) -> unit
(** Server-owned dynamic availability check for {!configured} and {!current}.
    Without one, those queries report Disabled with an explicit reason.
    {!for_recording} does not depend on hook installation or lane publication. *)
