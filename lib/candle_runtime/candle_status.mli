(** Is Candle on right now (RFC-goal-candle-ledger 3.9)?

    [configured] reads configuration and checks the appraiser without touching
    the ledger. [current] additionally owns recovery: when configuration says
    [Enabled] and the server appraiser check succeeds, the first call
    for a base path in this process runs {!Candle_ledger.recover_at_start} on
    the ledger: a tail left by an append that never finished is cut, and a
    ledger that cannot be read makes the answer [Disabled] instead of blocking
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

val report_at_start : base_path:string -> unit
(** Reads [candle.toml], recovers the ledger when it says [Enabled], and logs
    the answer in one line, so the server's boot log says whether Candle is off,
    on, or disabled and why. It is the first read of the ledger in the process,
    so a tail left by a write that never finished is cut here, before any Goal
    moves. *)

val install_appraiser_check : (unit -> (unit, string) result) -> unit
(** Server-owned dynamic availability check, installed before any Goal lifecycle
    writer starts. Without one, configured Candle is Disabled with an explicit
    reason. Each read observes current lane configuration. *)
