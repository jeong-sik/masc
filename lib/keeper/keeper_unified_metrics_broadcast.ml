(** Keeper compaction SSE broadcast helper, extracted from
    keeper_unified_metrics.ml.

    Pure write-only side-effects (SSE broadcast + failure counter); no
    keeper lifecycle state owned here. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile
open Keeper_context_runtime

let broadcast_compaction
      ~(name : string)
      (recovery : Keeper_post_turn.compaction_recovery)
  =
  try
    Sse.broadcast
      (`Assoc
        [ "type", `String "keeper_compaction"
        ; "name", `String name
        ; "outcome", `String "applied_checkpoint"
        ; "trigger", `String (Compaction_trigger.to_label recovery.trigger)
        ; "trigger_detail", Compaction_trigger.to_detail_json recovery.trigger
        ; "ts_unix", `Float (Time_compat.now ())
        ])
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
    Log.Keeper.error
      "compaction SSE broadcast failed: %s"
      (Printexc.to_string exn);
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string MetricsSseFailures)
      ~labels:
        [ "kind", Keeper_metrics_sse_failure_kind.(to_label Compaction) ]
      ()
;;
