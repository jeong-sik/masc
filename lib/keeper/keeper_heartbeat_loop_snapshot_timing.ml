(** Heartbeat snapshot persistence + stage-timing ring-buffer record,
    extracted from [keeper_heartbeat_loop.ml] (godfile decomp).

    Two side-effect helpers consumed by [run_heartbeat_loop]:

    - [maybe_write_heartbeat_snapshot] — TTL-gated wrapper around
      [Keeper_heartbeat_snapshot.write_heartbeat_snapshot]. Writes the
      snapshot iff the configured [~snapshot_interval_sec] has elapsed
      since [!last_snapshot_ts]. Write failures degrade gracefully:
      cancellation re-raises, other [exn] increment
      [metric_keeper_snapshot_write_failures] and log ERROR.
      [last_snapshot_ts] is bumped to [now_ts] even on failure to
      avoid retry storms.

    - [record_keepalive_stage_timing] — populates one ring-buffer slot
      of stage-timing measurements (presence/snapshot/board/turn/
      recurring in ms) and advances the cursor. [timing_filled] caps
      at [ring_sz].

    Pure helpers (no callback injection). All references reach
    external modules (Keeper_heartbeat_snapshot, Keeper_keepalive_signal,
    Eio, Otel_metric_store, Keeper_metrics, Log) directly. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile

let maybe_write_heartbeat_snapshot
      ~(ctx : _ context)
      ~(meta_current : keeper_meta)
      ~(now_ts : float)
      ~(last_snapshot_ts : float ref)
      ~(snapshot_interval_sec : int)
      ~(timing_ring : Keeper_keepalive_signal.stage_timing array)
      ~(timing_filled : int)
  : unit
  =
  if now_ts -. !last_snapshot_ts >= float_of_int snapshot_interval_sec
  then (
    (try
       Keeper_heartbeat_snapshot.write_heartbeat_snapshot
         ~ctx
         ~meta_current
         ~now_ts
         ~timing_ring
         ~timing_filled
     with
     | Eio.Cancel.Cancelled _ as e -> raise e
     | exn ->
       Otel_metric_store.inc_counter
         Keeper_metrics.(to_string SnapshotWriteFailures)
         ~labels:[ "keeper", meta_current.name ]
         ();
       Log.Keeper.error "heartbeat snapshot write failed: %s" (Printexc.to_string exn));
    last_snapshot_ts := now_ts)
;;

let record_keepalive_stage_timing
      ~(timing_ring : Keeper_keepalive_signal.stage_timing array)
      ~(timing_cursor : int ref)
      ~(timing_filled : int ref)
      ~(ring_sz : int)
      ~(t_presence_start : float)
      ~(t_presence_end : float)
      ~(t_snapshot_start : float)
      ~(t_snapshot_end : float)
      ~(t_board_start : float)
      ~(t_board_end : float)
      ~(t_turn_start : float)
      ~(t_turn_end : float)
      ~(t_recurring_start : float)
      ~(t_recurring_end : float)
  : unit
  =
  let timing : Keeper_keepalive_signal.stage_timing =
    { Keeper_keepalive_signal.presence_ms =
        (t_presence_end -. t_presence_start) *. 1000.0
    ; snapshot_ms = (t_snapshot_end -. t_snapshot_start) *. 1000.0
    ; board_ms = (t_board_end -. t_board_start) *. 1000.0
    ; turn_ms = (t_turn_end -. t_turn_start) *. 1000.0
    ; recurring_ms = (t_recurring_end -. t_recurring_start) *. 1000.0
    }
  in
  timing_ring.(!timing_cursor) <- timing;
  timing_cursor := (!timing_cursor + 1) mod ring_sz;
  if !timing_filled < ring_sz then incr timing_filled
;;
