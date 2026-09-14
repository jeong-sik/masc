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

(* Takes a free slot, or joins the queue. Under the mutex so the count and
   the queue move together. *)
let request_slot t =
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
;;

let release_slot t =
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

(* Whether a waiter whose wait has ended owns a slot is decided by its state
   transition, never by which fiber finished first. [release_slot] hands a
   slot over with the CAS Waiting -> Granted; a waiter that wins the CAS
   Waiting -> Cancelled here was never handed one and leaves the queue. A
   waiter that loses it was granted the slot in the same instant, however
   its wait ended, and owns it: it is used or returned, never dropped.
   ([Fiber.first] discards the later of two results, so a wait raced
   against a timer can end "expired" with the grant already made.) *)
let leave_or_own t waiter =
  if Atomic.compare_and_set waiter.state Waiting Cancelled
  then (
    Eio.Cancel.protect (fun () ->
      Eio.Mutex.use_rw ~protect:true t.mutex (fun () ->
        t.waiters <- remove_waiter waiter t.waiters));
    `Left_queue)
  else (
    match Atomic.get waiter.state with
    | Granted -> `Owns_slot
    | Cancelled -> invalid_arg "Slot_scheduler: waiter cancelled more than once"
    | Waiting -> invalid_arg "Slot_scheduler: invalid waiter state transition")
;;

let acquire t =
  match request_slot t with
  | `Got_slot -> ()
  | `Wait (promise, waiter) ->
    (try Eio.Promise.await promise with
     | exn ->
       (match leave_or_own t waiter with
        | `Left_queue -> ()
        | `Owns_slot ->
          (* The slot was transferred to this waiter before the exception.
             Return it to the oldest remaining waiter. *)
          Eio.Cancel.protect (fun () -> release_slot t));
       raise exn)
;;

type permit_wait =
  | Before_any_wait
  | Waiting_for_permit
  | Wait_settled_at of float

(* [acquire] whose wait for a slot ends at [deadline_at] on [clock]. A wait
   that happens is written to the caller's [wait] cell as it begins and as
   it ends, however it ends, with the instant it ended on [clock]; a slot
   granted at once is no wait and writes nothing. An [Atomic.set] neither
   raises nor blocks, so the caller's cell cannot cost the wait its slot or
   its place in the queue. *)
let acquire_until ?wait ~clock ~deadline_at t =
  match request_slot t with
  | `Got_slot -> Ok ()
  | `Wait (promise, waiter) ->
    let note state = Option.iter (fun cell -> Atomic.set cell state) wait in
    note Waiting_for_permit;
    Fun.protect
      ~finally:(fun () -> note (Wait_settled_at (Eio.Time.now clock)))
      (fun () ->
         let remaining = Float.max 0.0 (deadline_at -. Eio.Time.now clock) in
         match
           Eio.Time.with_timeout clock remaining (fun () -> Ok (Eio.Promise.await promise))
         with
         | Ok () -> Ok ()
         | Error `Timeout ->
           (match leave_or_own t waiter with
            | `Left_queue -> Error `Permit_wait_expired
            | `Owns_slot ->
              (* Granted as the deadline passed: the wait this deadline bounded
                 is over and the slot is this caller's. *)
              Ok ())
         | exception exn ->
           (match leave_or_own t waiter with
            | `Left_queue -> ()
            | `Owns_slot -> Eio.Cancel.protect (fun () -> release_slot t));
           raise exn)
;;

let with_permit t f =
  acquire t;
  Fun.protect f ~finally:(fun () -> release_slot t)
;;

let with_permit_until ?wait ~clock ~deadline_at t f =
  if Float.compare (deadline_at -. Eio.Time.now clock) 0.0 <= 0
  then Error `Permit_wait_expired
  else (
    match acquire_until ?wait ~clock ~deadline_at t with
    | Error `Permit_wait_expired as expired -> expired
    | Ok () -> Ok (Fun.protect f ~finally:(fun () -> release_slot t)))
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
