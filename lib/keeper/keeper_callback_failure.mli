(** Keeper lifecycle callback failure recorder.

    Lifecycle callbacks are non-critical side effects: failure must not
    abort handoff, but it must be observable as a metric,
    log, and durable telemetry coverage gap. *)

val record :
  masc_root:string ->
  meta:Keeper_meta_contract.keeper_meta ->
  callback:string ->
  exn ->
  unit
(** Record one lifecycle callback failure. [masc_root] is [<base>/.masc],
    the root the coverage-gap store lives under, as
    {!Telemetry_coverage_gap.record} takes it. Re-raises [Eio.Cancel.Cancelled] to preserve cooperative
    cancellation. *)
