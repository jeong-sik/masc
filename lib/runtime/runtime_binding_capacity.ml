(* Per-binding provider concurrency gate. See runtime_binding_capacity.mli for
   the rationale (RFC-0153 §4.2.3 deferred per-runtime cap; activates the inert
   binding max_concurrent left over from the RFC-0206 runtime rebirth). *)

type slot =
  { sem : Eio.Semaphore.t
  ; cap : int
  ; in_flight : int Atomic.t
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

let with_slot ~key ~max_concurrent f =
  (* [max_concurrent <= 0] = unconfigured binding (runtime.toml omits
     [max-concurrent], parsed as the 0 "required" marker). Run ungated rather
     than build a 0-permit semaphore that would deadlock on first acquire. *)
  if max_concurrent <= 0
  then f ()
  else begin
    let slot = slot_for ~key ~max_concurrent in
    (* Acquire BEFORE [Fun.protect] is armed: if acquisition is cancelled it
       raises here and no slot is held, so there is nothing to release. Once
       [acquire] returns the slot is held; [Atomic.incr] and entering
       [Fun.protect] are synchronous (no await point between), so the release
       path is guaranteed to run for every held slot. *)
    Eio.Semaphore.acquire slot.sem;
    Atomic.incr slot.in_flight;
    Fun.protect
      ~finally:(fun () ->
        (* fun-protect-finally-ok: [Atomic.decr] and [Eio.Semaphore.release]
           do not raise, so the finally cannot mask the body's exception with
           [Fun.Finally_raised]. *)
        Atomic.decr slot.in_flight;
        Eio.Semaphore.release slot.sem)
      f
  end

let snapshot () =
  Eio.Mutex.use_ro registry_mutex (fun () ->
    Hashtbl.fold
      (fun key slot acc -> (key, Atomic.get slot.in_flight, slot.cap) :: acc)
      registry
      [])
  |> List.sort (fun (a, _, _) (b, _, _) -> String.compare a b)
