(** Per-keeper event-queue access.

    Extracted from keeper_registry.ml (lines 1854-1900) as part of the
    godfile decomp campaign. Each [registry_entry] carries its own
    [event_queue : Keeper_event_queue.t Atomic.t] — these wrappers do
    CAS on that per-entry atomic after locating the entry via the
    central registry's public [get]. No coupling to the central
    Atomic state primitive. CAS-successful mutations are mirrored to
    [Keeper_event_queue_persistence] for restart replay. *)

let rec queue_contains queue stimulus =
  match Keeper_event_queue.dequeue queue with
  | None -> false
  | Some (head, rest) -> head = stimulus || queue_contains rest stimulus
;;

let enqueue_if_missing queue stimulus =
  if queue_contains queue stimulus then queue else Keeper_event_queue.enqueue queue stimulus
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
      (fun cur -> Keeper_event_queue.enqueue cur stimulus);
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
      let next = Keeper_event_queue.enqueue cur stimulus in
      if Atomic.compare_and_set entry.event_queue cur next
      then persist_live_queue ~base_path entry name
      else loop ()
    in
    loop ()
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
       Keeper_event_queue_persistence.ack_inflight ~base_path ~keeper_name:name
     | Some entry ->
       let rec loop () =
         let cur = Atomic.get entry.event_queue in
         let next = requeue_missing_front cur stimuli in
         if next = cur
         then ()
         else if Atomic.compare_and_set entry.event_queue cur next
         then (
           persist_live_queue ~base_path entry name;
           Keeper_event_queue_persistence.ack_inflight ~base_path ~keeper_name:name)
         else loop ()
       in
       loop ())
;;

let ack_consumed ~base_path name =
  Keeper_event_queue_persistence.ack_inflight ~base_path ~keeper_name:name
;;

let snapshot ~base_path name =
  match Keeper_registry.get ~base_path name with
  | None -> Keeper_event_queue_persistence.load ~base_path ~keeper_name:name
  | Some entry -> Atomic.get entry.event_queue
;;

let dequeue ~base_path name =
  match Keeper_registry.get ~base_path name with
  | None -> None
  | Some entry ->
    let rec loop () =
      let cur = Atomic.get entry.event_queue in
      match Keeper_event_queue.dequeue cur with
      | None -> None
      | Some (stim, rest) ->
        if Atomic.compare_and_set entry.event_queue cur rest
        then (
          Keeper_event_queue_persistence.record_inflight
            ~base_path
            ~keeper_name:name
            [ stim ];
          persist_live_queue ~base_path entry name;
          Some stim)
        else loop ()
    in
    loop ()
;;

let drain_board ?window_sec ~base_path name =
  match Keeper_registry.get ~base_path name with
  | None -> []
  | Some entry ->
    let rec loop () =
      let cur = Atomic.get entry.event_queue in
      let board, rest = Keeper_event_queue.drain_board_window ?window_sec cur in
      if Atomic.compare_and_set entry.event_queue cur rest
      then (
        Keeper_event_queue_persistence.record_inflight ~base_path ~keeper_name:name board;
        persist_live_queue ~base_path entry name;
        board)
      else loop ()
    in
    loop ()
;;
