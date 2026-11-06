(** The runtime history, [GET /api/v1/runtime/metrics]: every Keeper's
    decision rows and the cost ledger's rows of the last day, per executed
    runtime.

    The rows are kept between reads ({!Model_inference_metrics_kept}), so a
    read after a [runtime_metrics] push reads only the rows written since. *)

val window_minutes : int

val read : base_path:string -> now:float -> Yojson.Safe.t
(** The history of the day that ends at [now]. The first read of a file reads
    it whole; run it on a worker. *)

val install : sw:Eio.Switch.t -> clock:_ Eio.Time.clock -> config:Workspace.config -> unit
(** Announce [runtime_metrics] when a cost ledger row lands in [config]'s
    workspace ({!Cost_ledger_row_signal}; decision rows announce at their
    writer, {!Keeper_types_support.append_decision_record}), and when a row or
    cost day file the history keeps leaves its window. The fiber forked on
    [sw] sleeps until the earliest such instant and wakes early when a read
    keeps new rows. *)
