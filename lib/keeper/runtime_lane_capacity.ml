(** Per-runtime-lane capacity gate — fail-fast admission.

    Limits concurrent keeper turns per runtime lane (provider+model binding).
    The lane key is the provider label (e.g. "ollama_cloud"), and the limit
    comes from [Runtime.binding.max_concurrent] in runtime.toml.

    This is the third tier in the 3-tier admission stack:
    - Tier 1: {!Keeper_turn_capacity} — global + per-keeper limits
    - Tier 2 (this module): per-lane limit from binding config
    - Observation: OAS stream_idle_timeout_s — handles stalled streams, not prevention

    Design: fail-fast.  When [max_concurrent] slots are full the gate returns
    [Error] immediately.  The caller (keeper turn driver) decides whether to
    retry, fallback to another runtime, or surface the error to the agent.
    No spin-wait, no timeout — OAS already has its own timeout for the
    provider call itself.

    When [max_concurrent <= 0], the gate is disabled (immediate admission). *)

type rejection =
  { lane_key : string
  ; limit : int
  ; inflight : int
  }

type acquired = { release : unit -> unit }

(** Per-lane inflight counters. Key = provider_label (e.g. "ollama_cloud").
    Thread-safe via atomic per-key counters. *)
module Lane = struct
  let table : (string, int Atomic.t) Hashtbl.t = Hashtbl.create 16

  let get_counter lane_key =
    match Hashtbl.find_opt table lane_key with
    | Some counter -> counter
    | None ->
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

let acquire_lane_capacity ~lane_key ~max_concurrent =
  (* Disabled gate: immediate admission with no-op release. *)
  if max_concurrent <= 0
  then Ok { release = (fun () -> ()) }
  else
    let current = Lane.get lane_key in
    if current >= max_concurrent
    then Error { lane_key; limit = max_concurrent; inflight = current }
    else
      let counter = Lane.get_counter lane_key in
      if Atomic.compare_and_set counter current (current + 1)
      then
        let released = Atomic.make false in
        Ok
          { release =
              (fun () ->
                 if Atomic.compare_and_set released false true
                 then Lane.decr lane_key)
          }
      else
        (* CAS race — one retry with a fresh read, then fail fast. *)
        let current = Lane.get lane_key in
        if current >= max_concurrent
        then Error { lane_key; limit = max_concurrent; inflight = current }
        else if Atomic.compare_and_set counter current (current + 1)
        then
          let released = Atomic.make false in
          Ok
            { release =
                (fun () ->
                   if Atomic.compare_and_set released false true
                   then Lane.decr lane_key)
            }
        else Error { lane_key; limit = max_concurrent; inflight = Lane.get lane_key }
;;

let with_lane_capacity ~lane_key ~max_concurrent f =
  match acquire_lane_capacity ~lane_key ~max_concurrent with
  | Error rejection -> Error rejection
  | Ok acquired ->
    Fun.protect
      ~finally:acquired.release
      (fun () -> Ok (f ()))
;;

let inflight_for_test lane_key = Lane.get lane_key

let reset_for_test () =
  Hashtbl.clear Lane.table
