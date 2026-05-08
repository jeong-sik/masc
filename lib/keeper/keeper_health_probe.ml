(* Asynchronous health probe for condition-based auto-resume.
   See [.mli] for TLA+ modeling notes. *)

type health_status =
  | Unknown
  | Healthy
  | Unhealthy of string

let health_cache : (string, health_status * float) Hashtbl.t =
  Hashtbl.create 16

let health_cache_mu = Eio.Mutex.create ()

let is_healthy ~keeper_name =
  Eio.Mutex.use_ro health_cache_mu (fun () ->
    match Hashtbl.find_opt health_cache keeper_name with
    | Some (Healthy, _) -> true
    | _ -> false)

let set_health ~keeper_name status =
  Eio.Mutex.use_rw ~protect:true health_cache_mu (fun () ->
    Hashtbl.replace health_cache keeper_name
      (status, Time_compat.now ()))

(* ------------------------------------------------------------------ *)
(* Cascade health check                                               *)

(** Compute failure ratio per cascade from registry entries.
    Returns (cascade_name, is_healthy) where healthy means
    failure_ratio < 0.10.  The threshold is hard-coded as a stub;
    production tuning will replace it with a configurable value. *)
let check_cascade_health ~base_path =
  let entries = Keeper_registry.all ~base_path () in
  let by_cascade = Hashtbl.create 8 in
  List.iter
    (fun (entry : Keeper_registry.registry_entry) ->
      let cascade = entry.meta.cascade_name in
      let (total, failed) =
        match Hashtbl.find_opt by_cascade cascade with
        | Some pair -> pair
        | None -> (0, 0)
      in
      let failed' =
        if entry.restart_count > 0 then failed + 1 else failed
      in
      Hashtbl.replace by_cascade cascade (total + 1, failed'))
    entries;
  Hashtbl.fold
    (fun cascade (total, failed) acc ->
      let ratio =
        if total <= 0 then 0.0
        else float_of_int failed /. float_of_int total
      in
      let healthy = ratio < 0.10 in
      (cascade, healthy) :: acc)
    by_cascade []

(* ------------------------------------------------------------------ *)
(* Background probe fiber                                             *)

let run_once ~base_path =
  let results = check_cascade_health ~base_path in
  List.iter
    (fun (cascade, healthy) ->
      let status = if healthy then Healthy else Unhealthy "failure_ratio" in
      (* Cache keyed by cascade name so ResumeFromPause can look it up. *)
      set_health ~keeper_name:cascade status)
    results

let rec probe_loop ~base_path ~interval_sec () =
  (* Cancel-aware: Safe_ops.protect re-raises Eio.Cancel.Cancelled and swallows
     other exceptions so a transient registry I/O failure cannot kill the fiber
     and freeze [is_healthy] at [false] forever. *)
  Safe_ops.protect ~default:() (fun () -> run_once ~base_path);
  Eio_unix.sleep interval_sec;
  probe_loop ~base_path ~interval_sec ()

let start_probe ~sw ~base_path ~interval_sec =
  if interval_sec <= 0.0 then ()
  else
    Eio.Fiber.fork ~sw (fun () ->
      Eio.Switch.run (fun _sw ->
        probe_loop ~base_path ~interval_sec ()))
