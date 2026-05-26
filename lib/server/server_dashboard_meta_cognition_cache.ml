(* Meta-cognition summary cache for dashboard shell endpoints.

   Encapsulates one per-config table:
   - [warm_inflight]: dedup table so concurrent shell requests only
     spawn one warming fiber per cache key.

   Pulled out of [Server_dashboard_http_core] to shrink the godfile.
   Side effects are isolated to one Eio mutex + one Hashtbl. *)

let summary_ttl = 120.0

let warm_mu = Eio.Mutex.create ()
let warm_inflight : (string, unit) Hashtbl.t = Hashtbl.create 4

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
