(** Pending board-event collection for the keeper heartbeat loop.
    Extracted from [keeper_heartbeat_loop.ml] (godfile decomp).

    Single helper that, once the proactive-warmup phase has elapsed and the
    keeper is not paused, queries [Keeper_world_observation.collect_board_events]
    for the keeper's pending board events and returns them paired with the
    current meta. Cancellation is re-raised; any other exception is
    logged + counted via the heartbeat-failure Otel_metric_store counter
    (phase="board_count_query") and treated as zero pending events.

    Cursor-advance gating: [collect_board_events] advances and acks the
    per-keeper board cursor as a side effect, so it must only run when the
    keeper can actually act on the events this cycle. A paused keeper is not
    scheduled to run a turn (see [keeper_heartbeat_loop] scheduling), so
    collecting here would advance the cursor past posts the keeper never
    processed — dropping them with no requeue and no log at the keeper level.
    We therefore skip collection (returning no events and leaving the cursor
    untouched) until the keeper is both warmed up and unpaused, so the posts
    re-surface once the keeper resumes. This extends the existing warmup guard
    to the paused state. Runtime-backpressure and approval-pending gating are a
    follow-up: those verdicts are computed later in the scheduling stage, not at
    this collection site. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile

(* Pure gate: a keeper may consume board events — and thereby advance the
   per-keeper cursor past them — only once it has warmed up AND is not paused.
   [collect_board_events] advances + acks the cursor as a side effect, so
   collecting for a keeper that cannot act this cycle would step the cursor
   over posts it never processed, dropping them with no requeue. Backpressure
   and approval-pending verdicts are decided later in scheduling, not here. *)
let should_collect_board_events ~proactive_warmup_elapsed ~paused =
  proactive_warmup_elapsed && not paused
;;

let collect_keepalive_board_events
      ~(ctx : _ context)
      ~(meta_current : keeper_meta)
      ~(proactive_warmup_elapsed : bool)
  =
  if not
       (should_collect_board_events ~proactive_warmup_elapsed
          ~paused:meta_current.paused)
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
