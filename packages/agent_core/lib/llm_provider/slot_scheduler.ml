(** Fair FIFO slot scheduler for LLM requests.

    Uses Eio.Mutex for state protection and Eio.Promise for per-waiter
    signaling. Capacity is the only scheduling constraint; queued requests are
    granted slots in arrival order.

    @since 0.96.0 *)

type waiter_state =
  | Waiting
  | Granted
  | Cancelled

type waiter =
  { resolver : unit Eio.Promise.u
  ; state : waiter_state Atomic.t
  }

type waiter_queue =
  { front : waiter list
  ; back : waiter list
  ; length : int
  }

let empty_queue = { front = []; back = []; length = 0 }

let enqueue waiter queue =
  { queue with back = waiter :: queue.back; length = queue.length + 1 }
;;

let dequeue queue =
  match queue.front with
  | waiter :: front -> Some (waiter, { queue with front; length = queue.length - 1 })
  | [] ->
    (match List.rev queue.back with
     | [] -> None
     | waiter :: front -> Some (waiter, { front; back = []; length = queue.length - 1 }))
;;

let remove_waiter target queue =
  let rec remove acc = function
    | [] -> None
    | waiter :: rest when waiter == target -> Some (List.rev_append acc rest)
    | waiter :: rest -> remove (waiter :: acc) rest
  in
  match remove [] (queue.front @ List.rev queue.back) with
  | None -> queue
  | Some remaining -> { front = remaining; back = []; length = queue.length - 1 }
;;

type t =
  { max_slots : int
  ; mutable active : int
  ; mutable waiters : waiter_queue
  ; mutex : Eio.Mutex.t
  }

let create ~max_slots =
  if max_slots < 1
  then
    invalid_arg
      (Printf.sprintf "Slot_scheduler.create: max_slots must be >= 1, got %d" max_slots);
  { max_slots; active = 0; waiters = empty_queue; mutex = Eio.Mutex.create () }
;;

let rec acquire t =
  let action =
    Eio.Mutex.use_rw ~protect:true t.mutex (fun () ->
      if t.active < t.max_slots && t.waiters.length = 0
      then (
        t.active <- t.active + 1;
        `Got_slot)
      else (
        let promise, resolver = Eio.Promise.create () in
        let waiter = { resolver; state = Atomic.make Waiting } in
        t.waiters <- enqueue waiter t.waiters;
        `Wait (promise, waiter)))
  in
  match action with
  | `Got_slot -> ()
  | `Wait (promise, waiter) ->
    (try Eio.Promise.await promise with
     | exn ->
       if Atomic.compare_and_set waiter.state Waiting Cancelled
       then (
         Eio.Cancel.protect (fun () ->
           Eio.Mutex.use_rw ~protect:true t.mutex (fun () ->
             t.waiters <- remove_waiter waiter t.waiters));
         raise exn)
       else (
         match Atomic.get waiter.state with
         | Granted ->
           (* The slot was transferred to this waiter before cancellation.
              Return it to the oldest remaining waiter. *)
           Eio.Cancel.protect (fun () -> release_slot t);
           raise exn
         | Cancelled ->
           invalid_arg "Slot_scheduler.acquire: waiter cancelled more than once"
         | Waiting ->
           invalid_arg "Slot_scheduler.acquire: invalid waiter state transition"))

and release_slot t =
  let to_wake =
    Eio.Mutex.use_rw ~protect:true t.mutex (fun () ->
      let release_active_slot () =
        if t.active <= 0
        then invalid_arg "Slot_scheduler.release_slot: active count underflow"
        else t.active <- t.active - 1
      in
      let rec find_waiter queue =
        match dequeue queue with
        | None ->
          t.waiters <- empty_queue;
          release_active_slot ();
          None
        | Some (waiter, rest) ->
          (match Atomic.get waiter.state with
           | Cancelled -> find_waiter rest
           | Granted ->
             invalid_arg "Slot_scheduler.release_slot: queued waiter already granted"
           | Waiting ->
             if Atomic.compare_and_set waiter.state Waiting Granted
             then (
               t.waiters <- rest;
               Some waiter.resolver)
             else find_waiter rest)
      in
      find_waiter t.waiters)
  in
  match to_wake with
  | Some resolver -> Eio.Promise.resolve resolver ()
  | None -> ()
;;

let with_permit t f =
  acquire t;
  Fun.protect f ~finally:(fun () -> release_slot t)
;;

let queue_length t = Eio.Mutex.use_ro t.mutex (fun () -> t.waiters.length)

(* ── Capacity Query ───────────────────────────── *)

type snapshot =
  { max_slots : int
  ; active : int
  ; available : int
  ; queue_length : int
  }

let snapshot t =
  Eio.Mutex.use_ro t.mutex (fun () ->
    { max_slots = t.max_slots
    ; active = t.active
    ; available = t.max_slots - t.active
    ; queue_length = t.waiters.length
    })
;;

[@@@coverage off]
(* === Inline tests === *)

let[@warning "-32"] await_queue_length clock t expected =
  Eio.Time.with_timeout_exn clock 1.0 (fun () ->
    while queue_length t < expected do
      Eio.Fiber.yield ()
    done)
;;

let%test "create with valid max_slots" =
  Eio_main.run (fun _env ->
    let t = create ~max_slots:4 in
    let s = snapshot t in
    s.max_slots = 4 && s.available = 4 && s.active = 0)
;;

let%test "create rejects zero" =
  try
    let (_ : t) = create ~max_slots:0 in
    false
  with
  | Invalid_argument _ -> true
;;

let%test "create rejects negative" =
  try
    let (_ : t) = create ~max_slots:(-1) in
    false
  with
  | Invalid_argument _ -> true
;;

let%test "with_permit runs immediately when slots available" =
  Eio_main.run (fun _env ->
    let t = create ~max_slots:2 in
    let result = with_permit t (fun () -> 42) in
    result = 42 && (snapshot t).available = 2)
;;

let%test "with_permit releases on exception" =
  Eio_main.run (fun _env ->
    let t = create ~max_slots:2 in
    (try with_permit t (fun () -> failwith "boom") with
     | Failure _ -> ());
    (snapshot t).available = 2)
;;

let%test "queue_length tracks waiters" =
  Eio_main.run (fun _env ->
    let t = create ~max_slots:1 in
    queue_length t = 0)
;;

let%test "snapshot reflects current state" =
  Eio_main.run (fun _env ->
    let t = create ~max_slots:4 in
    let s = snapshot t in
    s.max_slots = 4 && s.active = 0 && s.available = 4 && s.queue_length = 0)
;;

let%test "snapshot during active permit" =
  Eio_main.run (fun _env ->
    let t = create ~max_slots:2 in
    with_permit t (fun () ->
      let s = snapshot t in
      s.active = 1 && s.available = 1))
;;
