(** Cascade_tier_wait_scheduler — bounded wait layer over tier admission.

    RFC-0153 Phase C.1.

    Architecture:
    - Wraps [Cascade_tier_admission.t] without modifying it (tower
      composition pattern).
    - Per-tier FIFO queue of waiting fibers, each with its own
      [Eio.Promise] for wake-up notification.
    - Backoff: fiber sleeps [backoff_delay] then retries [try_acquire].
    - On release: oldest waiter's promise is resolved, waking it.
    - Timeout: each fiber tracks its own deadline via [Eio.Time.Timeout].

    Concurrency model:
    - [tier_mu] protects the per-tier waiter queue + stats.
    - Admission [try_acquire] / [release] go through the underlying
      [Cascade_tier_admission.t] which has its own per-tier mutex.
    - Fiber-per-waiter: each [try_admission_or_wait] call that hits
      capacity_full spawns a wait loop in the calling fiber (no extra
      fiber). The fiber is identified by its promise for FIFO ordering. *)

(* ── Configuration ──────────────────────────────────────────────── *)

type backoff_strategy =
  | Constant of float
  | Linear of { initial_s : float; max_s : float }
  | Exponential of { initial_s : float; factor : float; max_s : float }

type wait_config = {
  backoff : backoff_strategy;
  timeout_s : float;
  max_retries : int option;
}

let default_wait_config =
  {
    backoff =
      Exponential { initial_s = 0.5; factor = 2.0; max_s = 8.0 };
    timeout_s = 30.0;
    max_retries = None;
  }

let next_backoff_delay strategy attempt =
  match strategy with
  | Constant s -> s
  | Linear { initial_s; max_s } ->
      let d = initial_s *. Float.of_int attempt in
      min d max_s
  | Exponential { initial_s; factor; max_s } ->
      let d = initial_s *. (factor ** Float.of_int (attempt - 1)) in
      min d max_s

(* ── Result types ───────────────────────────────────────────────── *)

type rejection_detail =
  | Timeout_expired of {
      tier_id : string;
      total_waited_s : float;
      attempts : int;
    }
  | Max_retries_exceeded of {
      tier_id : string;
      retries : int;
      total_waited_s : float;
    }
  | Cancelled of { tier_id : string }

let pp_rejection_detail fmt = function
  | Timeout_expired { tier_id; total_waited_s; attempts } ->
      Format.fprintf fmt
        "timeout_expired tier=%s waited=%.3fs attempts=%d"
        tier_id total_waited_s attempts
  | Max_retries_exceeded { tier_id; retries; total_waited_s } ->
      Format.fprintf fmt
        "max_retries_exceeded tier=%s retries=%d waited=%.3fs"
        tier_id retries total_waited_s
  | Cancelled { tier_id } ->
      Format.fprintf fmt "cancelled tier=%s" tier_id

(* ── Per-tier state ─────────────────────────────────────────────── *)

type waiter = {
  promise : unit Eio.Promise.t;
  resolver : unit Eio.Promise.u;
}

type tier_wait_state = {
  mu : Eio.Mutex.t;
  mutable waiters : waiter Queue.t;
  mutable total_admitted : int;
  mutable total_rejected : int;
  mutable total_timeouts : int;
  mutable total_wait_s : float;
}

let create_tier_state () =
  {
    mu = Eio.Mutex.create ();
    waiters = Queue.create ();
    total_admitted = 0;
    total_rejected = 0;
    total_timeouts = 0;
    total_wait_s = 0.0;
  }

(* ── Scheduler ──────────────────────────────────────────────────── *)

type t = {
  admission : Cascade_tier_admission.t;
  tiers : (string, tier_wait_state) Hashtbl.t;
  guard_mu : Eio.Mutex.t;
  default_wait_config : wait_config;
  clock : float Eio.Time.clock_ty Eio.Resource.t option;
}

let create ?(default_wait_config = default_wait_config) ?clock admission =
  {
    admission;
    tiers = Hashtbl.create 8;
    guard_mu = Eio.Mutex.create ();
    default_wait_config;
    clock;
  }

let clock t = t.clock

let get_or_create_tier t tier_id =
  Eio.Mutex.use_rw t.guard_mu ~protect:false (fun () ->
      match Hashtbl.find_opt t.tiers tier_id with
      | Some ts -> ts
      | None ->
          let ts = create_tier_state () in
          Hashtbl.add t.tiers tier_id ts;
          ts)

(* ── Wake oldest waiter (FIFO) ──────────────────────────────────── *)

let wake_oldest ts =
  (* Must be called under [ts.mu]. *)
  match Queue.take_opt ts.waiters with
  | None -> ()
  | Some w ->
      (* resolver: resolve succeeds even if fiber already timed out *)
      Eio.Promise.resolve w.resolver ()

(* ── on_admission_release ───────────────────────────────────────── *)

let on_admission_release t ~tier_id =
  match Hashtbl.find_opt t.tiers tier_id with
  | None -> ()
  | Some ts ->
      Eio.Mutex.use_rw ts.mu ~protect:false (fun () ->
          wake_oldest ts)

(* ── Backoff sleep with cancellation ────────────────────────────── *)

let backoff_sleep t ~sw delay_s waiter_promise =
  let result_promise, result_resolver = Eio.Promise.create () in
  let finished = Atomic.make false in
  let resolve winner =
    if Atomic.compare_and_set finished false true then
      Eio.Promise.resolve result_resolver winner
  in
  (* Fiber 1: timer *)
  Eio.Fiber.fork ~sw (fun () ->
      (match t.clock with
       | Some clock -> Eio.Time.sleep clock delay_s
       | None ->
           let start = Unix.gettimeofday () in
           let rec loop () =
             if Atomic.get finished then ()
             else begin
               Eio.Fiber.yield ();
               let elapsed = Unix.gettimeofday () -. start in
               if elapsed >= delay_s then ()
               else loop ()
             end
           in
           loop ());
      resolve `Sleep_done);
  (* Fiber 2: waiter wake signal — daemon so it doesn't block
     Switch.run completion when the timer wins the race *)
  Eio.Fiber.fork_daemon ~sw (fun () ->
      (try
         Eio.Promise.await waiter_promise;
         resolve `Woken_early
       with Eio.Cancel.Cancelled _ -> ());
      `Stop_daemon);
  (result_promise, finished)

(* ── Main API: try_admission_or_wait ────────────────────────────── *)

let try_admission_or_wait t ~tier_id ?(wait_config = t.default_wait_config)
    ?deadline:cascade_deadline ~sw f =
  let start_time = Unix.gettimeofday () in
  (* RFC-0192 § 2: effective per-call timeout =
       min(wait_config.timeout_s, deadline - now()).
     Backward-compat: cascade_deadline=None or clock=None → legacy
     [wait_config.timeout_s] amplifier behaviour. *)
  let effective_timeout_s =
    match cascade_deadline, t.clock with
    | None, _ -> wait_config.timeout_s
    | Some _, None -> wait_config.timeout_s
    | Some d, Some clk ->
      Cascade_deadline.composed_attempt_budget
        ~clock:clk ~deadline:d ~amplifier:wait_config.timeout_s
  in

  (* Attempt 1: immediate try_acquire *)
  match Cascade_tier_admission.try_acquire t.admission ~tier_id with
  | Cascade_tier_admission.Granted _ ->
      (* Fast path — run f with auto-release. No tier state created. *)
      (match f () with
       | v ->
           Cascade_tier_admission.release t.admission ~tier_id;
           on_admission_release t ~tier_id;
           Ok v
       | exception exn ->
           (try
              Cascade_tier_admission.release t.admission ~tier_id;
              on_admission_release t ~tier_id
            with _ -> ());
           raise exn)
  | Cascade_tier_admission.Capacity_full _ ->
      (* Slow path — create tier state lazily, enter wait loop *)
      let ts = get_or_create_tier t tier_id in
      let wait_deadline_s = start_time +. effective_timeout_s in
      let max_retries = wait_config.max_retries in
      let rec loop attempt total_waited =
        (* Check deadline *)
        let now = Unix.gettimeofday () in
        if now >= wait_deadline_s then begin
          Eio.Mutex.use_rw ts.mu ~protect:false (fun () ->
              ts.total_timeouts <- ts.total_timeouts + 1;
              ts.total_rejected <- ts.total_rejected + 1;
              ts.total_wait_s <- ts.total_wait_s +. total_waited);
          Error (Timeout_expired { tier_id; total_waited_s = total_waited; attempts = attempt })
        end
        (* Check max_retries *)
        else begin
          match max_retries with
          | Some mr when attempt > mr ->
              Eio.Mutex.use_rw ts.mu ~protect:false (fun () ->
                  ts.total_rejected <- ts.total_rejected + 1;
                  ts.total_wait_s <- ts.total_wait_s +. total_waited);
              Error (Max_retries_exceeded {
                tier_id;
                retries = attempt - 1;
                total_waited_s = total_waited;
              })
          | _ ->
              (* Compute backoff delay *)
              let delay = next_backoff_delay wait_config.backoff attempt in
              (* Register as waiter before sleeping *)
              let waiter_promise, waiter_resolver =
                Eio.Promise.create () in
              let waiter = {
                promise = waiter_promise;
                resolver = waiter_resolver;
              } in
              Eio.Mutex.use_rw ts.mu ~protect:false (fun () ->
                  Queue.push waiter ts.waiters);
              (* Sleep for backoff delay or until woken — race *)
              let result_promise, sleep_finished =
                backoff_sleep t ~sw delay waiter_promise in
              let _race_outcome = Eio.Promise.await result_promise in
              Atomic.set sleep_finished true;
              let sleep_time =
                min delay (Unix.gettimeofday () -. now)
              in
              let new_total = total_waited +. sleep_time in
              (* Remove self from queue if still there (e.g. timeout) *)
              Eio.Mutex.use_rw ts.mu ~protect:false (fun () ->
                  (* Filter out our waiter if not yet consumed *)
                  let remaining = Queue.create () in
                  Queue.transfer ts.waiters remaining;
                  Queue.clear ts.waiters;
                  Queue.iter (fun w ->
                      if w != waiter then Queue.push w ts.waiters
                  ) remaining);
              (* Always try_acquire after sleep or wake *)
              match Cascade_tier_admission.try_acquire t.admission
                      ~tier_id with
              | Cascade_tier_admission.Granted _ ->
                  Eio.Mutex.use_rw ts.mu ~protect:false (fun () ->
                      ts.total_admitted <- ts.total_admitted + 1;
                      ts.total_wait_s <- ts.total_wait_s +. new_total);
                  (match f () with
                   | v ->
                       Cascade_tier_admission.release t.admission
                         ~tier_id;
                       on_admission_release t ~tier_id;
                       Ok v
                   | exception exn ->
                       (try Cascade_tier_admission.release
                              t.admission ~tier_id;
                            on_admission_release t ~tier_id
                        with _ -> ());
                       raise exn)
              | Cascade_tier_admission.Capacity_full _ ->
                  (* Not admitted yet — check deadline and loop *)
                  let now2 = Unix.gettimeofday () in
                  if now2 >= wait_deadline_s then begin
                    Eio.Mutex.use_rw ts.mu ~protect:false (fun () ->
                        ts.total_timeouts <- ts.total_timeouts + 1;
                        ts.total_rejected <- ts.total_rejected + 1;
                        ts.total_wait_s <- ts.total_wait_s +. new_total);
                    Error (Timeout_expired {
                      tier_id;
                      total_waited_s = new_total;
                      attempts = attempt;
                    })
                  end
                  else
                    loop (attempt + 1) new_total
        end
      in
      loop 1 0.0

(* ── Observability ──────────────────────────────────────────────── *)

type tier_wait_stats = {
  tier_id : string;
  waiting_fibers : int;
  total_admitted : int;
  total_rejected : int;
  total_timeouts : int;
  avg_wait_s : float;
}

let stats t ~tier_id =
  match Hashtbl.find_opt t.tiers tier_id with
  | None -> None
  | Some ts ->
      Eio.Mutex.use_ro ts.mu (fun () ->
          let avg =
            if ts.total_admitted > 0 then
              ts.total_wait_s /. Float.of_int ts.total_admitted
            else 0.0
          in
          Some {
            tier_id;
            waiting_fibers = Queue.length ts.waiters;
            total_admitted = ts.total_admitted;
            total_rejected = ts.total_rejected;
            total_timeouts = ts.total_timeouts;
            avg_wait_s = avg;
          })

let all_stats t =
  Hashtbl.fold (fun tier_id ts acc ->
      match stats t ~tier_id with
      | Some s -> s :: acc
      | None -> acc
    ) t.tiers []
