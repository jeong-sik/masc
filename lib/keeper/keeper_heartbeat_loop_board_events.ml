(** Pending board-event collection for the keeper heartbeat loop.
    Extracted from [keeper_heartbeat_loop.ml] (godfile decomp).

    Single helper that, once the cursor-advance gate admits the cycle, queries
    [Keeper_world_observation.collect_board_events] for the keeper's pending
    board events and returns them paired with the current meta. Cancellation is
    re-raised; any other exception is logged, counted via the heartbeat-failure
    Otel_metric_store counter (phase="board_count_query"), recorded in
    [keeper_board_event_collection] health, and treated as zero pending events
    for this cycle.

    Cursor-advance gating: [collect_board_events] advances and acks the
    per-keeper board cursor as a side effect, so it must only run when the
    keeper can actually act on the events this cycle. If a later admission gate
    will prevent a turn, collecting here would advance the cursor past posts the
    keeper never processed — dropping them with no requeue and no log at the
    keeper level. We therefore skip collection (returning no events and leaving
    the cursor untouched) until the keeper is warmed up, unpaused, free of
    pending HITL approval, healthy enough to run, and not in provider cooldown,
    so the posts re-surface once the blocker clears. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile

type collection_failure =
  { failed_at : float
  ; message : string
  }

type collection_failure_snapshot =
  { snapshot_keeper_name : string
  ; snapshot_failed_at : float
  ; snapshot_message : string
  }

let collection_failures : (string, collection_failure) Hashtbl.t = Hashtbl.create 16

(* Module-level observability table: Stdlib.Mutex because reads can come from
   health/test code outside an Eio context and the critical sections never
   yield. *)
let collection_failures_mu = Stdlib.Mutex.create ()

let collection_failure_key ~base_path ~keeper_name =
  Keeper_registry_types.registry_key ~base_path keeper_name
;;

let record_collection_failure ~base_path ~keeper_name ~message =
  let key = collection_failure_key ~base_path ~keeper_name in
  (* NDT-OK: failure timestamps are health telemetry at the collection boundary;
     they do not influence keeper admission or replay decisions. *)
  let failed_at = Unix.gettimeofday () in
  Stdlib.Mutex.protect collection_failures_mu (fun () ->
    Hashtbl.replace collection_failures key { failed_at; message })
;;

let clear_collection_failure ~base_path ~keeper_name =
  let key = collection_failure_key ~base_path ~keeper_name in
  Stdlib.Mutex.protect collection_failures_mu (fun () ->
    Hashtbl.remove collection_failures key)
;;

let live_failure_keeper_names ~base_path =
  let base_path = Keeper_registry_types.canonical_base_path_exn base_path in
  Stdlib.Mutex.protect collection_failures_mu (fun () ->
    Hashtbl.fold
      (fun key _failure acc ->
        match Keeper_registry_types.registry_key_parts key with
        | Ok (stored_base_path, keeper_name) when String.equal stored_base_path base_path ->
          keeper_name :: acc
        | Ok _ | Error _ -> acc)
      collection_failures
      [])
;;

let snapshot_for ~base_path ~keeper_name =
  let key = collection_failure_key ~base_path ~keeper_name in
  Stdlib.Mutex.protect collection_failures_mu (fun () ->
    match Hashtbl.find_opt collection_failures key with
    | None -> None
    | Some failure ->
      Some
        { snapshot_keeper_name = keeper_name
        ; snapshot_failed_at = failure.failed_at
        ; snapshot_message = failure.message
        })
;;

let failure_snapshot_to_json ~now snapshot =
  `Assoc
    [ "keeper_name", `String snapshot.snapshot_keeper_name
    ; "last_error_at_unix", `Float snapshot.snapshot_failed_at
    ; ( "last_error_age_sec"
      , `Int (int_of_float (max 0.0 (now -. snapshot.snapshot_failed_at))) )
    ; "last_error_message", `String snapshot.snapshot_message
    ]
;;

let fleet_health_json ~base_path ~keeper_names =
  let keeper_names =
    List.sort_uniq
      String.compare
      (keeper_names @ live_failure_keeper_names ~base_path)
  in
  let failures =
    List.filter_map (fun keeper_name -> snapshot_for ~base_path ~keeper_name) keeper_names
  in
  let status_reasons =
    if failures = [] then [] else [ "board_event_collection_failure" ]
  in
  let operator_action_required = status_reasons <> [] in
  (* NDT-OK: fleet health renders wall-clock age at the HTTP observation
     boundary; the timestamp is not used for keeper control flow. *)
  let now = Unix.gettimeofday () in
  `Assoc
    [ "schema", `String "masc.keeper_board_event_collection.v1"
    ; "status", `String (if operator_action_required then "degraded" else "ok")
    ; "operator_action_required", `Bool operator_action_required
    ; "status_reasons", `List (List.map (fun value -> `String value) status_reasons)
    ; "keeper_count", `Int (List.length keeper_names)
    ; "keeper_names", `List (List.map (fun value -> `String value) keeper_names)
    ; "failed_keeper_count", `Int (List.length failures)
    ; "failure_count", `Int (List.length failures)
    ; "failures", `List (List.map (failure_snapshot_to_json ~now) failures)
    ]
;;

(* Pure gate: a keeper may consume board events — and thereby advance the
   per-keeper cursor past them — only once no known turn-admission blocker is
   present. [collect_board_events] advances + acks the cursor as a side effect,
   so collecting for a keeper that cannot act this cycle would step the cursor
   over posts it never processed, dropping them with no requeue. *)
let should_collect_board_events
      ~proactive_warmup_elapsed
      ~paused
      ~approval_pending
      ~keeper_backpressured
      ~provider_cooldown_pending
  =
  proactive_warmup_elapsed && not paused
  && not approval_pending
  && not keeper_backpressured
  && not provider_cooldown_pending
;;

let collect_keepalive_board_events
      ~(ctx : _ context)
      ~(meta_current : keeper_meta)
      ~(proactive_warmup_elapsed : bool)
      ~(approval_pending : bool)
      ~(keeper_backpressured : bool)
      ~(provider_cooldown_pending : bool)
  =
  if not
       (should_collect_board_events
          ~proactive_warmup_elapsed
          ~paused:meta_current.paused
          ~approval_pending
          ~keeper_backpressured
          ~provider_cooldown_pending)
  then [], meta_current
  else (
    let pending_board_events =
      try
        let events, _new_count, _mention_count =
          Keeper_world_observation.collect_board_events
            ~base_path:ctx.config.base_path
            ~meta:meta_current
        in
        clear_collection_failure
          ~base_path:ctx.config.base_path
          ~keeper_name:meta_current.name;
        events
      with
      | Eio.Cancel.Cancelled _ as e -> raise e
      | exn ->
        let message = Printexc.to_string exn in
        record_collection_failure
          ~base_path:ctx.config.base_path
          ~keeper_name:meta_current.name
          ~message;
        Log.Keeper.warn "keepalive: board count query failed: %s" message;
        Otel_metric_store.inc_counter
          Keeper_metrics.(to_string HeartbeatFailures)
          ~labels:[ "keeper", meta_current.name; "phase", "board_count_query" ]
          ();
        []
    in
    pending_board_events, meta_current)
;;

module For_testing = struct
  let reset () =
    Stdlib.Mutex.protect collection_failures_mu (fun () ->
      Hashtbl.reset collection_failures)
  ;;

  let record_collection_failure = record_collection_failure
  let clear_collection_failure = clear_collection_failure
end
