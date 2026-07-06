(** Otel_metric_store adapter for neutral Board metric hooks.

    Holds the only [variant -> Otel_metric_store label string] mappings for the
    typed label dimensions on {!Board_metrics_hooks.observer}. The emitted
    strings are byte-identical to the values the pre-typed string hooks
    passed, so existing dashboards and alerts keyed on these labels keep
    working. The mappings are total (no [_ ->] wildcard) so adding a label
    variant is a compile obligation here. *)

(* surface label for masc_persistence_read_drops_total *)
let board_persist_surface_to_label :
  Board_metrics_hooks.board_persist_surface -> string = function
  | Board_post_meta_json -> "board_post_meta_json"
  | Board_post_kind -> "board_post_kind"
  | Board_post_mention_ids -> "board_post_mention_ids"
  | Board_comment_mention_ids -> "board_comment_mention_ids"
  | Board_sub_board_member_ids -> "board_sub_board_member_ids"

(* outcome label for masc_board_dispatch_flusher_start_outcomes_total *)
let flusher_outcome_to_label : Board_metrics_hooks.flusher_outcome -> string =
  function
  | Switch_finished -> "switch_finished"
  | Cas_exhausted -> "cas_exhausted"

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
      inc_dispatch_flusher_start_outcome =
        (fun ~outcome ->
           Otel_metric_store.inc_counter
             Otel_metric_store.metric_board_dispatch_flusher_start_outcomes
             ~labels:[ ("outcome", flusher_outcome_to_label outcome) ]
             ());
      inc_vote_fixture_detected =
        (fun ~count ->
           if count > 0 then
             Otel_metric_store.inc_counter
               "masc_board_vote_fixture_detected_total"
               ~delta:(Float.of_int count)
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
