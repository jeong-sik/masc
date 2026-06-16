(* Per-binding provider concurrency gate. See runtime_binding_capacity.mli for
   the rationale (RFC-0153 §4.2.3 deferred per-runtime cap; activates the inert
   binding max_concurrent left over from the RFC-0206 runtime rebirth). *)

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

let finite_positive = function
  | Some value when Float.is_finite value && value > 0.0 -> Some value
  | Some _ | None -> None

let acquire ?clock ?wait_timeout_sec (slot : slot) =
  match clock, finite_positive wait_timeout_sec with
  | Some clock, Some wait_timeout_sec ->
    (try
       Eio.Time.with_timeout_exn clock wait_timeout_sec (fun () ->
         Eio.Semaphore.acquire slot.sem);
       Ok ()
     with Eio.Time.Timeout ->
       Error
         { key = ""
         ; wait_timeout_sec
         ; in_flight = Atomic.get slot.in_flight
         ; cap = slot.cap
         })
  | _, _ ->
    Eio.Semaphore.acquire slot.sem;
    Ok ()

let with_slot_result ?clock ?wait_timeout_sec ~key ~max_concurrent f =
  (* [max_concurrent <= 0] = unconfigured binding (runtime.toml omits
     [max-concurrent], parsed as the 0 "required" marker). Run ungated rather
     than build a 0-permit semaphore that would deadlock on first acquire. *)
  if max_concurrent <= 0
  then Ok (f ())
  else begin
    let slot = slot_for ~key ~max_concurrent in
    (* Acquire before registering cleanup: if acquisition is cancelled it raises
       here and no slot is held. After [acquire] returns, [Atomic.incr] and
       [Switch.on_release] registration are synchronous, so every held slot has
       a release hook before [f] can yield. *)
    match acquire ?clock ?wait_timeout_sec slot with
    | Error timeout -> Error { timeout with key }
    | Ok () ->
      Atomic.incr slot.in_flight;
      Ok
        (Eio.Switch.run (fun sw ->
           Eio.Switch.on_release sw (fun () ->
             Atomic.decr slot.in_flight;
             Eio.Semaphore.release slot.sem);
           f ()))
  end

let with_slot ~key ~max_concurrent f =
  match with_slot_result ~key ~max_concurrent f with
  | Ok value -> value
  | Error _ -> assert false

let snapshot () =
  Eio.Mutex.use_ro registry_mutex (fun () ->
    Hashtbl.fold
      (fun key (slot : slot) acc -> (key, Atomic.get slot.in_flight, slot.cap) :: acc)
      registry
      [])
  |> List.sort (fun (a, _, _) (b, _, _) -> String.compare a b)
