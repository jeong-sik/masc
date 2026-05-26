(** Keeper_turn_slot_acquire_queue — autonomous wait queue extracted from
    [Keeper_turn_slot_acquire] (588 LoC).
    @since Keeper 500-line decomposition *)

type autonomous_waiter =
  { ticket : int
  ; keeper_name : string
  }

(* Eio.Mutex: queue operations are pure/non-yielding. Stdlib.Mutex is PTHREAD_MUTEX_ERRORCHECK on OCaml 5 and raises "Resource deadlock avoided" whenever two Eio fibers on the same OS thread contend, ... *)
let autonomous_wait_queue_mutex = Eio.Mutex.create ()

(* FIFO waiters use an append-only queue plus an active-ticket table. Removing a middle waiter only tombstones its ticket; the physical queue is pruned lazily from the head. This keeps enqueue/drop O(... *)
let autonomous_wait_queue : autonomous_waiter Queue.t = Queue.create ()
let autonomous_wait_queue_active_tickets : (int, unit) Hashtbl.t = Hashtbl.create 32
let autonomous_wait_queue_active_count = ref 0
let autonomous_wait_queue_next_ticket = ref 0

(* Routed through Env_config_keeper so operators can tune cadence without a rebuild (same fragmentation class as the watchdog thresholds extracted in #10740). The value is read once at module load — r... *)
let autonomous_queue_poll_sec =
  Env_config_keeper.KeeperPollIntervals.autonomous_queue_poll_sec
;;
let with_autonomous_wait_queue f =
  Eio.Mutex.use_rw ~protect:true autonomous_wait_queue_mutex f
;;
let autonomous_queue_depth_labels = [ "channel", "autonomous_queue" ]
let record_autonomous_queue_depth depth =
  Prometheus.set_gauge
    Keeper_metrics.metric_keeper_turn_queue_depth
    ~labels:autonomous_queue_depth_labels
    (float_of_int depth)
;;
let autonomous_queue_peek_opt () =
  try Some (Queue.peek autonomous_wait_queue) with
  | Queue.Empty -> None
;;
let prune_autonomous_wait_queue_locked () =
  let rec loop () =
    match autonomous_queue_peek_opt () with
    | None -> ()
    | Some waiter ->
      if Hashtbl.mem autonomous_wait_queue_active_tickets waiter.ticket
      then ()
      else (
        (* fire-and-forget: drain queue element *)
        ignore (Queue.take autonomous_wait_queue);
        loop ())
  in
  loop ()
;;
let active_autonomous_waiters_locked () =
  prune_autonomous_wait_queue_locked ();
  let active = ref [] in
  Queue.iter
    (fun waiter ->
       if Hashtbl.mem autonomous_wait_queue_active_tickets waiter.ticket
       then active := waiter :: !active)
    autonomous_wait_queue;
  List.rev !active
;;
let autonomous_wait_queue_depth () =
  with_autonomous_wait_queue (fun () ->
    prune_autonomous_wait_queue_locked ();
    !autonomous_wait_queue_active_count)
;;
let reset_autonomous_turn_queue_for_test () =
  with_autonomous_wait_queue (fun () ->
    Queue.clear autonomous_wait_queue;
    Hashtbl.reset autonomous_wait_queue_active_tickets;
    autonomous_wait_queue_active_count := 0;
    autonomous_wait_queue_next_ticket := 0;
    record_autonomous_queue_depth 0)
;;
let enqueue_autonomous_waiter ~(keeper_name : string) : int =
  with_autonomous_wait_queue (fun () ->
    let ticket = !autonomous_wait_queue_next_ticket in
    incr autonomous_wait_queue_next_ticket;
    Queue.add { ticket; keeper_name } autonomous_wait_queue;
    Hashtbl.replace autonomous_wait_queue_active_tickets ticket ();
    incr autonomous_wait_queue_active_count;
    record_autonomous_queue_depth !autonomous_wait_queue_active_count;
    ticket)
;;
let drop_autonomous_waiter ~(ticket : int) : unit =
  with_autonomous_wait_queue (fun () ->
    if Hashtbl.mem autonomous_wait_queue_active_tickets ticket
    then (
      Hashtbl.remove autonomous_wait_queue_active_tickets ticket;
      decr autonomous_wait_queue_active_count);
    prune_autonomous_wait_queue_locked ();
    record_autonomous_queue_depth !autonomous_wait_queue_active_count)
;;
let autonomous_waiter_snapshot_for_test () : string list =
  with_autonomous_wait_queue (fun () ->
    List.map (fun waiter -> waiter.keeper_name) (active_autonomous_waiters_locked ()))
;;
let enqueue_autonomous_waiter_for_test keeper_name =
  enqueue_autonomous_waiter ~keeper_name
;;
let drop_autonomous_waiter_for_test ticket = drop_autonomous_waiter ~ticket
let autonomous_waiter_head_ticket () : int option =
  with_autonomous_wait_queue (fun () ->
    prune_autonomous_wait_queue_locked ();
    match autonomous_queue_peek_opt () with
    | Some head -> Some head.ticket
    | None -> None)
;;
let autonomous_waiter_position ~(ticket : int) : int option =
  with_autonomous_wait_queue (fun () ->
    prune_autonomous_wait_queue_locked ();
    let position = ref None in
    let idx = ref 0 in
    Queue.iter
      (fun waiter ->
         if
           Option.is_none !position
           && Hashtbl.mem autonomous_wait_queue_active_tickets waiter.ticket
         then if waiter.ticket = ticket then position := Some !idx else incr idx)
      autonomous_wait_queue;
    !position)
;;
