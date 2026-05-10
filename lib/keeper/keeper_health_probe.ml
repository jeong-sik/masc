(* Asynchronous health probe for condition-based auto-resume.
   See [.mli] for TLA+ modeling notes.

   RFC-0041 Phase B2: migrated from per-cascade (string) cache keys to
   per-keeper, per-item (string * string) keys. The old [is_healthy]
   remains as a backward-compatible alias that checks whether ANY item
   for the keeper is healthy. *)

type health_status =
  | Unknown
  | Healthy
  | Unhealthy of string

(** Per-keeper, per-item health cache.
    Key: (keeper_name, item_id). Value: (status, timestamp). *)
let health_cache : (string * string, health_status * float) Hashtbl.t = Hashtbl.create 16

let health_cache_mu = Eio.Mutex.create ()

(* ------------------------------------------------------------------ *)
(* Per-item health queries                                            *)
(* ------------------------------------------------------------------ *)

(** [is_item_healthy ~keeper_name ~item_id] returns the cached health
    status for the specific keeper+item pair. *)
let is_item_healthy ~keeper_name ~item_id =
  Eio.Mutex.use_ro health_cache_mu (fun () ->
    match Hashtbl.find_opt health_cache (keeper_name, item_id) with
    | Some (Healthy, _) -> true
    | _ -> false)
;;

(** [set_item_health ~keeper_name ~item_id status] updates the cache
    for a specific keeper+item pair. *)
let set_item_health ~keeper_name ~item_id status =
  Eio.Mutex.use_rw ~protect:true health_cache_mu (fun () ->
    Hashtbl.replace health_cache (keeper_name, item_id) (status, Time_compat.now ()))
;;

(** [record_item_result ~keeper_name ~item_id ~success] updates the
    health state based on turn outcome. Success -> Healthy immediately.
    Failure -> Unhealthy (no Degraded intermediate for now). *)
let record_item_result ~keeper_name ~item_id ~success =
  let status = if success then Healthy else Unhealthy "turn_failure" in
  set_item_health ~keeper_name ~item_id status
;;

(* ------------------------------------------------------------------ *)
(* Backward-compatible per-keeper health (deprecated)                 *)
(* ------------------------------------------------------------------ *)

(** [is_healthy ~keeper_name] returns true if ANY item for this keeper
    is Healthy. This is the backward-compatible alias for code that
    hasn't migrated to per-item health checks yet.

    Deprecated: use [is_item_healthy] for RFC-0041 per-item routing. *)
let is_healthy ~keeper_name =
  Eio.Mutex.use_ro health_cache_mu (fun () ->
    let found = ref false in
    Hashtbl.iter
      (fun (kn, _item_id) (status, _ts) ->
         if String.equal kn keeper_name
         then (
           match status with
           | Healthy -> found := true
           | _ -> ()))
      health_cache;
    !found)
;;

let set_health ~keeper_name status =
  Eio.Mutex.use_rw ~protect:true health_cache_mu (fun () ->
    Hashtbl.replace health_cache (keeper_name, "") (status, Time_compat.now ()))
;;

(** [get_cascade_status ~cascade_name] reads the cascade-level entry
    written by [set_health]/[run_once].  Three-valued:
      - [Healthy]    : last probe saw the cascade at < threshold ratio.
      - [Unhealthy r]: last probe saw the cascade at >= threshold ratio.
      - [Unknown]    : probe never wrote this cascade (e.g. boot before
                       first sweep, or no running keepers in the cascade
                       at the time of the last scan). *)
let get_cascade_status ~cascade_name =
  Eio.Mutex.use_ro health_cache_mu (fun () ->
    match Hashtbl.find_opt health_cache (cascade_name, "") with
    | Some (status, _) -> status
    | None -> Unknown)
;;

(* ------------------------------------------------------------------ *)
(* Cascade health check                                               *)
(* ------------------------------------------------------------------ *)

(** [is_terminal_unhealthy phase] returns true only for phases that
    represent unrecoverable or immediately-actionable failure.
    Dead / Zombie / Crashed are terminal unhealthy states.
    All other phases (including Restarting — a keeper mid-recovery)
    are treated as healthy for cascade ratio purposes.

    Extracted as a named function so tests can exercise the
    exhaustive match directly, and so the compiler catches omissions
    when a new phase variant is added. *)
let is_terminal_unhealthy (phase : Keeper_state_machine.phase) =
  match phase with
  | Dead | Zombie | Crashed -> true
  | Offline | Running | Failing | Overflowed | Compacting
  | HandingOff | Draining | Paused | Stopped | Restarting -> false

(** Compute failure ratio per cascade from registry entries.
    Returns (cascade_name, is_healthy) where healthy means
    failure_ratio < 0.10.

    A keeper is counted as "failed" only when its phase is a terminal
    unhealthy state (Dead, Zombie, or Crashed).  Past restarts
    (restart_count > 0) do NOT count — a restarted keeper that is now
    Running is healthy.  Prior to this fix, restart_count was used as
    the proxy, causing permanent cascade pollution after any single
    restart since restart_count is monotonic and never resets.

    Per-item health is updated via [record_item_result] after each
    turn. *)
let check_cascade_health ~base_path =
  let entries = Keeper_registry.all ~base_path () in
  let by_cascade = Hashtbl.create 8 in
  List.iter
    (fun (entry : Keeper_registry.registry_entry) ->
       let cascade = Keeper_types.cascade_name_of_meta entry.meta in
       let total, failed =
         match Hashtbl.find_opt by_cascade cascade with
         | Some pair -> pair
         | None -> 0, 0
       in
       let failed' = if is_terminal_unhealthy entry.phase then failed + 1 else failed in
       Hashtbl.replace by_cascade cascade (total + 1, failed'))
    entries;
  Hashtbl.fold
    (fun cascade (total, failed) acc ->
       let ratio =
         if total <= 0 then 0.0 else float_of_int failed /. float_of_int total
       in
       let healthy = ratio < 0.10 in
       (cascade, healthy) :: acc)
    by_cascade
    []
;;

(* ------------------------------------------------------------------ *)
(* Background probe fiber                                             *)
(* ------------------------------------------------------------------ *)

let run_once ~base_path =
  let results = check_cascade_health ~base_path in
  List.iter
    (fun (cascade, healthy) ->
       let status = if healthy then Healthy else Unhealthy "failure_ratio" in
       (* Cache keyed by cascade name so ResumeFromPause can look it up.
         Uses empty item_id for backward compat. *)
       set_health ~keeper_name:cascade status)
    results
;;

let rec probe_loop ~base_path ~interval_sec () =
  (* Cancel-aware: Safe_ops.protect re-raises Eio.Cancel.Cancelled and swallows
     other exceptions so a transient registry I/O failure cannot kill the fiber
     and freeze [is_healthy] at [false] forever. *)
  Safe_ops.protect ~default:() (fun () -> run_once ~base_path);
  Eio_unix.sleep interval_sec;
  probe_loop ~base_path ~interval_sec ()
;;

let start_probe ~sw ~base_path ~interval_sec =
  if interval_sec <= 0.0
  then ()
  else
    Eio.Fiber.fork ~sw (fun () ->
      Eio.Switch.run (fun _sw -> probe_loop ~base_path ~interval_sec ()))
;;
