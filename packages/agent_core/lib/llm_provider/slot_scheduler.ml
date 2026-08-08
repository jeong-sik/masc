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

let available t = Eio.Mutex.use_ro t.mutex (fun () -> t.max_slots - t.active)
let in_use t = Eio.Mutex.use_ro t.mutex (fun () -> t.active)
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

(* ── Non-blocking Acquisition ─────────────────────────── *)

let try_with_permit t f =
  let got =
    Eio.Mutex.use_rw ~protect:true t.mutex (fun () ->
      (* A non-blocking caller must not bypass an older queued request. *)
      if t.active < t.max_slots && t.waiters.length = 0
      then (
        t.active <- t.active + 1;
        true)
      else false)
  in
  if got then Some (Fun.protect f ~finally:(fun () -> release_slot t)) else None
;;

(* ── Explicit Handle API ─────────────────────────────── *)

type permit_state =
  | Held
  | Yielded
  | Released

type permit = { mutable state : permit_state }

let acquire_permit t =
  acquire t;
  { state = Held }
;;

let yield_permit t p =
  match p.state with
  | Held ->
    release_slot t;
    p.state <- Yielded
  | Yielded -> invalid_arg "Slot_scheduler.yield_permit: permit already yielded"
  | Released -> invalid_arg "Slot_scheduler.yield_permit: permit already released"
;;

let resume_permit t p =
  match p.state with
  | Yielded ->
    (* A resumed permit rejoins the same FIFO as every other request. *)
    acquire t;
    p.state <- Held
  | Held -> invalid_arg "Slot_scheduler.resume_permit: permit is already held"
  | Released -> invalid_arg "Slot_scheduler.resume_permit: permit already released"
;;

let release_permit t p =
  match p.state with
  | Held ->
    release_slot t;
    p.state <- Released
  | Yielded -> p.state <- Released
  | Released -> invalid_arg "Slot_scheduler.release_permit: permit already released"
;;

let permit_is_held p = p.state = Held

[@@@coverage off]
(* === Inline tests === *)

let await_queue_length clock t expected =
  Eio.Time.with_timeout_exn clock 1.0 (fun () ->
    while queue_length t < expected do
      Eio.Fiber.yield ()
    done)
;;

let%test "create with valid max_slots" =
  Eio_main.run (fun _env ->
    let t = create ~max_slots:4 in
    t.max_slots = 4 && available t = 4 && in_use t = 0)
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
    result = 42 && available t = 2)
;;

let%test "with_permit releases on exception" =
  Eio_main.run (fun _env ->
    let t = create ~max_slots:2 in
    (try with_permit t (fun () -> failwith "boom") with
     | Failure _ -> ());
    available t = 2)
;;

let%test "waiters are granted slots in FIFO order" =
  Eio_main.run (fun env ->
    let clock = Eio.Stdenv.clock env in
    let t = create ~max_slots:1 in
    let blocker = acquire_permit t in
    let order = ref [] in
    Eio.Fiber.both
      (fun () -> with_permit t (fun () -> order := "first" :: !order))
      (fun () ->
         await_queue_length clock t 1;
         Eio.Fiber.both
           (fun () -> with_permit t (fun () -> order := "second" :: !order))
           (fun () ->
              await_queue_length clock t 2;
              release_permit t blocker));
    !order = [ "second"; "first" ])
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

let%test "try_with_permit succeeds when available" =
  Eio_main.run (fun _env ->
    let t = create ~max_slots:2 in
    let result = try_with_permit t (fun () -> 42) in
    result = Some 42 && available t = 2)
;;

let%test "try_with_permit returns None when full" =
  Eio_main.run (fun _env ->
    let t = create ~max_slots:1 in
    with_permit t (fun () ->
      let result = try_with_permit t (fun () -> 99) in
      result = None))
;;

let%test "try_with_permit releases on exception" =
  Eio_main.run (fun _env ->
    let t = create ~max_slots:2 in
    (try ignore (try_with_permit t (fun () -> failwith "boom")) with
     | Failure _ -> ());
    available t = 2)
;;

(* === Explicit Handle API tests === *)

let%test "acquire_permit and release_permit" =
  Eio_main.run (fun _env ->
    let t = create ~max_slots:2 in
    let p = acquire_permit t in
    permit_is_held p
    && in_use t = 1
    &&
    (release_permit t p;
     in_use t = 0))
;;

let%test "yield then resume" =
  Eio_main.run (fun _env ->
    let t = create ~max_slots:2 in
    let p = acquire_permit t in
    yield_permit t p;
    (not (permit_is_held p))
    && in_use t = 0
    &&
    (resume_permit t p;
     permit_is_held p
     && in_use t = 1
     &&
     (release_permit t p;
      in_use t = 0)))
;;

let%test "yield frees slot for other agent" =
  Eio_main.run (fun _env ->
    let t = create ~max_slots:1 in
    let p1 = acquire_permit t in
    let got_before = try_with_permit t (fun () -> true) in
    yield_permit t p1;
    let got_after = try_with_permit t (fun () -> true) in
    resume_permit t p1;
    release_permit t p1;
    got_before = None && got_after = Some true)
;;

let%test "release from yielded state" =
  Eio_main.run (fun _env ->
    let t = create ~max_slots:2 in
    let p = acquire_permit t in
    yield_permit t p;
    release_permit t p;
    in_use t = 0 && not (permit_is_held p))
;;

let%test "double yield raises" =
  Eio_main.run (fun _env ->
    let t = create ~max_slots:2 in
    let p = acquire_permit t in
    yield_permit t p;
    try
      yield_permit t p;
      false
    with
    | Invalid_argument _ ->
      release_permit t p;
      true)
;;

let%test "resume on held raises" =
  Eio_main.run (fun _env ->
    let t = create ~max_slots:2 in
    let p = acquire_permit t in
    try
      resume_permit t p;
      false
    with
    | Invalid_argument _ ->
      release_permit t p;
      true)
;;

let%test "double release raises" =
  Eio_main.run (fun _env ->
    let t = create ~max_slots:2 in
    let p = acquire_permit t in
    release_permit t p;
    try
      release_permit t p;
      false
    with
    | Invalid_argument _ -> true)
;;

let%test "resumed permit rejoins FIFO" =
  Eio_main.run (fun env ->
    let clock = Eio.Stdenv.clock env in
    let t = create ~max_slots:1 in
    let resumed = acquire_permit t in
    yield_permit t resumed;
    let blocker = acquire_permit t in
    let order = ref [] in
    Eio.Fiber.both
      (fun () -> with_permit t (fun () -> order := "first" :: !order))
      (fun () ->
         await_queue_length clock t 1;
         Eio.Fiber.both
           (fun () ->
              resume_permit t resumed;
              order := "resumed" :: !order;
              release_permit t resumed)
           (fun () ->
              await_queue_length clock t 2;
              release_permit t blocker));
    !order = [ "resumed"; "first" ])
;;

let%test "cancel does not leak slot" =
  Eio_main.run (fun env ->
    let clock = Eio.Stdenv.clock env in
    let t = create ~max_slots:1 in
    let blocker = acquire_permit t in
    let cancelled =
      try
        Eio.Time.with_timeout_exn clock 0.01 (fun () -> acquire t);
        false
      with
      | Eio.Time.Timeout -> true
    in
    release_permit t blocker;
    cancelled && available t = 1 && queue_length t = 0)
;;

let%test "cancelled waiters leave the queue immediately" =
  Eio_main.run (fun env ->
    let clock = Eio.Stdenv.clock env in
    let t = create ~max_slots:1 in
    let p = acquire_permit t in
    let timed_out_waiter () =
      try
        Eio.Time.with_timeout_exn clock 0.01 (fun () -> acquire t);
        false
      with
      | Eio.Time.Timeout -> true
    in
    let first_cancelled = timed_out_waiter () in
    let second_cancelled = timed_out_waiter () in
    let queued_before_release = queue_length t in
    release_permit t p;
    let snap = snapshot t in
    first_cancelled
    && second_cancelled
    && queued_before_release = 0
    && snap.active = 0
    && snap.available = 1
    && snap.queue_length = 0)
;;
