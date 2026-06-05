(** Pending board-event collection for the keeper heartbeat loop.
    Extracted from [keeper_heartbeat_loop.ml] (godfile decomp).

    Single helper that, once the proactive-warmup phase has elapsed,
    queries [Keeper_world_observation.collect_board_events] for the
    keeper's pending board events and returns them paired with the
    current meta. Cancellation is re-raised; any other exception is
    logged + counted via the heartbeat-failure Otel_metric_store counter
    (phase="board_count_query") and treated as zero pending events. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile

let collect_keepalive_board_events
      ~(ctx : _ context)
      ~(meta_current : keeper_meta)
      ~(proactive_warmup_elapsed : bool)
  =
  if not proactive_warmup_elapsed
  then [], meta_current
  else (
    let pending_board_events =
      try
        let events, _new_count, _mention_count =
          Keeper_world_observation.collect_board_events
            ~base_path:ctx.config.base_path
            ~meta:meta_current
            ~continuity_summary:meta_current.continuity_summary
        in
        events
      with
      | Eio.Cancel.Cancelled _ as e -> raise e
      | exn ->
        Log.Keeper.warn "keepalive: board count query failed: %s" (Printexc.to_string exn);
        Otel_metric_store.inc_counter
          Keeper_metrics.(to_string HeartbeatFailures)
          ~labels:[ "keeper", meta_current.name; "phase", "board_count_query" ]
          ();
        []
    in
    pending_board_events, meta_current)
;;
