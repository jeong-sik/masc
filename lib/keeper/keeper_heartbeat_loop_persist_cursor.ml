(** Message cursor persistence for keeper heartbeat, extracted from
    [keeper_heartbeat_loop.ml] (godfile decomp).

    [persist_message_cursor_updates ~config meta updates] folds the
    requested message_cursor updates into the keeper meta and writes
    them back via [write_meta_with_merge]. The merge callback re-
    applies the same updates against the *latest* on-disk meta to
    avoid stealing concurrent heartbeat writes (cf. #9733).

    On successful write, re-reads the meta to return the final
    canonical version (which may have additional concurrent merges).
    Read failures after a successful write degrade gracefully:

    - [Ok None] (race: meta deleted between write and read) →
      [metric_keeper_meta_read_failures] (site=[cursor_update_none_after_write])
      + WARN log + return [{ updated with meta_version = v + 1 }]
    - [Error e] → same metric (site=[cursor_update_read_after_write])
      + WARN log + same fallback

    Write failures (CAS race or disk error) tick
    [metric_keeper_write_meta_failures] (phase=[cursor_update]) +
    WARN log + return the in-memory [updated] meta without bumping
    [meta_version].

    Pure helper move (no callback injection). All references reach
    external modules — no parent-local dependencies. *)

open Keeper_types

let persist_message_cursor_updates ~config (meta : keeper_meta) updates =
  let updated = Keeper_world_observation.apply_message_cursor_updates meta updates in
  if updates = []
  then updated
  else (
    let merge ~latest ~caller:_ =
      Keeper_world_observation.apply_message_cursor_updates latest updates
    in
    match write_meta_with_merge ~merge config updated with
    | Ok () ->
      (match read_meta config updated.name with
       | Ok (Some latest) -> latest
       | Ok None ->
         Prometheus.inc_counter
           Keeper_metrics.(to_string MetaReadFailures)
           ~labels:[ "keeper", updated.name; "site", "cursor_update_none_after_write" ]
           ();
         Log.Keeper.warn
           "read_meta returned None after message cursor update write for %s"
           updated.name;
         { updated with meta_version = updated.meta_version + 1 }
       | Error e ->
         Prometheus.inc_counter
           Keeper_metrics.(to_string MetaReadFailures)
           ~labels:[ "keeper", updated.name; "site", "cursor_update_read_after_write" ]
           ();
         Log.Keeper.warn
           "read_meta failed after message cursor update write for %s: %s"
           updated.name
           e;
         { updated with meta_version = updated.meta_version + 1 })
    | Error e ->
      Prometheus.inc_counter
        Keeper_metrics.(to_string WriteMetaFailures)
        ~labels:[ "keeper", updated.name; "phase", "cursor_update" ]
        ();
      Log.Keeper.warn "write_meta failed (message cursor update): %s" e;
      updated)
;;
