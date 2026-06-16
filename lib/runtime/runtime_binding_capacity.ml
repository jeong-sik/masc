(** Runtime_binding_capacity — per-binding provider HTTP concurrency gate.
    See {!Runtime_binding_capacity} (.mli) for the contract. *)

let wait_timeout_env = "MASC_KEEPER_BINDING_SLOT_WAIT_TIMEOUT_SEC"
let default_wait_timeout_fallback_sec = 15.0
let min_wait_timeout_sec = 1.0
let max_wait_timeout_sec = 300.0

let default_wait_timeout_sec () =
  let clamp v = Float.min max_wait_timeout_sec (Float.max min_wait_timeout_sec v) in
  match Sys.getenv_opt wait_timeout_env with
  | None -> default_wait_timeout_fallback_sec
  | Some raw ->
    (match float_of_string_opt (String.trim raw) with
     | Some v when Float.is_finite v && v > 0.0 -> clamp v
     | Some _ | None -> default_wait_timeout_fallback_sec)

(* One semaphore per capacity key. [cap] is recorded for diagnostics; the
   semaphore's capacity is fixed at creation, so a later differing cap for the
   same key reuses the first semaphore (caps are static runtime.toml config). *)
type slot =
  { sem : Eio.Semaphore.t
  ; cap : int
  }

let registry : (string, slot) Hashtbl.t = Hashtbl.create 16

(* Stdlib Mutex (not Eio.Mutex): the registry is shared mutable state across
   Eio Executor_pool worker domains, so find-or-insert needs a real cross-domain
   lock. The critical section performs no effects, so it does not block fibers
   beyond the Hashtbl op. *)
let registry_mutex = Mutex.create ()

let slot_for ~key ~cap =
  Mutex.lock registry_mutex;
  Fun.protect
    ~finally:(fun () -> Mutex.unlock registry_mutex)
    (fun () ->
       match Hashtbl.find_opt registry key with
       | Some slot -> slot
       | None ->
         let slot = { sem = Eio.Semaphore.make cap; cap } in
         Hashtbl.replace registry key slot;
         slot)

let with_slot_result ?clock ?wait_timeout_sec ~key ~(max_concurrent : int option) f =
  match max_concurrent with
  | None -> Ok (f ())
  | Some n when n <= 0 -> Ok (f ())
  | Some n ->
    let slot = slot_for ~key ~cap:n in
    (* Run inside a fresh Switch and bind release to [acquired] via on_release.
       There is no effect-suspension point between [Eio.Semaphore.acquire]
       returning and [acquired := true], so a wait-timeout cancellation that
       races a permit transfer cannot drop a held permit: either acquire never
       returned (no permit, [acquired]=false) or it returned and the flag was
       set (permit released by on_release). f runs inside the switch, so the
       permit is held across f and released on return / raise / cancel. *)
    Eio.Switch.run (fun sw ->
      let acquired = ref false in
      Eio.Switch.on_release sw (fun () ->
        if !acquired then Eio.Semaphore.release slot.sem);
      let got =
        match clock with
        | Some clock ->
          let wait =
            match wait_timeout_sec with
            | Some w -> w
            | None -> default_wait_timeout_sec ()
          in
          (match
             Eio.Time.with_timeout clock wait (fun () ->
               Eio.Semaphore.acquire slot.sem;
               acquired := true;
               Ok ())
           with
           | Ok () -> true
           | Error `Timeout -> false)
        | None ->
          Eio.Semaphore.acquire slot.sem;
          acquired := true;
          true
      in
      if got then Ok (f ()) else Error `Slot_timeout)
