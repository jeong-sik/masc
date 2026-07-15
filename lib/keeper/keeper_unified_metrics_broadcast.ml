(** Keeper lifecycle SSE broadcast helpers — compaction and handoff events —
    extracted from keeper_unified_metrics.ml.

    Pure write-only side-effects (SSE broadcast + failure counter); no
    keeper lifecycle state owned here. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile
open Keeper_context_runtime

let broadcast_lifecycle_events ~(name : string)
    ~(turn_generation : int)
    ~(compaction : Keeper_context_runtime.compaction_event)
    ~(handoff_json : Yojson.Safe.t option) : unit =
  let now_ts = Time_compat.now () in
  (if compaction.applied then
     try
       Sse.broadcast
         (`Assoc
           [
             ("type", `String "keeper_compaction");
             ("name", `String name);
             ("generation", `Int turn_generation);
             ( "before_checkpoint_bytes"
             , `Int compaction.before_checkpoint_bytes );
             ( "after_checkpoint_bytes"
             , `Int compaction.after_checkpoint_bytes );
             ( "saved_checkpoint_bytes"
             , `Int compaction.saved_checkpoint_bytes );
             ( "trigger",
               match compaction.trigger with
               | Some trigger -> `String (Compaction_trigger.to_label trigger)
               | None ->
                   `String
                     (Keeper_context_runtime.compaction_decision_to_string
                        compaction.decision) );
             ( "trigger_detail",
               match compaction.trigger with
               | Some trigger -> Compaction_trigger.to_detail_json trigger
               | None -> `Null );
             ("ts_unix", `Float now_ts);
           ])
     with
     | Eio.Cancel.Cancelled _ as e -> raise e
     | exn ->
         Log.Keeper.error "compaction SSE broadcast failed: %s"
           (Printexc.to_string exn);
         Otel_metric_store.inc_counter Keeper_metrics.(to_string MetricsSseFailures) ~labels:[("kind", Keeper_metrics_sse_failure_kind.(to_label Compaction))] ());
  match handoff_json with
  | Some ((`Assoc _ as handoff)) ->
      let from_generation =
        Safe_ops.json_int ~default:turn_generation "from_generation" handoff
      in
      let to_generation =
        Safe_ops.json_int ~default:(from_generation + 1) "to_generation" handoff
      in
      let to_model = Safe_ops.json_string ~default:"" "to_model" handoff in
      (try
         Sse.broadcast
           (`Assoc
             [
               ("type", `String "keeper_handoff");
               ("name", `String name);
               ("from_generation", `Int from_generation);
               ("to_generation", `Int to_generation);
               ("from_model", `Null);
               ("to_model",
                if String.trim to_model = "" then `Null else `String to_model);
               ("ts_unix", `Float now_ts);
             ])
       with
      | Eio.Cancel.Cancelled _ as e -> raise e
      | exn ->
          Log.Keeper.error "handoff SSE broadcast failed: %s"
            (Printexc.to_string exn);
          Otel_metric_store.inc_counter Keeper_metrics.(to_string MetricsSseFailures) ~labels:[("kind", Keeper_metrics_sse_failure_kind.(to_label Handoff))] ())
  | _ -> ()
