(** Prometheus adapter for neutral Board metric hooks. *)

(* Canonical counter name for author-heuristic legacy post-kind migration.
   Named constant so the dashboard contract has a single source of truth
   (this file has no .mli, so the binding auto-exports). *)
let metric_legacy_migrate_post_kind = "masc_board_legacy_migrate_post_kind_total"

let install () =
  Board_metrics_hooks.set_observer
    {
      observe_persist_lock_acquire_sec =
        (fun seconds ->
           Prometheus.observe_histogram
             Prometheus.metric_board_persist_lock_acquire_sec
             seconds);
      observe_persist_lock_held_sec =
        (fun seconds ->
           Prometheus.observe_histogram
             Prometheus.metric_board_persist_lock_held_sec
             seconds);
      inc_dispatch_flusher_start_outcome =
        (fun ~outcome ->
           Prometheus.inc_counter
             Prometheus.metric_board_dispatch_flusher_start_outcomes
             ~labels:[ ("outcome", outcome) ]
             ());
      inc_vote_fixture_detected =
        (fun ~count ->
           if count > 0 then
             Prometheus.inc_counter
               "masc_board_vote_fixture_detected_total"
               ~delta:(Float.of_int count)
               ());
      inc_persistence_read_drop =
        (fun ~surface ~reason ->
           Prometheus.inc_counter
             Prometheus.metric_persistence_read_drops
             ~labels:[ ("surface", surface); ("reason", reason) ]
             ());
      inc_legacy_migrate_post_kind =
        (fun ~author ~automation_label ->
           Prometheus.inc_counter
             metric_legacy_migrate_post_kind
             ~labels:[ ("author", author); ("automation_label", automation_label) ]
             ());
    }
