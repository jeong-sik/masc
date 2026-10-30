(** Schedule projection owner — sole producer of
    [masc.dashboard.scheduled_automation.v1].

    Served by [GET /api/v1/dashboard/scheduled-automation] on both the HTTP/1
    router and the H2 gateway. No other module renders this projection, and it
    is not embedded in any other response. *)

val schedule_projection_target_request_limit : int
(** Row ceiling for a target-scoped page. Its own number, larger than the fleet
    cap, because a request already narrowed to one target does not need the
    bound that exists to keep a whole-store scan small. *)

val scheduled_automation_dashboard_json :
  ?payload_target:string -> ?cursor:string -> Workspace.config -> Yojson.Safe.t
(** Renders the read-only dashboard projection for scheduled internal
    automation. This summarizes the schedule store as a small FSM envelope
    plus recent request rows; it does not refresh due state or run work.

    [payload_target] narrows every part of the response about schedules --
    rows, counts, FSM envelope, and signals -- to the schedules aimed at that
    target, and the response echoes it in [payload_target_selector] so a
    scoped page cannot be read as the fleet's. The fleet page caps at 20 rows
    with active ones first; target-scoped pages use their own limit.
    [next_cursor], when present, continues the same target's ordering. A cursor
    from another target or a malformed cursor yields [status=invalid_cursor]
    rather than an empty page. Pages are independent store observations, not
    a snapshot: a schedule changed or created between reads can move across
    the boundary. [page_cursor] echoes the accepted cursor, or null on the
    first page. [truncated] says the page does not contain the whole selection,
    not that a next page exists; use [next_cursor] for that decision.

    Reads the schedule ledger from disk, so callers on an Eio fiber wrap this
    in [Domain_pool_ref.submit_io_or_inline].

    Keeper queue evidence includes pending, committed terminal/transfer
    projection and exact retired receipts. It reuses the dispatch resolver's
    latest-incarnation, conflict and transfer semantics, with complete lock-free
    owner observations captured before reaction ledger reads. Compact source
    receipts are verified against the exact occurrence's dispatch source hash.
    Per-owner coherence does not imply a global cross-store transaction.

    Keeper queue evidence uses a lock-free, non-compacting durable observer,
    and reaction evidence is indexed once per Keeper for the bounded request
    rows. A GET therefore never enters the queue-owner transaction boundary
    and never rescans one Keeper's complete reaction ledger per row.

    Each request row carries [runner_hold]: the occurrence the schedule
    runner's newest successful tick held back for that schedule, read from
    [Schedule_runner_status] (the list [/health] reports as
    [schedule_runner.held]), or [null] when it holds none. Its [observed_at]
    is when that tick decided the hold. The response carries the runner's
    status word once, as [schedule_runner.status] -- the word [/health]
    reports, with the same threshold -- because a tick that fails does not
    re-read the list, and only that word says whether a hold is current. The
    object carries nothing else, so a page scoped to one target does not carry
    the fleet's holds or counts.

    A ledger read failure is reported, not hidden: [status] is ["unknown"],
    [counts] / [request_count] / [fsm.active_count] are [null], and
    [schedule_store_read_error] carries the reason. Consumers must render that
    as unknown rather than as zero schedules. *)

val scheduled_automation_exact_lookup_json :
  Workspace.config -> now:float -> schedule_id:string -> Yojson.Safe.t
(** Renders one exact schedule through the same request-row encoder as the
    aggregate projection. The closed [status] is [found], [not_found],
    [unavailable], or [invalid_id]. *)
