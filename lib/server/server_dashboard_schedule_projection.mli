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

    A ledger read failure is reported, not hidden: [status] is ["unknown"],
    [counts] / [request_count] / [fsm.active_count] are [null], and
    [schedule_store_read_error] carries the reason. Consumers must render that
    as unknown rather than as zero schedules. *)
