(** Process-local sticky candidate preference for runtime lane failover.

    See the [.mli] for the contract.  Implementation notes:

    - State is a small [Hashtbl] guarded by [Stdlib.Mutex], matching the
      {!Dashboard_oas_bridge} convention in this library (record/read may be
      called from outside Eio fibers, so [Eio.Mutex] is not required).
    - Expiry is lazy: [prefer_order] compares the entry age against
      {!ttl_s} at call time and drops stale entries on read. *)

type entry =
  { candidate : string
  ; noted_at : float
  }

let entries : (string, entry) Hashtbl.t = Hashtbl.create 8
let mu = Stdlib.Mutex.create ()

let ttl_s = Env_config_runtime.Lane.preference_ttl_s

(* NDT-OK: the wall clock is the explicit time boundary for TTL expiry; no
   deterministic replay logic branches on these timestamps. *)
let now () = Unix.gettimeofday ()

let prefer_order ~lane_id candidates =
  let preferred =
    Stdlib.Mutex.protect mu (fun () ->
      match Hashtbl.find_opt entries lane_id with
      | None -> None
      | Some entry ->
        if Float.compare (now () -. entry.noted_at) (ttl_s ()) < 0
        then Some entry.candidate
        else begin
          Hashtbl.remove entries lane_id;
          None
        end)
  in
  match preferred with
  | Some candidate when List.exists (String.equal candidate) candidates ->
    candidate :: List.filter (fun id -> not (String.equal id candidate)) candidates
  | _ -> candidates

let note_success ~lane_id ~candidate =
  Stdlib.Mutex.protect mu (fun () ->
    Hashtbl.replace entries lane_id { candidate; noted_at = now () })

let reset_for_testing () =
  Stdlib.Mutex.protect mu (fun () -> Hashtbl.reset entries)
