(** Per-runtime-lane capacity gate.

    Limits concurrent keeper turns per runtime lane (provider+model binding).
    The lane key is the provider label (e.g. "ollama_cloud"), and the limit
    comes from [Runtime.binding.max_concurrent] in runtime.toml.

    This is the third tier in the 3-tier admission stack:
    - Tier 1: {!Keeper_turn_capacity} — global + per-keeper limits
    - Tier 2 (this module): per-lane limit from binding config
    - Observation: {!Keeper_attempt_liveness} — kill stalled streams, not prevention

    The lane gate sits between the per-keeper gate and the liveness observer
    in the dispatch chain:
    {[
      keeper_heartbeat_loop
        → Keeper_turn_capacity.with_turn_capacity (global + per-keeper)
          → keeper_turn_driver.run_named
            → Runtime_lane_capacity.with_lane_capacity (this module)
              → with_liveness_attempt (observation/kill)
                → provider stream
    ]}

    When [max_concurrent <= 0], the gate is disabled (immediate admission).

    Config source: runtime.toml [binding].max-concurrent, e.g.
    {[
      [ollama_cloud.deepseek-v4-flash]
      max-concurrent = 8
    ]} *)

type rejection =
  { lane_key : string
  ; limit : int
  ; inflight : int
  ; waited_ms : int
  }

type acquired =
  { release : unit -> unit
  ; wait_ms : int
  }

(** Per-lane inflight counters. Key = provider_label (e.g. "ollama_cloud").
    Thread-safe via atomic per-key counters. *)
module Lane = struct
  let table : (string, int Atomic.t) Hashtbl.t = Hashtbl.create 16

  let get_counter lane_key =
    match Hashtbl.find_opt table lane_key with
    | Some counter -> counter
    | None ->
      (* Race-safe: if two fibers create for the same key, both start at 0.
         The second Hashtbl.replace overwrites with an equivalent counter. *)
      let counter = Atomic.make 0 in
      Hashtbl.replace table lane_key counter;
      counter

  let incr lane_key =
    let counter = get_counter lane_key in
    Atomic.incr counter

  let decr lane_key =
    let counter = get_counter lane_key in
    let rec loop () =
      let current = Atomic.get counter in
      if current <= 0
      then ()
      else if not (Atomic.compare_and_set counter current (current - 1))
      then loop ()
    in
    loop ()

  let get lane_key =
    let counter = get_counter lane_key in
    Atomic.get counter
end

let waited_ms ~started_at =
  let waited_s = Time_compat.now () -. started_at in
  int_of_float ((if waited_s < 0.0 then 0.0 else waited_s) *. 1000.0)
;;

let acquire_lane_capacity ~lane_key ~max_concurrent ~timeout_s =
  (* Disabled gate: immediate admission with no-op release. *)
  if max_concurrent <= 0
  then Ok { release = (fun () -> ()); wait_ms = 0 }
  else
    let started_at = Time_compat.now () in
    let rec loop () =
      let current = Lane.get lane_key in
      if current >= max_concurrent
      then
        if Time_compat.now () -. started_at >= timeout_s
        then
          Error
            { lane_key
            ; limit = max_concurrent
            ; inflight = current
            ; waited_ms = waited_ms ~started_at
            }
        else (
          Eio.Fiber.yield ();
          loop ())
      else
        (* CAS: only admit if our stale read hasn't been overtaken. *)
        let counter = Lane.get_counter lane_key in
        if Atomic.compare_and_set counter current (current + 1)
        then
          let released = Atomic.make false in
          Ok
            { release =
                (fun () ->
                   if Atomic.compare_and_set released false true
                   then Lane.decr lane_key)
            ; wait_ms = waited_ms ~started_at
            }
        else (
          Eio.Fiber.yield ();
          loop ())
    in
    loop ()
;;

let with_lane_capacity ?timeout_s ~lane_key ~max_concurrent f =
  let timeout_s =
    match timeout_s with
    | Some value -> value
    | None -> Keeper_runtime_resolved.admission_wait_timeout_sec ()
  in
  match acquire_lane_capacity ~lane_key ~max_concurrent ~timeout_s with
  | Error rejection -> Error rejection
  | Ok acquired ->
    Fun.protect
      ~finally:acquired.release
      (fun () -> Ok (f ~capacity_wait_ms:acquired.wait_ms))
;;

let inflight_for_test lane_key = Lane.get lane_key

let reset_for_test () =
  Hashtbl.clear Lane.table
