(* Meta-cognition summary cache for dashboard shell endpoints.

   Encapsulates two parallel per-config tables:
   - [warm_inflight]: dedup table so concurrent shell requests only
     spawn one warming fiber per cache key.
   - [last_good]: most recent successful summary, used as a fallback
     while the warm fiber is in flight (avoid `Null surface).

   Pulled out of [Server_dashboard_http_core] to shrink the godfile.
   Side effects are isolated to two Eio mutexes + two Hashtbls. *)

let summary_ttl = 120.0
let summary_stale_for = summary_ttl *. 3.0

let summary_empty_json =
  `Assoc
    [ "stagnation_score", `Float 0.0
    ; "belief_count", `Int 0
    ; "contested_belief_count", `Int 0
    ; "dominant_belief", `Null
    ; "top_tension", `Null
    ; "top_desire", `Null
    ]
;;

let warm_mu = Eio.Mutex.create ()
let warm_inflight : (string, unit) Hashtbl.t = Hashtbl.create 4
let last_good_mu = Eio.Mutex.create ()
let last_good : (string, Yojson.Safe.t) Hashtbl.t = Hashtbl.create 4

let store_last_good key json =
  Eio_guard.with_mutex last_good_mu (fun () -> Hashtbl.replace last_good key json)
;;

let find_last_good key =
  Eio_guard.with_mutex last_good_mu (fun () -> Hashtbl.find_opt last_good key)
;;

let clear_warm_flag key =
  Eio_guard.with_mutex warm_mu (fun () -> Hashtbl.remove warm_inflight key)
;;

(** Claim the warm slot for [key]. Returns [true] when this caller acquired
    the slot (and is responsible for the subsequent [clear_warm_flag] call);
    returns [false] when another caller is already warming the same key. *)
let try_acquire_warm_slot key =
  Eio_guard.with_mutex warm_mu (fun () ->
    if Hashtbl.mem warm_inflight key
    then false
    else (
      Hashtbl.replace warm_inflight key ();
      true))
;;
