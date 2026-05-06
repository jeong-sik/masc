(** Keeper lifecycle callback failure recorder.

    Lifecycle callbacks are non-critical side effects: failure must not
    abort compaction or handoff, but it must be observable as a metric,
    log, and durable telemetry coverage gap. *)

val record :
  base_dir:string ->
  meta:Keeper_types.keeper_meta ->
  callback:string ->
  exn ->
  unit
(** Record one lifecycle callback failure. Re-raises
    [Eio.Cancel.Cancelled] to preserve cooperative cancellation. *)
