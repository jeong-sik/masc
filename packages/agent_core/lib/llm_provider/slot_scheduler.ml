(** Slot scheduler for LLM requests.

    A [Stdlib.Mutex] guards the counts and queues: every critical section
    only moves them and never blocks or switches fibers, so it also runs
    outside an Eio fiber ({!reconfigure} from a config load). Each waiter
    is woken through its own [Eio.Promise], resolved after the mutex is
    released. Queued requests are granted slots in arrival order within
    their class; see {!Slot_scheduler.create} for how the two classes share
    a freed slot.

    @since 0.96.0 *)

type waiter_state =
  | Waiting
  | Granted
  | Cancelled

type waiter =
  { resolver : unit Eio.Promise.u
  ; state : waiter_state Atomic.t
  ; queue : Admission_class.t
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
  { mutable max_slots : int
  ; mutable priority_run_limit : int option
  ; mutable active : int
  ; mutable priority : waiter_queue
  ; mutable standard : waiter_queue
  ; mutable priority_run : int
        (** Slots handed to [Priority] in a row while a [Standard] waiter
            was queued. Back to 0 whenever no [Standard] waiter is queued. *)
  ; mutex : Stdlib.Mutex.t
  }

let check_allowance ~caller ~max_slots ~priority_run_limit =
  if max_slots < 1
  then
    invalid_arg
      (Printf.sprintf "Slot_scheduler.%s: max_slots must be >= 1, got %d" caller max_slots);
  match priority_run_limit with
  | Some limit when limit < 1 ->
    invalid_arg
      (Printf.sprintf
         "Slot_scheduler.%s: priority_run_limit must be >= 1, got %d"
         caller
         limit)
  | Some _ | None -> ()
;;

let create ~max_slots ~priority_run_limit =
  check_allowance ~caller:"create" ~max_slots ~priority_run_limit;
  { max_slots
  ; priority_run_limit
  ; active = 0
  ; priority = empty_queue
  ; standard = empty_queue
  ; priority_run = 0
  ; mutex = Stdlib.Mutex.create ()
  }
;;

let queued t = t.priority.length + t.standard.length

(* The queue a request of [admission_class] joins. A scheduler without a
   run limit has one FIFO, so both classes wait in arrival order. *)
let queue_of t admission_class =
  match t.priority_run_limit, (admission_class : Admission_class.t) with
  | Some _, Priority -> Admission_class.Priority
  | Some _, Standard | None, (Priority | Standard) -> Admission_class.Standard
;;

(* Takes a free slot, or joins its class's queue. Under the mutex so the
   count and the queues move together. A free slot is taken at once only
   when nobody is queued, so a newcomer never passes a waiter. *)
let request_slot t ~admission_class =
  Stdlib.Mutex.protect t.mutex (fun () ->
    if t.active < t.max_slots && queued t = 0
    then (
      t.active <- t.active + 1;
      `Got_slot)
    else (
      let promise, resolver = Eio.Promise.create () in
      let queue = queue_of t admission_class in
      let waiter = { resolver; state = Atomic.make Waiting; queue } in
      (match queue with
       | Priority -> t.priority <- enqueue waiter t.priority
       | Standard -> t.standard <- enqueue waiter t.standard);
      `Wait (promise, waiter)))
;;

(* The first waiter of [queue] that can still take a slot, handed it with
   the CAS Waiting -> Granted, and the queue behind it. Cancelled waiters in
   front of it are dropped. *)
let rec take_waiting queue =
  match dequeue queue with
  | None -> None, empty_queue
  | Some (waiter, rest) ->
    (match Atomic.get waiter.state with
     | Cancelled -> take_waiting rest
     | Granted -> invalid_arg "Slot_scheduler.release_slot: queued waiter already granted"
     | Waiting ->
       if Atomic.compare_and_set waiter.state Waiting Granted
       then Some waiter, rest
       else take_waiting rest)
;;

(* Which queue a freed slot goes to. [Priority] goes first, except that once
   it has taken [limit] slots in a row while a [Standard] waiter was queued,
   the next slot goes to [Standard]. A scheduler without a limit queues
   newcomers as [Standard]; waiters a removed limit left in the [Priority]
   queue still go first. *)
let next_queue t =
  if t.priority.length = 0
  then Admission_class.Standard
  else if t.standard.length = 0
  then Admission_class.Priority
  else (
    match t.priority_run_limit with
    | None -> Admission_class.Priority
    | Some limit ->
      if t.priority_run < limit then Admission_class.Priority else Admission_class.Standard)
;;

(* Hands one slot to the next live waiter, under the mutex, and returns its
   resolver; [None] when nobody live is queued. Cancelled waiters met on the
   way are dropped. *)
let rec take_next t =
  if queued t = 0
  then None
  else (
    match next_queue t with
    | Priority ->
      let standard_waiting = t.standard.length > 0 in
      (match take_waiting t.priority with
       | Some waiter, rest ->
         t.priority <- rest;
         t.priority_run <- (if standard_waiting then t.priority_run + 1 else 0);
         Some waiter.resolver
       | None, rest ->
         t.priority <- rest;
         take_next t)
    | Standard ->
      (match take_waiting t.standard with
       | Some waiter, rest ->
         t.standard <- rest;
         t.priority_run <- 0;
         Some waiter.resolver
       | None, rest ->
         t.standard <- rest;
         t.priority_run <- 0;
         take_next t))
;;

let release_slot t =
  let to_wake =
    Stdlib.Mutex.protect t.mutex (fun () ->
      let release_active_slot () =
        if t.active <= 0
        then invalid_arg "Slot_scheduler.release_slot: active count underflow"
        else t.active <- t.active - 1
      in
      (* Above a lowered [max_slots], a returned slot is not handed on:
         the count comes down to the new allowance first. *)
      if t.active > t.max_slots
      then (
        release_active_slot ();
        None)
      else (
        match take_next t with
        | Some resolver -> Some resolver
        | None ->
          release_active_slot ();
          None))
  in
  match to_wake with
  | Some resolver -> Eio.Promise.resolve resolver ()
  | None -> ()
;;

(* A raised [max_slots] hands the new slots to waiters at once; a lowered
   one takes effect as holders return slots ([release_slot]). Waiters keep
   their queue: a request queued before a run limit changed stays in the
   queue it joined. *)
let reconfigure t ~max_slots ~priority_run_limit =
  check_allowance ~caller:"reconfigure" ~max_slots ~priority_run_limit;
  let to_wake =
    Stdlib.Mutex.protect t.mutex (fun () ->
      t.max_slots <- max_slots;
      t.priority_run_limit <- priority_run_limit;
      let rec fill woken =
        if t.active >= t.max_slots
        then woken
        else (
          match take_next t with
          | None -> woken
          | Some resolver ->
            t.active <- t.active + 1;
            fill (resolver :: woken))
      in
      List.rev (fill []))
  in
  List.iter (fun resolver -> Eio.Promise.resolve resolver ()) to_wake
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
    Stdlib.Mutex.protect t.mutex (fun () ->
      match waiter.queue with
      | Priority -> t.priority <- remove_waiter waiter t.priority
      | Standard ->
        t.standard <- remove_waiter waiter t.standard;
        if t.standard.length = 0 then t.priority_run <- 0);
    `Left_queue)
  else (
    match Atomic.get waiter.state with
    | Granted -> `Owns_slot
    | Cancelled -> invalid_arg "Slot_scheduler: waiter cancelled more than once"
    | Waiting -> invalid_arg "Slot_scheduler: invalid waiter state transition")
;;

type wait_end =
  | Wait_granted
  | Wait_expired

(* [on_queue] runs inside the arm that leaves the queue on any exception, so
   a raising observer cannot strand the waiter. The finisher it returns is
   handed back for [with_permit] to run under the slot's release. *)
let acquire ?on_queue t ~admission_class =
  match request_slot t ~admission_class with
  | `Got_slot -> None
  | `Wait (promise, waiter) ->
    (try
       let finish = Option.map (fun on_queue -> on_queue ()) on_queue in
       Eio.Promise.await promise;
       finish
     with
     | exn ->
       (match leave_or_own t waiter with
        | `Left_queue -> ()
        | `Owns_slot ->
          (* The slot was transferred to this waiter before the exception.
             Return it to the next waiter. *)
          release_slot t);
       raise exn)
;;

type permit_wait =
  | Before_any_wait
  | Waiting_for_permit
  | Wait_settled_at of float

(* [acquire] whose wait for a slot ends at [deadline_at] on [clock]; a
   deadline already passed asks for no slot. A wait that happens is written
   to the caller's [wait] cell as it begins and as it ends, however it ends,
   with the instant it ended on [clock]; a slot granted at once is no wait
   and writes nothing. An [Atomic.set] neither raises nor blocks, so the
   caller's cell cannot cost the wait its slot or its place in the queue. *)
let acquire_until ?wait ?on_queue ~clock ~deadline_at ~admission_class t =
  let remaining = deadline_at -. Eio.Time.now clock in
  if Float.compare remaining 0.0 <= 0
  then Error `Permit_wait_expired
  else (
    match request_slot t ~admission_class with
    | `Got_slot -> Ok None
    | `Wait (promise, waiter) ->
      let note state = Option.iter (fun cell -> Atomic.set cell state) wait in
      note Waiting_for_permit;
      (* Set inside the bounded wait, so a raising [on_queue] reaches the arm
         that leaves the queue; an expiry still finds the finisher here. *)
      let finish = ref None in
      Fun.protect
        ~finally:(fun () -> note (Wait_settled_at (Eio.Time.now clock)))
        (fun () ->
           match
             Eio.Time.with_timeout clock remaining (fun () ->
               finish := Option.map (fun on_queue -> on_queue ()) on_queue;
               Ok (Eio.Promise.await promise))
           with
           | Ok () -> Ok !finish
           | Error `Timeout ->
             (match leave_or_own t waiter with
              | `Left_queue ->
                Option.iter (fun finish -> finish Wait_expired) !finish;
                Error `Permit_wait_expired
              | `Owns_slot ->
                (* Granted as the deadline passed: the wait this deadline bounded
                   is over and the slot is this caller's. *)
                Ok !finish)
           | exception exn ->
             (match leave_or_own t waiter with
              | `Left_queue -> ()
              | `Owns_slot -> release_slot t);
             raise exn))
;;

(* The slot goes back whether [f] returned, raised or was cancelled:
   [release_slot] takes only the scheduler's [Stdlib.Mutex] and performs no
   effect, so a fiber whose cancellation is already requested still returns
   the slot in full. *)
let release_after t f = Fun.protect f ~finally:(fun () -> release_slot t)


(* A granted wait's finisher runs under the release, so one that raises
   still gives the slot back. *)
let run_granted finish f () =
  Option.iter (fun finish -> finish Wait_granted) finish;
  f ()
;;

let with_permit ?on_queue ~admission_class t f =
  let finish = acquire ?on_queue t ~admission_class in
  release_after t (run_granted finish f)
;;

let with_permit_until ?wait ?on_queue ~clock ~deadline_at ~admission_class t f =
  match acquire_until ?wait ?on_queue ~clock ~deadline_at ~admission_class t with
  | Error `Permit_wait_expired as expired -> expired
  | Ok finish -> Ok (release_after t (run_granted finish f))
;;

let queue_length t = Stdlib.Mutex.protect t.mutex (fun () -> queued t)

(* ── Capacity Query ───────────────────────────── *)

type snapshot =
  { max_slots : int
  ; active : int
  ; available : int
  ; queue_length : int
  }

let snapshot t =
  Stdlib.Mutex.protect t.mutex (fun () ->
    { max_slots = t.max_slots
    ; active = t.active
    ; available = Int.max 0 (t.max_slots - t.active)
    ; queue_length = queued t
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
    let t = create ~max_slots:4 ~priority_run_limit:None in
    let s = snapshot t in
    s.max_slots = 4 && s.available = 4 && s.active = 0)
;;

let%test "create rejects zero" =
  try
    let (_ : t) = create ~max_slots:0 ~priority_run_limit:None in
    false
  with
  | Invalid_argument _ -> true
;;

let%test "create rejects negative" =
  try
    let (_ : t) = create ~max_slots:(-1) ~priority_run_limit:None in
    false
  with
  | Invalid_argument _ -> true
;;

let%test "with_permit runs immediately when slots available" =
  Eio_main.run (fun _env ->
    let t = create ~max_slots:2 ~priority_run_limit:None in
    let result = with_permit ~admission_class:Standard t (fun () -> 42) in
    result = 42 && (snapshot t).available = 2)
;;

let%test "with_permit releases on exception" =
  Eio_main.run (fun _env ->
    let t = create ~max_slots:2 ~priority_run_limit:None in
    (try with_permit ~admission_class:Standard t (fun () -> failwith "boom") with
     | Failure _ -> ());
    (snapshot t).available = 2)
;;

let%test "queue_length tracks waiters" =
  Eio_main.run (fun _env ->
    let t = create ~max_slots:1 ~priority_run_limit:None in
    queue_length t = 0)
;;

let%test "snapshot reflects current state" =
  Eio_main.run (fun _env ->
    let t = create ~max_slots:4 ~priority_run_limit:None in
    let s = snapshot t in
    s.max_slots = 4 && s.active = 0 && s.available = 4 && s.queue_length = 0)
;;

let%test "snapshot during active permit" =
  Eio_main.run (fun _env ->
    let t = create ~max_slots:2 ~priority_run_limit:None in
    with_permit ~admission_class:Standard t (fun () ->
      let s = snapshot t in
      s.active = 1 && s.available = 1))
;;
