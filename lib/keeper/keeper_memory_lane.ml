(** Per-keeper memory execution lane. See keeper_memory_lane.mli (RFC-0252). *)

type entry =
  { mem_mu : Eio.Mutex.t
    (* Serializes memory work within one keeper; held across a provider round
       trip (seconds), hence the fiber-cooperative Eio.Mutex. Raw lock/unlock,
       not [use_rw]: a raising unit must not poison the lane. *)
  ; state_mu : Stdlib.Mutex.t
    (* Guards [pending]. Critical sections never yield. *)
  ; mutable pending : int
  }

type outcome =
  | Submitted
  | Ran_inline
  | Dropped

(* One unit in flight (holding [mem_mu]) plus one queued. A third concurrent
   post-turn unit for the same keeper means turns outpace extraction; the excess
   is best-effort and dropped rather than piling up fibers. *)
let max_pending = 2

let entries : (string, entry) Hashtbl.t = Hashtbl.create 16

(* Module-level singleton table: Stdlib.Mutex because lookup is reachable
   outside an Eio context (test setup) and the critical section never yields. *)
let registry_mu = Stdlib.Mutex.create ()

(* Set once by [init] at startup, before keepers run. Guarded by [registry_mu]
   so a reader sees the write. *)
let executor_sw : Eio.Switch.t option ref = ref None

let init ~sw =
  Stdlib.Mutex.protect registry_mu (fun () -> executor_sw := Some sw)
;;

let current_sw () = Stdlib.Mutex.protect registry_mu (fun () -> !executor_sw)

let entry_for ~base_path ~keeper_name =
  let key = Keeper_registry_types.registry_key ~base_path keeper_name in
  Stdlib.Mutex.protect registry_mu (fun () ->
    match Hashtbl.find_opt entries key with
    | Some e -> e
    | None ->
      let e =
        { mem_mu = Eio.Mutex.create ()
        ; state_mu = Stdlib.Mutex.create ()
        ; pending = 0
        }
      in
      Hashtbl.add entries key e;
      e)
;;

let try_reserve entry =
  Stdlib.Mutex.protect entry.state_mu (fun () ->
    if entry.pending >= max_pending
    then false
    else (
      entry.pending <- entry.pending + 1;
      true))
;;

let release_reservation entry =
  Stdlib.Mutex.protect entry.state_mu (fun () -> entry.pending <- entry.pending - 1)
;;

(* Runs on a forked fiber owned by the executor switch. Holds [mem_mu] across
   [f]. Releases the mutex (only if acquired) and the reservation on every exit,
   including cancellation at shutdown. No exception escapes: a best-effort unit
   must never propagate into the executor switch — that would cancel the
   fleet. *)
let run_unit entry sw f =
  let acquired = ref false in
  (try
     Eio.Mutex.lock entry.mem_mu;
     (* No suspension point between [lock] returning and this assignment, so
        cancellation cannot strand a held mutex with [acquired = false]. *)
     acquired := true;
     Eio_context.with_turn_switch sw f
   with
   | Eio.Cancel.Cancelled _ -> () (* shutdown: silent *)
   | exn ->
     Log.Keeper.warn "memory lane unit failed: %s" (Printexc.to_string exn));
  if !acquired then Eio.Mutex.unlock entry.mem_mu;
  release_reservation entry
;;

let submit ~base_path ~keeper_name f =
  match current_sw () with
  | None ->
    (* Not initialized: run inline. The caller is still inside the per-keeper
       turn lane, so single-fiber-per-keeper memory access is preserved. *)
    f ();
    Ran_inline
  | Some sw ->
    let entry = entry_for ~base_path ~keeper_name in
    if not (try_reserve entry)
    then (
      Otel_metric_store.inc_counter
        Keeper_metrics.(to_string DispatchEventFailures)
        ~labels:[ "keeper", keeper_name; "site", "memory_lane_saturated" ]
        ();
      Log.Keeper.warn ~keeper_name
        "memory lane saturated (pending>=%d): dropping post-turn memory unit"
        max_pending;
      Dropped)
    else (
      Eio.Fiber.fork ~sw (fun () -> run_unit entry sw f);
      Submitted)
;;

module For_testing = struct
  let reset () =
    Stdlib.Mutex.protect registry_mu (fun () ->
      Hashtbl.reset entries;
      executor_sw := None)
  ;;

  let pending ~base_path ~keeper_name =
    let key = Keeper_registry_types.registry_key ~base_path keeper_name in
    Stdlib.Mutex.protect registry_mu (fun () -> Hashtbl.find_opt entries key)
    |> Option.map (fun e -> Stdlib.Mutex.protect e.state_mu (fun () -> e.pending))
  ;;
end
