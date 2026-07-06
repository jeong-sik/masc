(** Per-keeper event-queue access.

    Extracted from keeper_registry.ml (lines 1854-1900) as part of the
    godfile decomp campaign. Each [registry_entry] carries its own
    [event_queue : Keeper_event_queue.t Atomic.t] — these wrappers do
    CAS on that per-entry atomic after locating the entry via the
    central registry's public [get]. No coupling to the central
    Atomic state primitive. CAS-successful mutations are mirrored to
    [Keeper_event_queue_persistence] for restart replay. *)

open Keeper_registry_types

let rec queue_contains queue stimulus =
  match Keeper_event_queue.dequeue queue with
  | None -> false
  | Some (head, rest) ->
    Keeper_event_queue.stimulus_identity_equal head stimulus
    || queue_contains rest stimulus
;;

let enqueue_if_missing queue stimulus =
  if queue_contains queue stimulus then queue else Keeper_event_queue.enqueue queue stimulus
;;

let enqueue_if_missing_with_outcome queue stimulus =
  if queue_contains queue stimulus
  then queue, `Duplicate
  else Keeper_event_queue.enqueue queue stimulus, `Queued
;;

let requeue_missing_front queue stimuli =
  let missing =
    List.filter (fun stimulus -> not (queue_contains queue stimulus)) stimuli
  in
  Keeper_event_queue.prepend_list missing queue
;;

let source_label (stimulus : Keeper_event_queue.stimulus) =
  Keeper_event_queue.payload_kind_label stimulus.payload
;;

type enqueue_outcome =
  | Enqueue_queued
  | Enqueue_persisted
  | Enqueue_duplicate
  | Enqueue_persist_failed

type enqueue_success =
  [ `Queued
  | `Persisted
  | `Duplicate
  ]

type consume_outcome =
  | Consume_completed
  | Consume_requeued
  | Consume_lease_failed
  | Consume_pending_persist_failed
  | Consume_requeue_failed

let enqueue_outcome_label = function
  | Enqueue_queued -> "queued"
  | Enqueue_persisted -> "persisted"
  | Enqueue_duplicate -> "duplicate"
  | Enqueue_persist_failed -> "persist_failed"
;;

let consume_outcome_label = function
  | Consume_completed -> "completed"
  | Consume_requeued -> "requeued"
  | Consume_lease_failed -> "lease_failed"
  | Consume_pending_persist_failed -> "pending_persist_failed"
  | Consume_requeue_failed -> "requeue_failed"
;;

let metric_labels ~keeper_name stimulus ~outcome =
  [ "keeper", keeper_name; "source", source_label stimulus; "outcome", outcome ]
;;

let delay_metric_labels ~keeper_name stimulus =
  [ "keeper", keeper_name; "source", source_label stimulus ]
;;

let record_enqueue_metric ~keeper_name stimulus outcome =
  Otel_metric_store.inc_counter
    Otel_metric_store.metric_keeper_wake_enqueue_total
    ~labels:(metric_labels ~keeper_name stimulus ~outcome:(enqueue_outcome_label outcome))
    ()
;;

let record_consume_metric ~keeper_name stimulus outcome =
  Otel_metric_store.inc_counter
    Otel_metric_store.metric_keeper_wake_consume_total
    ~labels:(metric_labels ~keeper_name stimulus ~outcome:(consume_outcome_label outcome))
    ()
;;

let record_consume_metrics ~keeper_name stimuli outcome =
  List.iter (fun stimulus -> record_consume_metric ~keeper_name stimulus outcome) stimuli
;;

let record_completed_delay_metric ~keeper_name (stimulus : Keeper_event_queue.stimulus) =
  let delay_seconds = max 0.0 (Time_compat.now () -. stimulus.arrived_at) in
  Otel_metric_store.observe_histogram
    Otel_metric_store.metric_keeper_wake_delay_seconds
    ~labels:(delay_metric_labels ~keeper_name stimulus)
    delay_seconds
;;

let record_reaction_ledger_stimulus ~base_path ~keeper_name stimulus =
  match
    Keeper_reaction_ledger.record_event_queue_stimulus_result
      ~base_path
      ~keeper_name
      stimulus
  with
  | Ok () -> ()
  | Error error ->
    Log.Keeper.warn
      "registry: reaction-ledger stimulus append failed name=%s source=%s post_id=%s: %s"
      keeper_name
      (source_label stimulus)
      stimulus.Keeper_event_queue.post_id
      error
;;

let record_reaction_ledger_consumed ~base_path ~keeper_name stimulus =
  match
    Keeper_reaction_ledger.record_event_queue_reaction_result
      ~base_path
      ~keeper_name
      ~reaction_kind:Keeper_reaction_ledger.Stimulus_consumed
      stimulus
  with
  | Ok () -> ()
  | Error error ->
    Log.Keeper.warn
      "registry: reaction-ledger consumed append failed name=%s source=%s post_id=%s: %s"
      keeper_name
      (source_label stimulus)
      stimulus.Keeper_event_queue.post_id
      error
;;

let replay_snapshot_contains queue stimulus = queue_contains queue stimulus

let acknowledged_stimuli_from_replay_snapshot ~base_path ~keeper_name stimuli =
  let replayable =
    Keeper_event_queue_persistence.load ~base_path ~keeper_name
  in
  stimuli
  |> List.filter (replay_snapshot_contains replayable)
  |> Keeper_event_queue.uniq_stimuli
;;

let persist_live_queue_result ~base_path (entry : Keeper_registry.registry_entry) name =
  Keeper_event_queue_persistence.persist_snapshot_result
    ~base_path
    ~keeper_name:name
    (fun () -> Atomic.get entry.event_queue)
;;

let persist_live_queue ~base_path entry name =
  match persist_live_queue_result ~base_path entry name with
  | Ok () -> ()
  | Error msg -> Log.Keeper.warn "registry: event queue persist failed name=%s: %s" name msg
;;

let enqueue_result ~base_path name stimulus =
  match Keeper_registry.get ~base_path name with
  | None ->
    Log.Keeper.warn
      "registry: enqueue_event name=%s base_path=%s: keeper not registered; persisting stimulus for replay"
      name
      base_path;
    let persisted_outcome = ref `Duplicate in
    let durable_result =
      match
        Keeper_event_queue_persistence.update_result
          ~base_path
          ~keeper_name:name
          (fun cur ->
             let next, outcome = enqueue_if_missing_with_outcome cur stimulus in
             persisted_outcome := outcome;
             next)
      with
      | Error msg ->
        Log.Keeper.warn "registry: enqueue_event persist failed name=%s: %s" name msg;
        record_enqueue_metric ~keeper_name:name stimulus Enqueue_persist_failed;
        Error msg
      | Ok () ->
        (match !persisted_outcome with
         | `Queued ->
           record_reaction_ledger_stimulus ~base_path ~keeper_name:name stimulus;
           record_enqueue_metric ~keeper_name:name stimulus Enqueue_persisted;
           Ok `Persisted
         | `Duplicate ->
           record_enqueue_metric ~keeper_name:name stimulus Enqueue_duplicate;
           Ok `Duplicate)
    in
    (match Keeper_registry.get ~base_path name with
     | None -> ()
     | Some entry ->
       let rec loop () =
         let cur = Atomic.get entry.event_queue in
         let next = enqueue_if_missing cur stimulus in
         if next = cur
         then ()
         else if Atomic.compare_and_set entry.event_queue cur next
         then persist_live_queue ~base_path entry name
         else loop ()
       in
       loop ());
    durable_result
  | Some entry ->
    let rec loop () =
      let cur = Atomic.get entry.event_queue in
      let next, outcome = enqueue_if_missing_with_outcome cur stimulus in
      match outcome with
      | `Duplicate ->
        (match persist_live_queue_result ~base_path entry name with
         | Error msg ->
           Log.Keeper.warn "registry: enqueue_event persist failed name=%s: %s" name msg;
           record_enqueue_metric ~keeper_name:name stimulus Enqueue_persist_failed;
           Error msg
         | Ok () ->
           record_enqueue_metric ~keeper_name:name stimulus Enqueue_duplicate;
           Ok `Duplicate)
      | `Queued ->
        if Atomic.compare_and_set entry.event_queue cur next
        then (
          match persist_live_queue_result ~base_path entry name with
          | Error msg ->
            Log.Keeper.warn "registry: enqueue_event persist failed name=%s: %s" name msg;
            record_enqueue_metric ~keeper_name:name stimulus Enqueue_persist_failed;
            Error msg
          | Ok () ->
            record_reaction_ledger_stimulus ~base_path ~keeper_name:name stimulus;
            record_enqueue_metric ~keeper_name:name stimulus Enqueue_queued;
            Ok `Queued)
        else loop ()
    in
    loop ()
;;

let enqueue ~base_path name stimulus =
  match enqueue_result ~base_path name stimulus with
  | Ok _ -> ()
  | Error msg ->
    Log.Keeper.warn
      "registry: enqueue compatibility wrapper suppressed delivery failure name=%s: %s"
      name
      msg
;;

let record_requeue_failed ~keeper_name stimuli msg =
  Log.Keeper.warn "registry: requeue_front failed name=%s: %s" keeper_name msg;
  record_consume_metrics ~keeper_name stimuli Consume_requeue_failed;
  Error msg
;;

let requeue_front_result ~base_path name stimuli =
  match stimuli with
  | [] -> Ok ()
  | _ ->
    (match Keeper_registry.get ~base_path name with
     | None ->
       (match
          Keeper_event_queue_persistence.update_result
            ~base_path
            ~keeper_name:name
            (fun cur -> requeue_missing_front cur stimuli)
        with
        | Error msg -> record_requeue_failed ~keeper_name:name stimuli msg
        | Ok () ->
          (match
             Keeper_event_queue_persistence.ack_inflight_result
               ~base_path
               ~keeper_name:name
               stimuli
           with
           | Error msg -> record_requeue_failed ~keeper_name:name stimuli msg
           | Ok () ->
             record_consume_metrics ~keeper_name:name stimuli Consume_requeued;
             Ok ()))
     | Some entry ->
       let rec loop () =
         let cur = Atomic.get entry.event_queue in
         let next = requeue_missing_front cur stimuli in
         if next = cur
         then (
           match
             Keeper_event_queue_persistence.ack_inflight_result
               ~base_path
               ~keeper_name:name
               stimuli
           with
           | Error msg -> record_requeue_failed ~keeper_name:name stimuli msg
           | Ok () ->
             record_consume_metrics ~keeper_name:name stimuli Consume_requeued;
             Ok ())
         else if Atomic.compare_and_set entry.event_queue cur next
         then (
           match persist_live_queue_result ~base_path entry name with
           | Error msg -> record_requeue_failed ~keeper_name:name stimuli msg
           | Ok () ->
             (match
                Keeper_event_queue_persistence.ack_inflight_result
                  ~base_path
                  ~keeper_name:name
                  stimuli
              with
              | Error msg -> record_requeue_failed ~keeper_name:name stimuli msg
              | Ok () ->
                record_consume_metrics ~keeper_name:name stimuli Consume_requeued;
                Ok ()))
         else loop ()
       in
       loop ())
;;

let requeue_front ~base_path name stimuli =
  match requeue_front_result ~base_path name stimuli with
  | Ok () -> ()
  | Error msg ->
    Log.Keeper.warn
      "registry: requeue_front compatibility wrapper suppressed delivery failure name=%s count=%d: %s"
      name
      (List.length stimuli)
      msg
;;

let ack_consumed ~base_path name stimuli =
  let acknowledged_stimuli =
    acknowledged_stimuli_from_replay_snapshot ~base_path ~keeper_name:name stimuli
  in
  match
    Keeper_event_queue_persistence.ack_consumed ~base_path ~keeper_name:name stimuli
  with
  | Ok () ->
    List.iter
      (fun stimulus ->
         record_reaction_ledger_consumed ~base_path ~keeper_name:name stimulus;
         record_consume_metric ~keeper_name:name stimulus Consume_completed;
         record_completed_delay_metric ~keeper_name:name stimulus)
      acknowledged_stimuli
  | Error msg ->
    Log.Keeper.warn "registry: ack_consumed failed name=%s: %s" name msg
;;

let drop_by_post_id ~base_path name ~post_id =
  let remove_live (entry : Keeper_registry.registry_entry) =
    let rec loop () =
      let cur = Atomic.get entry.event_queue in
      let removed, next = Keeper_event_queue.remove_by_post_id post_id cur in
      if removed = []
      then Ok removed
      else if Atomic.compare_and_set entry.event_queue cur next
      then (
        match persist_live_queue_result ~base_path entry name with
        | Ok () -> Ok removed
        | Error msg -> Error msg)
      else loop ()
    in
    loop ()
  in
  match
    Keeper_event_queue_persistence.drop_by_post_id
      ~base_path
      ~keeper_name:name
      ~post_id
  with
  | Error msg ->
    Log.Keeper.warn
      "registry: drop_by_post_id failed name=%s post_id=%s: %s"
      name
      post_id
      msg;
    Error msg
  | Ok persisted_removed ->
    (match Keeper_registry.get ~base_path name with
     | None -> Ok (Keeper_event_queue.uniq_stimuli persisted_removed)
     | Some entry ->
       (match remove_live entry with
        | Error msg ->
          Log.Keeper.warn
            "registry: drop_by_post_id live persist failed name=%s post_id=%s: %s"
            name
            post_id
            msg;
          Error msg
        | Ok live_removed ->
          Ok (Keeper_event_queue.uniq_stimuli (live_removed @ persisted_removed))))
;;

let snapshot ~base_path name =
  match Keeper_registry.get ~base_path name with
  | None -> Keeper_event_queue_persistence.load ~base_path ~keeper_name:name
  | Some entry -> Atomic.get entry.event_queue
;;

let dequeue_result ~base_path name =
  match Keeper_registry.get ~base_path name with
  | None -> Ok None
  | Some entry ->
    let rec loop () =
      let cur = Atomic.get entry.event_queue in
      match Keeper_event_queue.dequeue cur with
      | None -> Ok None
      | Some (stim, rest) ->
        (match
           Keeper_event_queue_persistence.record_inflight_result
             ~base_path
             ~keeper_name:name
             [ stim ]
         with
         | Error msg ->
           Log.Keeper.warn "registry: dequeue lease failed name=%s: %s" name msg;
           record_consume_metric ~keeper_name:name stim Consume_lease_failed;
           Error msg
         | Ok () ->
           if Atomic.compare_and_set entry.event_queue cur rest
           then (
             match persist_live_queue_result ~base_path entry name with
             | Ok () -> Ok (Some stim)
             | Error msg ->
               Log.Keeper.warn
                 "registry: dequeue pending persist failed name=%s: %s"
                 name
                 msg;
               record_consume_metric
                 ~keeper_name:name
                 stim
                 Consume_pending_persist_failed;
               Error msg)
           else loop ())
    in
    loop ()
;;

let dequeue ~base_path name =
  match dequeue_result ~base_path name with
  | Ok value -> value
  | Error msg ->
    Log.Keeper.warn
      "registry: dequeue compatibility wrapper suppressed delivery failure name=%s: %s"
      name
      msg;
    None
;;

let drain_board_result ?window_sec ~base_path name =
  match Keeper_registry.get ~base_path name with
  | None -> Ok []
  | Some entry ->
    let rec loop () =
      let cur = Atomic.get entry.event_queue in
      let board, rest = Keeper_event_queue.drain_board_window ?window_sec cur in
      match board with
      | [] -> Ok []
      | _ ->
        (match
           Keeper_event_queue_persistence.record_inflight_result
             ~base_path
             ~keeper_name:name
             board
         with
         | Error msg ->
           Log.Keeper.warn "registry: drain_board lease failed name=%s: %s" name msg;
           record_consume_metrics ~keeper_name:name board Consume_lease_failed;
           Error msg
         | Ok () ->
           if Atomic.compare_and_set entry.event_queue cur rest
           then (
             match persist_live_queue_result ~base_path entry name with
             | Ok () -> Ok board
             | Error msg ->
               Log.Keeper.warn
                 "registry: drain_board pending persist failed name=%s: %s"
                 name
                 msg;
               record_consume_metrics
                 ~keeper_name:name
                 board
                 Consume_pending_persist_failed;
               Error msg)
           else loop ())
    in
    loop ()
;;

let drain_board ?window_sec ~base_path name =
  match drain_board_result ?window_sec ~base_path name with
  | Ok value -> value
  | Error msg ->
    Log.Keeper.warn
      "registry: drain_board compatibility wrapper suppressed delivery failure name=%s: %s"
      name
      msg;
    []
;;
