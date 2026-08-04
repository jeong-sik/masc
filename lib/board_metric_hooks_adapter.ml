(** Otel_metric_store adapter for neutral Board metric hooks.

    Holds the only [variant -> Otel_metric_store label string] mappings for the
    typed label dimensions on {!Board_metrics_hooks.observer}. The emitted
    strings are byte-identical to the values the pre-typed string hooks
    passed, so existing dashboards and alerts keyed on these labels keep
    working. The mappings are total (no [_ ->] wildcard) so adding a label
    variant is a compile obligation here. *)

(* outcome label for masc_board_dispatch_flusher_start_outcomes_total *)
let flusher_outcome_to_label : Board_metrics_hooks.flusher_outcome -> string =
  function
  | Switch_finished -> "switch_finished"
  | Cas_exhausted -> "cas_exhausted"

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
      inc_dispatch_flusher_start_outcome =
        (fun ~outcome ->
           Otel_metric_store.inc_counter
             Otel_metric_store.metric_board_dispatch_flusher_start_outcomes
             ~labels:[ ("outcome", flusher_outcome_to_label outcome) ]
             ());
    }
