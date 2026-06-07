(** Keeper-turn capacity gate with global + per-keeper limits.

    This is intentionally separate from {!Keeper_turn_holders}: holders are
    diagnostics for turns that are already running, while this module admits or
    rejects new turn bodies.

    Two-tier admission:
    - Global limit ([keeper.turn.capacity_limit], default 32): machine-level
      concurrent turn cap shared across all keepers.
    - Per-keeper limit ([keeper.turn.per_keeper_capacity_limit], default 2):
      prevents a single keeper from monopolising provider capacity.

    Both limits must be satisfied for admission. Rejection records which
    limit was hit so the caller can log the specific bottleneck. *)

type rejection =
  { limit : int
  ; inflight : int
  ; waited_ms : int
  ; per_keeper_limit : int
  ; per_keeper_inflight : int
  }

type acquired =
  { release : unit -> unit
  ; wait_ms : int
  }

let inflight = Atomic.make 0

(** Per-keeper inflight tracking. Thread-safe via atomic per-key counters. *)
module Per_keeper = struct
  let table : (string, int Atomic.t) Hashtbl.t = Hashtbl.create 64

  let get_counter keeper_name =
    match Hashtbl.find_opt table keeper_name with
    | Some counter -> counter
    | None ->
      (* Race-safe: if two fibers create for the same key, both start at 0.
         The second Hashtbl.replace overwrites with an equivalent counter. *)
      let counter = Atomic.make 0 in
      Hashtbl.replace table keeper_name counter;
      counter

  let incr keeper_name =
    let counter = get_counter keeper_name in
    Atomic.incr counter

  let decr keeper_name =
    let counter = get_counter keeper_name in
    let rec loop () =
      let current = Atomic.get counter in
      if current <= 0
      then ()
      else if not (Atomic.compare_and_set counter current (current - 1))
      then loop ()
    in
    loop ()

  let get keeper_name =
    let counter = get_counter keeper_name in
    Atomic.get counter
end

let waited_ms ~started_at =
  let waited_s = Time_compat.now () -. started_at in
  int_of_float ((if waited_s < 0.0 then 0.0 else waited_s) *. 1000.0)
;;

let release_global_capacity () =
  let rec loop () =
    let current = Atomic.get inflight in
    if current <= 0
    then ()
    else if not (Atomic.compare_and_set inflight current (current - 1))
    then loop ()
  in
  loop ()
;;

let acquire_capacity ~keeper_name ~timeout_s =
  let started_at = Time_compat.now () in
  let global_limit = Keeper_config.keeper_turn_capacity_limit () in
  let per_keeper_limit = Keeper_config.keeper_per_keeper_turn_capacity_limit () in
  let rec loop () =
    (* Fast path: both limits disabled *)
    if global_limit <= 0 && per_keeper_limit <= 0
    then Ok { release = (fun () -> ()); wait_ms = waited_ms ~started_at }
    else (
      let global_current = Atomic.get inflight in
      let per_keeper_current = Per_keeper.get keeper_name in
      (* Check per-keeper limit first (cheaper, more specific) *)
      if per_keeper_limit > 0 && per_keeper_current >= per_keeper_limit
      then
        if Time_compat.now () -. started_at >= timeout_s
        then
          Error
            { limit = global_limit
            ; inflight = global_current
            ; waited_ms = waited_ms ~started_at
            ; per_keeper_limit
            ; per_keeper_inflight = per_keeper_current
            }
        else (
          Eio.Fiber.yield ();
          loop ())
      (* Check global limit *)
      else if global_limit > 0 && global_current >= global_limit
      then
        if Time_compat.now () -. started_at >= timeout_s
        then
          Error
            { limit = global_limit
            ; inflight = global_current
            ; waited_ms = waited_ms ~started_at
            ; per_keeper_limit
            ; per_keeper_inflight = per_keeper_current
            }
        else (
          Eio.Fiber.yield ();
          loop ())
      (* Admission: increment both counters *)
      else
        if Atomic.compare_and_set inflight global_current (global_current + 1)
        then (
          Per_keeper.incr keeper_name;
          let released = Atomic.make false in
          Ok
            { release =
                (fun () ->
                   if Atomic.compare_and_set released false true
                   then (
                     release_global_capacity ();
                     Per_keeper.decr keeper_name))
            ; wait_ms = waited_ms ~started_at
            })
        else (
          Eio.Fiber.yield ();
          loop ()))
  in
  loop ()
;;

let with_turn_capacity ?timeout_s ~keeper_name ~channel:_ f =
  let timeout_s =
    match timeout_s with
    | Some value -> value
    | None -> Keeper_runtime_resolved.admission_wait_timeout_sec ()
  in
  match acquire_capacity ~keeper_name ~timeout_s with
  | Error rejection -> Error rejection
  | Ok acquired ->
    Fun.protect
      ~finally:acquired.release
      (fun () -> Ok (f ~capacity_wait_ms:acquired.wait_ms))
;;

let inflight_for_test () = Atomic.get inflight

let per_keeper_inflight_for_test keeper_name = Per_keeper.get keeper_name
