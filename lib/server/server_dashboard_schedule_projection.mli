(** Schedule projection owner — sole producer of
    [masc.dashboard.scheduled_automation.v1].

    Served by [GET /api/v1/dashboard/scheduled-automation] on both the HTTP/1
    router and the H2 gateway. No other module renders this projection, and it
    is not embedded in any other response. *)

val scheduled_automation_dashboard_json : Workspace.config -> Yojson.Safe.t
(** Renders the read-only dashboard projection for scheduled internal
    automation. This summarizes the schedule store as a small FSM envelope
    plus recent request rows; it does not refresh due state or run work.

    Reads the schedule ledger from disk, so callers on an Eio fiber wrap this
    in [Domain_pool_ref.submit_io_or_inline].

    Keeper queue evidence uses a lock-free, non-compacting durable observer,
    and reaction evidence is indexed once per Keeper for the bounded request
    rows. A GET therefore never enters the queue-owner transaction boundary
    and never rescans one Keeper's complete reaction ledger per row.

    A ledger read failure is reported, not hidden: [status] is ["unknown"],
    [counts] / [request_count] / [fsm.active_count] are [null], and
    [schedule_store_read_error] carries the reason. Consumers must render that
    as unknown rather than as zero schedules. *)

val scheduled_automation_exact_lookup_json :
  Workspace.config -> now:float -> schedule_id:string -> Yojson.Safe.t
(** Renders one exact schedule through the same request-row encoder as the
    aggregate projection. The closed [status] is [found], [not_found],
    [unavailable], or [invalid_id]. *)
