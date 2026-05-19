(** Alive-but-stuck supervisor detector and recovery request. *)

open Keeper_types
open Keeper_supervisor_types

(* Per-keeper dedup table for [scan]. Bounds counter emission to one
   increment per [alive_but_stuck_dedup_ttl_sec] per keeper, even when the
   sweep fires every 30s. *)
let last_alert : (string, float) Hashtbl.t = Hashtbl.create 16
let last_alert_mu = Eio.Mutex.create ()

let should_emit ~now ~dedup_ttl_sec name =
  Eio.Mutex.use_rw ~protect:false last_alert_mu (fun () ->
    match Hashtbl.find_opt last_alert name with
    | Some last_ts when now -. last_ts < dedup_ttl_sec -> false
    | _ ->
      Hashtbl.replace last_alert name now;
      true)
;;

let set_gauges ~(entry : Keeper_registry.registry_entry) ~threshold ~elapsed =
  let labels = [ "keeper_name", entry.name ] in
  Prometheus.set_gauge
    Keeper_metrics.metric_keeper_alive_but_stuck_seconds
    ~labels
    (Option.value elapsed ~default:0.0);
  Prometheus.set_gauge
    Keeper_metrics.metric_keeper_alive_but_stuck_threshold_seconds
    ~labels
    threshold
;;

let recovery_stimulus ~now ~elapsed ~threshold (entry : Keeper_registry.registry_entry)
  : Keeper_event_queue.stimulus
  =
  let payload =
    `Assoc
      [ "source", `String "alive_but_stuck_recovery"
      ; "keeper", `String entry.name
      ; "elapsed_sec", `Float elapsed
      ; "threshold_sec", `Float threshold
      ; "autonomous_turns", `Int entry.meta.runtime.autonomous_turn_count
      ; "proactive_count_total", `Int entry.meta.runtime.proactive_rt.count_total
      ; ( "message"
        , `String
            "supervisor detected a frozen scheduled-autonomous timestamp; run a recovery \
             cycle" )
      ]
    |> Yojson.Safe.to_string
  in
  { Keeper_event_queue.post_id = "alive-but-stuck:" ^ entry.name
  ; urgency = Keeper_event_queue.Immediate
  ; arrived_at = now
  ; payload
  }
;;

let queue_recovery ~base_path ~now ~elapsed ~threshold
      (entry : Keeper_registry.registry_entry)
  =
  if not Env_config.KeeperSupervisor.alive_but_stuck_recovery_enabled
  then "disabled"
  else if entry.phase <> Keeper_state_machine.Running
  then "skipped_not_running"
  else (
    let stimulus = recovery_stimulus ~now ~elapsed ~threshold entry in
    Keeper_registry_event_queue.enqueue ~base_path entry.name stimulus;
    Keeper_registry.wakeup ~base_path entry.name;
    "queued")
;;

let reset_for_test () =
  Eio.Mutex.use_rw ~protect:false last_alert_mu (fun () -> Hashtbl.clear last_alert)
;;

let request_recovery ~base_path ~elapsed (entry : Keeper_registry.registry_entry) =
  let kill_class = Keeper_registry.Idle_turn { stall_seconds = elapsed } in
  let current_entry =
    Keeper_registry.get ~base_path entry.name |> Option.value ~default:entry
  in
  let prior_str =
    Option.map Keeper_registry.failure_reason_to_string current_entry.last_failure_reason
    |> Option.value ~default:"none"
  in
  let reason =
    match current_entry.last_failure_reason with
    | Some
        ( Keeper_registry.Stale_turn_timeout _
        | Keeper_registry.Stale_termination_storm _
        | Keeper_registry.Oas_timeout_budget_loop _ ) as kept -> kept
    | Some (Keeper_registry.Heartbeat_consecutive_failures _)
    | Some (Keeper_registry.Turn_consecutive_failures _)
    | Some (Keeper_registry.Provider_runtime_error _)
    | Some (Keeper_registry.Tool_required_unsatisfied _)
    | Some (Keeper_registry.Ambiguous_partial_commit _)
    | Some (Keeper_registry.Stale_fleet_batch _)
    | Some Keeper_registry.Fiber_unresolved
    | Some (Keeper_registry.Exception _)
    | None -> Some (Keeper_registry.Stale_turn_timeout kill_class)
  in
  Keeper_registry.set_failure_reason ~base_path entry.name reason;
  Atomic.set entry.fiber_stop true;
  Atomic.set entry.fiber_wakeup true;
  Prometheus.inc_counter
    Keeper_metrics.metric_keeper_alive_but_stuck_recovery_requests
    ~labels:[ "keeper", entry.name ]
    ();
  Log.Keeper.error
    "%s: alive-but-stuck recovery requested (elapsed=%.0fs, prior_reason=%s, \
     failure_reason=%s)"
    entry.name
    elapsed
    prior_str
    (Option.map Keeper_registry.failure_reason_to_string reason
     |> Option.value ~default:"unknown")
;;

let request_recovery_for_test = request_recovery

let scan (ctx : _ context) =
  if not Env_config.KeeperSupervisor.alive_but_stuck_enabled
  then ()
  else (
    let now = Time_compat.now () in
    let stall_multiplier = Env_config.KeeperSupervisor.alive_but_stuck_stall_multiplier in
    let dedup_ttl_sec = Env_config.KeeperSupervisor.alive_but_stuck_dedup_ttl_sec in
    let base_path = ctx.config.base_path in
    let entries = Keeper_registry.all ~base_path () in
    let abs_ym = Eio_guard.create_yield_meter () in
    List.iter
      (fun (entry : Keeper_registry.registry_entry) ->
         let stall_floor_sec =
           Env_config.KeeperSupervisor.alive_but_stuck_stall_floor_sec
         in
         let threshold =
           alive_but_stuck_threshold ~stall_multiplier ~stall_floor_sec entry
         in
         let elapsed =
           detect_alive_but_stuck ~now ~stall_multiplier ~stall_floor_sec entry
         in
         set_gauges ~entry ~threshold ~elapsed;
         (match elapsed with
          | None -> ()
          | Some elapsed ->
            if should_emit ~now ~dedup_ttl_sec entry.name
            then (
              let recovery =
                queue_recovery ~base_path ~now ~elapsed ~threshold entry
              in
              Prometheus.inc_counter
                Keeper_metrics.metric_keeper_alive_but_stuck
                ~labels:[ "keeper", entry.name ]
                ();
              Prometheus.inc_counter
                Keeper_metrics.metric_keeper_alive_but_stuck_recovery
                ~labels:[ "keeper", entry.name; "outcome", recovery ]
                ();
              Log.Keeper.warn
                "%s: alive-but-stuck detected (elapsed=%.0fs, threshold=%.0fs, \
                 autonomous_turns=%d, proactive_count_total=%d, recovery=%s)"
                entry.name
                elapsed
                threshold
                entry.meta.runtime.autonomous_turn_count
                entry.meta.runtime.proactive_rt.count_total
                recovery;
              if String.equal recovery "queued"
              then request_recovery ~base_path ~elapsed entry));
         Eio_guard.yield_step abs_ym)
      entries)
;;
