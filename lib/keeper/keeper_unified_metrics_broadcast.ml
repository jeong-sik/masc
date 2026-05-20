(** Keeper lifecycle SSE broadcast helpers — compaction and handoff events —
    extracted from keeper_unified_metrics.ml.

    Pure write-only side-effects (SSE broadcast + failure counter); no
    keeper lifecycle state owned here. *)

open Keeper_types
open Keeper_exec_context

let broadcast_lifecycle_events ~(name : string)
    ~(turn_generation : int)
    ~(compaction : Keeper_exec_context.compaction_event)
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
             ("before_tokens", `Int compaction.before_tokens);
             ("after_tokens", `Int compaction.after_tokens);
             ("saved_tokens", `Int compaction.saved_tokens);
             ( "trigger",
               match compaction.trigger with
               | Some trigger -> `String (Compaction_trigger.to_label trigger)
               | None ->
                   `String
                     (Keeper_exec_context.compaction_decision_to_string
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
         Prometheus.inc_counter Keeper_metrics.metric_keeper_metrics_sse_failures ~labels:[("kind", Keeper_metrics_sse_failure_kind.(to_label Compaction))] ());
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
          Prometheus.inc_counter Keeper_metrics.metric_keeper_metrics_sse_failures ~labels:[("kind", Keeper_metrics_sse_failure_kind.(to_label Handoff))] ())
  | _ -> ()

