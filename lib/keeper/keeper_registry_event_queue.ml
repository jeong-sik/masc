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

let rec stimulus_with_post_id queue post_id =
  match Keeper_event_queue.dequeue queue with
  | None -> None
  | Some (stimulus, rest) ->
    if String.equal stimulus.post_id post_id
    then Some stimulus
    else stimulus_with_post_id rest post_id
;;

let enqueue_external_decision queue stimulus =
  match stimulus_with_post_id queue stimulus.Keeper_event_queue.post_id with
  | None -> Ok (Keeper_event_queue.enqueue queue stimulus)
  | Some committed
    when Keeper_event_queue.stimulus_identity_equal committed stimulus ->
    Ok queue
  | Some _ ->
    Error
      (Printf.sprintf
         "conflicting durable stimulus already exists for post_id=%s"
         stimulus.post_id)
;;

let requeue_missing_front queue stimuli =
  let missing =
    List.filter (fun stimulus -> not (queue_contains queue stimulus)) stimuli
  in
  Keeper_event_queue.prepend_list missing queue
;;

let persist_live_queue ~base_path (entry : Keeper_registry.registry_entry) name =
  Keeper_event_queue_persistence.persist_snapshot
    ~base_path
    ~keeper_name:name
    (fun () -> Atomic.get entry.event_queue)
;;

let enqueue_live_if_missing (entry : Keeper_registry.registry_entry) stimulus =
  let rec loop () =
    let cur = Atomic.get entry.event_queue in
    let next = enqueue_if_missing cur stimulus in
    if next = cur
    then ()
    else if Atomic.compare_and_set entry.event_queue cur next
    then ()
    else loop ()
  in
  loop ()
;;

let enqueue ~base_path name stimulus =
  match Keeper_registry.get ~base_path name with
  | None ->
    Log.Keeper.warn
      "registry: enqueue_event name=%s base_path=%s: keeper not registered; persisting stimulus for replay"
      name
      base_path;
    Keeper_event_queue_persistence.update
      ~base_path
      ~keeper_name:name
      (fun cur -> enqueue_if_missing cur stimulus);
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
       loop ())
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
    loop ()
;;

let enqueue_durable_result ~base_path name stimulus =
  (* Commit the identity-deduplicated durable row before exposing a successful
     delivery result. This path is intentionally separate from [enqueue]: most
     stimuli already have an upstream replay source, while HITL resolution is
     the sole carrier of an operator decision and must fail closed. *)
  let after_commit =
    match Keeper_registry.get ~base_path name with
    | None -> fun () -> ()
    | Some entry -> fun () -> enqueue_live_if_missing entry stimulus
  in
  Keeper_event_queue_persistence.update_checked_result
    ~base_path
    ~keeper_name:name
    ~after_commit
    (fun queue -> enqueue_external_decision queue stimulus)
;;

let enqueue_hitl_resolution_durable_result
    ~base_path
    ~keeper_name
    ~approval_id
    ~decision
    ~channel
  =
  let resolution : Keeper_event_queue.hitl_resolution =
    { approval_id; decision; channel }
  in
  let stimulus : Keeper_event_queue.stimulus =
    { post_id = Keeper_event_queue.hitl_resolution_post_id resolution
    ; urgency = Keeper_event_queue.Immediate
    ; arrived_at = Time_compat.now ()
    ; payload = Keeper_event_queue.Hitl_resolved resolution
    }
  in
  enqueue_durable_result ~base_path keeper_name stimulus
;;

let requeue_front ~base_path name stimuli =
  match stimuli with
  | [] -> ()
  | _ ->
    (match Keeper_registry.get ~base_path name with
     | None ->
       Keeper_event_queue_persistence.update
         ~base_path
         ~keeper_name:name
         (fun cur -> requeue_missing_front cur stimuli);
       Keeper_event_queue_persistence.ack_inflight ~base_path ~keeper_name:name stimuli
     | Some entry ->
       let rec loop () =
         let cur = Atomic.get entry.event_queue in
         let next = requeue_missing_front cur stimuli in
         if next = cur
         then Keeper_event_queue_persistence.ack_inflight ~base_path ~keeper_name:name stimuli
         else if Atomic.compare_and_set entry.event_queue cur next
         then (
           persist_live_queue ~base_path entry name;
           Keeper_event_queue_persistence.ack_inflight ~base_path ~keeper_name:name stimuli)
         else loop ()
       in
       loop ())
;;

let ack_consumed_result ~base_path name stimuli =
  Keeper_event_queue_persistence.ack_consumed ~base_path ~keeper_name:name stimuli
;;

let ack_consumed ~base_path name stimuli =
  match ack_consumed_result ~base_path name stimuli with
  | Ok () -> ()
  | Error msg ->
    Log.Keeper.warn "registry: ack_consumed failed name=%s: %s" name msg
;;

let drop_by_post_id ~base_path name ~post_id =
  let remove_live (entry : Keeper_registry.registry_entry) =
    let rec loop () =
      let cur = Atomic.get entry.event_queue in
      let removed, next = Keeper_event_queue.remove_by_post_id post_id cur in
      if removed = []
      then removed
      else if Atomic.compare_and_set entry.event_queue cur next
      then (
        persist_live_queue ~base_path entry name;
        removed)
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
    let live_removed =
      match Keeper_registry.get ~base_path name with
      | None -> []
      | Some entry -> remove_live entry
    in
    Ok (Keeper_event_queue.uniq_stimuli (live_removed @ persisted_removed))
;;

let snapshot ~base_path name =
  match Keeper_registry.get ~base_path name with
  | None -> Keeper_event_queue_persistence.load ~base_path ~keeper_name:name
  | Some entry -> Atomic.get entry.event_queue
;;

let dequeue_when ~base_path name ~ready =
  match Keeper_registry.get ~base_path name with
  | None -> None
  | Some entry ->
    let rec loop () =
      let cur = Atomic.get entry.event_queue in
      match Keeper_event_queue.dequeue cur with
      | None -> None
      | Some (stim, _) when not (ready stim) -> None
      | Some (stim, rest) ->
        Keeper_event_queue_persistence.record_inflight
          ~base_path
          ~keeper_name:name
          [ stim ];
        if Atomic.compare_and_set entry.event_queue cur rest
        then (
          persist_live_queue ~base_path entry name;
          Some stim)
        else loop ()
    in
    loop ()
;;

let dequeue ~base_path name = dequeue_when ~base_path name ~ready:(fun _ -> true)

let drain_board ~base_path name =
  match Keeper_registry.get ~base_path name with
  | None -> []
  | Some entry ->
    let rec loop () =
      let cur = Atomic.get entry.event_queue in
      let board, rest = Keeper_event_queue.drain_board_all cur in
      Keeper_event_queue_persistence.record_inflight ~base_path ~keeper_name:name board;
      if Atomic.compare_and_set entry.event_queue cur rest
      then (
        persist_live_queue ~base_path entry name;
        board)
      else loop ()
    in
    loop ()
;;
