(* Per-binding provider concurrency gate.

   RFC-0153 §4.2.3 deferred a per-runtime cap to post-merge measurement. This
   module implements a coarser interim per-binding cap ([provider:model@base_url]
   keyed semaphore) because the live ollama.com endpoint showed that the global
   [Fd_accountant.Provider_http] gate (default 16, shared across every provider)
   cannot hold a single over-subscribed endpoint under its own limit. The
   [max_concurrent] binding field, previously parsed but inert, is now enforced
   by this gate. A future RFC may narrow the granularity to per-HTTP-call or
   per-endpoint once we have fleet-wide concurrency measurements. *)

type slot =
  { sem : Eio.Semaphore.t
  ; cap : int
  ; in_flight : int Atomic.t
  }

type wait_timeout =
  { key : string
  ; wait_timeout_sec : float
  ; in_flight : int
  ; cap : int
  }

(* Process-global registry of one semaphore per capacity key. The Hashtbl is
   module-global mutable state shared across every keeper fiber/domain, so all
   access is serialized under [registry_mutex] per RFC-0239 (a top-level
   Hashtbl is indistinguishable from a fiber-local one to the type system; the
   mutex makes the sharing explicit). The critical section is one
   find-or-insert and never spans the semaphore acquire, so contention on the
   registry mutex is bounded and does not serialize unrelated keys. *)
let registry : (string, slot) Hashtbl.t = Hashtbl.create 16
let registry_mutex = Eio.Mutex.create ()

let slot_for ~key ~max_concurrent =
  Eio.Mutex.use_rw ~protect:true registry_mutex (fun () ->
    match Hashtbl.find_opt registry key with
    | Some slot -> slot
    | None ->
      let slot =
        { sem = Eio.Semaphore.make max_concurrent
        ; cap = max_concurrent
        ; in_flight = Atomic.make 0
        }
      in
      Hashtbl.replace registry key slot;
      slot)

let finite_positive value =
  Float.is_finite value && value > 0.0

let with_slot_result ~clock ~wait_timeout_sec ~key ~max_concurrent f =
  (* [None] (or [Some n] with [n <= 0]) = unconfigured binding (runtime.toml
     omits [max-concurrent], parsed as [None]). Run ungated rather than build a
     0-permit semaphore that would deadlock on first acquire. *)
  match max_concurrent with
  | None -> Ok (f ())
  | Some max_concurrent when max_concurrent <= 0 -> Ok (f ())
  | Some max_concurrent ->
    if not (finite_positive wait_timeout_sec)
    then
      invalid_arg
        "Runtime_binding_capacity.with_slot_result: wait_timeout_sec must be \
         finite and positive";
    let slot = slot_for ~key ~max_concurrent in
    (* Cancellation-safe acquisition:

       1. The semaphore permit is acquired inside the same [Eio.Switch.run] that
          registers the release hook.
       2. The [acquired] flag starts as [false]. If [Eio.Semaphore.acquire]
          raises (timeout, cancellation, or other), the release hook sees
          [false] and does nothing.
       3. Only after [acquire] returns successfully do we set [acquired := true]
          and increment [in_flight]. At that point the release hook is already
          registered, so any subsequent cancellation cannot leak the permit or
          the counter.

       This removes the window between "acquire succeeded" and "release hook
       registered" that existed in the previous version. *)
    try
      Ok
        (Eio.Switch.run (fun sw ->
           let acquired = ref false in
           Eio.Switch.on_release sw (fun () ->
             if !acquired
             then (
               Atomic.decr slot.in_flight;
               Eio.Semaphore.release slot.sem));
           Eio.Time.with_timeout_exn clock wait_timeout_sec (fun () ->
             Eio.Semaphore.acquire slot.sem);
           acquired := true;
           Atomic.incr slot.in_flight;
           f ()))
    with
    | Eio.Time.Timeout ->
      Error
        { key
        ; wait_timeout_sec
        ; in_flight = Atomic.get slot.in_flight
        ; cap = slot.cap
        }

let snapshot () =
  Eio.Mutex.use_ro registry_mutex (fun () ->
    Hashtbl.fold
      (fun key (slot : slot) acc -> (key, Atomic.get slot.in_flight, slot.cap) :: acc)
      registry
      [])
  |> List.sort (fun (a, _, _) (b, _, _) -> String.compare a b)
