(** Otel_metric_store adapter for neutral Board metric hooks.

    Holds the only [variant -> Otel_metric_store label string] mappings for the
    typed label dimensions on {!Board_metrics_hooks.observer}.  Mappings are
    total (no [_ ->] wildcard), so adding a label variant is a compile
    obligation here.  The runtime-actor startup metric is intentionally a new
    contract; no alias for the deleted flusher-only metric is emitted. *)

(* surface label for masc_persistence_read_drops_total *)
let board_persist_surface_to_label :
  Board_metrics_hooks.board_persist_surface -> string = function
  | Board_post_meta_json -> "board_post_meta_json"

(* labels for masc_board_dispatch_runtime_actor_start_outcomes_total *)
let runtime_actor_to_label : Board_metrics_hooks.runtime_actor -> string =
  function
  | Flusher -> "flusher"
  | Routing_retry -> "routing_retry"

let runtime_actor_start_outcome_to_label :
  Board_metrics_hooks.runtime_actor_start_outcome -> string = function
  | Started -> "started"
  | Start_failed -> "start_failed"

(* reason label for masc_persistence_read_drops_total; reuses the
   SSOT wire mapping in Read_drop_reason (byte-identical to the old
   Safe_ops.persistence_read_drop_reason_* constants). *)
let read_drop_reason_to_label : Read_drop_reason.t -> string =
  Read_drop_reason.to_wire

let install () =
  Board_metrics_hooks.set_observer
    {
      observe_persist_lock_acquire_sec =
        (fun seconds ->
           Otel_metric_store.observe_histogram
             Otel_metric_store.metric_board_persist_lock_acquire_sec
             seconds);
      observe_persist_lock_held_sec =
        (fun seconds ->
           Otel_metric_store.observe_histogram
             Otel_metric_store.metric_board_persist_lock_held_sec
             seconds);
      inc_runtime_actor_start_outcome =
        (fun ~actor ~outcome ->
           Otel_metric_store.inc_counter
             Otel_metric_store.metric_board_dispatch_runtime_actor_start_outcomes
             ~labels:
               [ ("actor", runtime_actor_to_label actor)
               ; ("outcome", runtime_actor_start_outcome_to_label outcome)
               ]
             ());
      inc_persistence_read_drop =
        (fun ~surface ~reason ->
           Otel_metric_store.inc_counter
             Otel_metric_store.metric_persistence_read_drops
             ~labels:
               [ ("surface", board_persist_surface_to_label surface)
               ; ("reason", read_drop_reason_to_label reason)
               ]
             ());
    }
