(** Keeper_keepalive — keeper heartbeat fiber and board-reactive wakeup.

    Per-keeper lifecycle (start, stop, wakeup) is managed through
    [Keeper_registry] (SSOT).  This module provides the heartbeat loop
    body, board-reactive wakeup filtering, and optional gRPC heartbeat
    fiber.

    [MASC_KEEPER_*] env vars read here (compatibility counters) can also be set in
    [<resolved config root>/runtime.toml].
    See {!Keeper_runtime_config} and [docs/BOOT-ENV-STATE-INVENTORY.md]
    section 1.3.

    Structure (facade decomposition):
    - [Keeper_keepalive_signal] — gRPC client refs, FSM guard identity
                                   helpers, interruptible sleep, wakeup
                                   dispatch, board-reactive wakeup,
                                   stage_timing type, event dispatch
    - [Keeper_heartbeat_snapshot] — heartbeat snapshot write, event
                                     dispatch, stage timing metrics
    - [Keeper_heartbeat_loop]  — [run_keepalive_unified_turn], smart
                                   heartbeat, [run_heartbeat_loop]
    This facade [include]s all three and adds: event bus delegation,
    identity repair, gRPC heartbeat stream, directive processing, and
    keeper lifecycle start/stop. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_meta_store
open Keeper_types_profile
open Keeper_memory
open Keeper_execution
include Keeper_keepalive_signal
include Keeper_heartbeat_snapshot
include Keeper_heartbeat_loop

module StringMap = Set_util.StringMap

(* OAS Event_bus — delegated to Keeper_event_bus to avoid dependency cycles. *)
let set_bus bus = Keeper_event_bus.set bus
let get_bus () = Keeper_event_bus.get ()

(* ── gRPC directive processing ── *)

let keeper_entry_by_identity_opt identity =
  match Keeper_registry_lookup.find_by_agent_name identity with
  | Some entry -> Some entry
  | None ->
    (match Keeper_registry_lookup.find_by_name identity with
     | Some entry -> Some entry
     | None ->
       (match Keeper_identity.canonical_keeper_name_from_agent_name identity with
        | Some keeper_name ->
          (match Keeper_registry_lookup.find_by_name keeper_name with
           | Some entry -> Some entry
           | None -> None)
        | None -> None))
;;

let with_keeper_entry_by_identity ~identity ~on_missing f =
  match keeper_entry_by_identity_opt identity with
  | Some entry -> f entry
  | None -> on_missing ()
;;

let persist_directive_meta_update
      (entry : Keeper_registry.registry_entry)
      ~(updated_meta : keeper_meta)
  : (unit, string) result
  =
  let keeper_filename = entry.name ^ ".json" in
  let masc_root = Workspace_utils.masc_dir_from_base_path ~base_path:entry.base_path in
  let default_path =
    Filename.concat (Filename.concat masc_root "keepers") keeper_filename
  in
  let persisted_path =
    if Fs_compat.file_exists default_path
    then default_path
    else (
      let clusters_dir = Filename.concat masc_root "clusters" in
      let cluster_paths =
        match Safe_ops.list_dir_safe clusters_dir with
        | Ok names ->
          names
          |> List.map (fun cluster_name ->
            Filename.concat
              (Filename.concat (Filename.concat clusters_dir cluster_name) "keepers")
              keeper_filename)
          |> List.filter Fs_compat.file_exists
        | Error _ -> []
      in
      match cluster_paths with
      | [] -> default_path
      | [ path ] -> path
      | paths ->
        let by_mtime_desc a b =
          let a_mtime = Option.value ~default:0.0 (Fs_compat.file_mtime a) in
          let b_mtime = Option.value ~default:0.0 (Fs_compat.file_mtime b) in
          Float.compare b_mtime a_mtime
        in
        (match List.sort by_mtime_desc paths with
         | latest_path :: _ -> latest_path
         | [] -> default_path))
  in
  match Keeper_fs.save_json_atomic persisted_path (Keeper_meta_json.meta_to_json updated_meta) with
  | Ok () ->
    Keeper_registry.update_meta ~base_path:entry.base_path entry.name updated_meta;
    Ok ()
  | Error msg ->
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string WriteMetaFailures)
      ~labels:[ "keeper", entry.name; "site", "directive_persist" ]
      ();
    Log.Keeper.emit
      Log.Warn
      ~category:Log.Heartbeat
      ~details:(`Assoc [ "keeper", `String entry.name; "error", `String msg ])
      (Printf.sprintf "directive meta persist failed for %s: %s" entry.name msg);
    Error msg
;;

let directive_paused_meta (meta : keeper_meta) paused =
  {
    meta with
    paused;
    (* A gRPC pause directive is an operator/control-plane pause; record it
       so the status bridge can name it. Resume/wakeup (paused=false) clears
       the reason together with the pause bit. Observability only — the
       pause/resume decision is carried by [paused] as before. *)
    latched_reason =
      (if paused
       then
         Some
           (Keeper_latched_reason.Operator_paused
              { operator_actor = Keeper_latched_reason.operator_actor_grpc_directive })
       else None);
    runtime = { meta.runtime with last_blocker = None };
    updated_at = now_iso ();
  }
;;

(* Unknown-keeper directives can repeat while boot/crash truth is still
   elsewhere. Keep WARN output low-cardinality; the caller-side
   [DirectiveFailures] counter still records every miss. *)
let not_in_registry_warn_cooldown_s = Masc_time_constants.minute
let not_in_registry_warn_max_entries = 256

type not_in_registry_warn_decision =
  | Warn_unknown_keeper
  | Debug_throttled_unknown_keeper

let not_in_registry_warn_due ?(cooldown_s = not_in_registry_warn_cooldown_s) ~previous ~now () =
  match previous with
  | None -> true
  | Some prev -> now < prev || now -. prev >= cooldown_s
;;

let not_in_registry_warn_prune ?(max_entries = not_in_registry_warn_max_entries)
      ~now last_warns =
  let cutoff = now -. not_in_registry_warn_cooldown_s in
  let recent =
    StringMap.filter (fun _ warned_at -> warned_at >= cutoff || warned_at > now) last_warns
  in
  if StringMap.cardinal recent <= max_entries
  then recent
  else
    let rec take n = function
      | _ when n <= 0 -> []
      | [] -> []
      | x :: xs -> x :: take (n - 1) xs
    in
    let newest =
      recent
      |> StringMap.bindings
      |> List.sort (fun (name_a, ts_a) (name_b, ts_b) ->
      let ts_cmp = Float.compare ts_b ts_a in
      if ts_cmp <> 0 then ts_cmp else String.compare name_a name_b)
      |> take max_entries
    in
    List.fold_left
      (fun acc (name, warned_at) -> StringMap.add name warned_at acc)
      StringMap.empty newest
;;

let not_in_registry_warn_state_step ?max_entries ~agent_name ~now last_warns =
  let last_warns = not_in_registry_warn_prune ?max_entries ~now last_warns in
  let previous = StringMap.find_opt agent_name last_warns in
  let decision, updated =
  if not_in_registry_warn_due ~previous ~now ()
    then Warn_unknown_keeper, StringMap.add agent_name now last_warns
    else Debug_throttled_unknown_keeper, last_warns
  in
  decision, not_in_registry_warn_prune ?max_entries ~now updated
;;

let not_in_registry_last_warn : float StringMap.t Atomic.t =
  Atomic.make StringMap.empty
;;

let not_in_registry_warn_decision ~agent_name ~now =
  let rec loop () =
    let current = Atomic.get not_in_registry_last_warn in
    let decision, updated = not_in_registry_warn_state_step ~agent_name ~now current in
    if updated == current || Atomic.compare_and_set not_in_registry_last_warn current updated
    then decision
    else loop ()
  in
  loop ()
;;

let log_directive_agent_not_in_registry ~agent_name ~action =
  let known_keeper () =
    match Keeper_tool_shared_runtime.find_registry_meta ~keeper_name:agent_name ~source_layer:"directive" with
    | Some _ -> true
    | None ->
      (match Keeper_identity.canonical_keeper_name_from_agent_name agent_name with
       | None -> false
       | Some canonical_name ->
         Option.is_some
           (Keeper_tool_shared_runtime.find_registry_meta
              ~keeper_name:canonical_name
              ~source_layer:"directive"))
  in
  if known_keeper ()
  then
    Log.Keeper.emit
      Log.Debug
      ~category:Log.Directive
      ~details:
        (`Assoc
          [ "agent_name", `String agent_name
          ; "action", `String action
          ; "reason", `String "not_yet_registered"
          ])
      (Printf.sprintf "directive %s: agent %s not yet registered" action agent_name)
  else (
    match not_in_registry_warn_decision ~agent_name ~now:(Time_compat.now ()) with
    | Warn_unknown_keeper ->
      Log.Keeper.emit
        Log.Warn
        ~category:Log.Directive
        ~details:(`Assoc [ "agent_name", `String agent_name; "action", `String action ])
        (Printf.sprintf "directive %s: agent %s not in registry" action agent_name)
    | Debug_throttled_unknown_keeper ->
      Log.Keeper.emit
        Log.Debug
        ~category:Log.Directive
        ~details:
          (`Assoc
            [ "agent_name", `String agent_name
            ; "action", `String action
            ; "reason", `String "not_in_registry_throttled"
            ])
        (Printf.sprintf "directive %s: agent %s not in registry (throttled)" action agent_name)
  )
;;

let set_keeper_paused_state ~agent_name paused =
  with_keeper_entry_by_identity
    ~identity:agent_name
    ~on_missing:(fun () ->
      let action = if paused then "pause" else "resume" in
      Otel_metric_store.inc_counter
        Keeper_metrics.(to_string DirectiveFailures)
        ~labels:[ "keeper", agent_name; "site", "pause_resume_not_in_registry" ]
        ();
      log_directive_agent_not_in_registry ~agent_name ~action)
    (fun entry ->
       let previous_failure_reason = entry.last_failure_reason in
       let updated_meta = directive_paused_meta entry.meta paused in
       (match persist_directive_meta_update entry ~updated_meta with
        | Error err ->
          Keeper_registry.set_failure_reason
            ~base_path:entry.base_path
            entry.name
            previous_failure_reason;
          Otel_metric_store.inc_counter
            Keeper_metrics.(to_string DirectiveFailures)
            ~labels:
              [ "keeper", entry.name; "site", "pause_resume_persist" ]
            ();
          Log.Keeper.error
            "directive %s: meta persist failed for %s: %s"
            (if paused then "pause" else "resume")
            entry.name
            err
        | Ok () ->
          Keeper_registry.dispatch_event_unit
            ~base_path:entry.base_path
            entry.name
            (if paused
             then Keeper_state_machine.Operator_pause
             else Keeper_state_machine.Operator_resume);
          if not paused
          then (
            (* tla-lint: allow-mutation: fiber signal — Atomic flag wakes the keeper from Eio.Promise.await *)
            Atomic.set entry.fiber_wakeup true;
            (* Cycle 43: KeeperHeartbeat.tla WakeupSignal post-condition.
               The [@@fsm_guard] PPX routes the assertion through
               [wrap_unit ~stage:"guard"] automatically. *)
            post_wakeup_signal ~wakeup:entry.fiber_wakeup)))
;;

let wakeup_keeper_by_agent_name ~agent_name =
  with_keeper_entry_by_identity
    ~identity:agent_name
    ~on_missing:(fun () ->
      Otel_metric_store.inc_counter
        Keeper_metrics.(to_string DirectiveFailures)
        ~labels:[ "keeper", agent_name; "site", "wakeup_not_in_registry" ]
        ();
      log_directive_agent_not_in_registry ~agent_name ~action:"wakeup")
    (fun entry -> wakeup_keeper ~base_path:entry.base_path entry.name)
;;

let assign_keeper_task_from_directive ~agent_name ~task_id =
  with_keeper_entry_by_identity
    ~identity:agent_name
    ~on_missing:(fun () ->
      Otel_metric_store.inc_counter
        Keeper_metrics.(to_string DirectiveFailures)
        ~labels:[ "keeper", agent_name; "site", "claim_not_in_registry" ]
        ();
      log_directive_agent_not_in_registry ~agent_name ~action:"claim")
    (fun entry ->
       let task_id_string = Keeper_id.Task_id.to_string task_id in
       let updated_meta =
         { entry.meta with current_task_id = Some task_id; updated_at = now_iso () }
       in
       match persist_directive_meta_update entry ~updated_meta with
       | Error err ->
         Otel_metric_store.inc_counter
           Keeper_metrics.(to_string DirectiveFailures)
           ~labels:[ "keeper", entry.name; "site", "claim_persist" ]
           ();
         Log.Keeper.error
           "task assignment directive: meta persist failed for %s task=%s: %s"
           entry.name
           task_id_string
           err
       | Ok () ->
         (* Cycle 44: KeeperTaskAcquisition.tla SubmitTask post-action
            guard pins that the directive successfully attached the
            [task_id] to the keeper's meta. The [@@fsm_guard] PPX
            routes the assertion through [wrap_unit ~stage:"guard"]
            automatically. *)
         post_submit_task ~meta:updated_meta ~task_id;
         wakeup_keeper ~base_path:entry.base_path entry.name)
;;

(** Apply one typed control-plane directive.  Parsing belongs to the transport
    boundary; this domain path cannot receive an unknown command. *)
let process_directive ~agent_name directive =
  match directive with
  | Keeper_directive.Pause ->
    Log.Keeper.emit
      Log.Info
      ~category:Log.Directive
      ~details:(`Assoc [ "agent_name", `String agent_name; "action", `String "pause" ])
      (Printf.sprintf "directive: pausing keeper %s" agent_name);
    set_keeper_paused_state ~agent_name true
  | Keeper_directive.Resume ->
    Log.Keeper.emit
      Log.Info
      ~category:Log.Directive
      ~details:(`Assoc [ "agent_name", `String agent_name; "action", `String "resume" ])
      (Printf.sprintf "directive: resuming keeper %s" agent_name);
    set_keeper_paused_state ~agent_name false
  | Keeper_directive.Wakeup ->
    (* Dashboard "깨우기" is an explicit operator action and therefore a
       superset of resume: a deliberately paused Keeper re-enters the run loop
       before the wakeup signal is delivered. *)
    let entry_opt = keeper_entry_by_identity_opt agent_name in
    let entry_paused =
      match entry_opt with
      | Some e -> e.meta.paused
      | None ->
        (match Keeper_tool_shared_runtime.find_registry_meta
                 ~keeper_name:agent_name
                 ~source_layer:"keepalive"
         with
         | Some meta -> meta.paused
         | None -> false)
    in
    let prepare_wakeup () = true in
    if entry_paused
    then (
      Log.Keeper.emit
        Log.Info
        ~category:Log.Directive
        ~details:(`Assoc [ "agent_name", `String agent_name; "action", `String "wakeup_resume" ])
        (Printf.sprintf "directive: waking up %s (explicitly resuming paused keeper)" agent_name);
      set_keeper_paused_state ~agent_name false)
    else (
      Log.Keeper.emit
        Log.Debug
        ~category:Log.Directive
        ~details:(`Assoc [ "agent_name", `String agent_name; "action", `String "wakeup" ])
        (Printf.sprintf "directive: waking up %s" agent_name);
      if prepare_wakeup ()
      then wakeup_keeper_by_agent_name ~agent_name)
  | Keeper_directive.Assign_task task_id ->
    let task_id_string = Keeper_id.Task_id.to_string task_id in
    Log.Keeper.emit
      Log.Info
      ~category:Log.Directive
      ~details:
        (`Assoc
          [ "agent_name", `String agent_name
          ; "action", `String "claim"
          ; "task_id", `String task_id_string
          ])
      (Printf.sprintf
         "directive: server assigned task %s to %s"
         task_id_string
         agent_name);
    assign_keeper_task_from_directive ~agent_name ~task_id
;;

(* ── gRPC heartbeat stream ── *)

let reconcile_current_task_id_for_heartbeat ~config ~agent_name =
  try
    Keeper_current_task_reconcile.sync_current_task_id_for_agent_name ~config ~agent_name;
    true
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string ReconcileFailures)
      ~labels:[ "keeper", agent_name; "phase", "grpc_heartbeat" ]
      ();
    Log.Keeper.emit
      Log.Warn
      ~category:Log.Heartbeat
      ~details:
        (`Assoc
          [ "keeper", `String agent_name; "error", `String (Printexc.to_string exn) ])
      (Printf.sprintf
         "gRPC heartbeat: failed to reconcile current_task_id for %s: %s"
         agent_name
         (Printexc.to_string exn));
    false
;;

let registry_current_task_id agent_name =
  match Keeper_registry_lookup.find_by_agent_name agent_name with
  | Some e -> e.meta.current_task_id
  | None -> None
;;

let current_task_id_for_agent ~config agent_name =
  if reconcile_current_task_id_for_heartbeat ~config ~agent_name
  then (
    match registry_current_task_id agent_name with
    | Some task_id -> Keeper_id.Task_id.to_string task_id
    | None -> "")
  else ""
;;

let start_keeper_grpc_heartbeat
      ~(ctx : _ context)
      ~(m : keeper_meta)
      ~(stop : bool Atomic.t)
  : (unit -> unit) option
  =
  grpc_heartbeat_starter ~ctx ~m ~stop
;;
;;

(* ── Lifecycle bootstrap / publish helpers ── *)

let bootstrap_live_keeper_meta ?lifecycle_token ~(ctx : _ context) (m : keeper_meta)
  : keeper_meta
  =
  try
    if not (Workspace_utils.is_initialized ctx.config)
    then (
      let (_init_msg : string) = Workspace.init ctx.config ~agent_name:None in
      ());
    let m =
      match repair_identity_drift_for_keepalive ?lifecycle_token ~ctx m with
      | Some repaired -> repaired
      | None -> m
    in
    let synced = m in
    (* Reset stale timestamp from previous server lifecycle.

       Use [Time_compat.now ()] (not [0.0]). This preserves a sane
       bootstrap timestamp for runtime health surfaces without encoding
       a stale value from a previous server lifecycle. Real turns continue to
       overwrite this with the actual turn time as before.

       Production evidence (2026-04-27): 7 of 11 keepers had
       [last_turn_ts = 0.0] for 50-65 min after server restart with no
       watchdog stall fired despite obvious silence. *)
    let bootstrap_ts = Time_compat.now () in
    let synced =
      { synced with
        runtime =
          { synced.runtime with
            usage = { synced.runtime.usage with last_turn_ts = bootstrap_ts }
          }
      }
    in
    (match lifecycle_token with
     | Some _ ->
       (* The revival coordinator already committed the durable candidate.
          Keep this fresh presence timestamp in the new registry lane; the
          heartbeat persists it after the transaction releases ownership. *)
       ()
     | None ->
       (match
          write_meta_with_merge
            ~merge:Keeper_meta_merge.monotonic_usage_counters
            ctx.config
            synced
        with
        | Ok () -> ()
        | Error e ->
          Otel_metric_store.inc_counter
            Keeper_metrics.(to_string WriteMetaFailures)
            ~labels:[ "keeper", synced.name; "phase", "bootstrap" ]
            ();
          Log.Keeper.emit
            Log.Warn
            ~category:Log.Heartbeat
            ~details:(`Assoc [ "keeper", `String synced.name; "error", `String e ])
            (Printf.sprintf "write_meta failed (bootstrap): %s" e)));
    synced
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string WriteMetaFailures)
      ~labels:[ "keeper", m.name; "phase", "bootstrap-catch" ]
      ();
    Log.Keeper.emit
      Log.Error
      ~category:Log.Heartbeat
      ~details:(`Assoc [ "keeper", `String m.name; "error", `String (Printexc.to_string exn) ])
      (Printf.sprintf "workspace presence bootstrap failed: %s" (Printexc.to_string exn));
    m
;;

(* #8856: hook takes the unified
   [Keeper_lifecycle_events.lifecycle_event] variant. *)
let publish_keeper_lifecycle
      ~(event : Keeper_lifecycle_events.lifecycle_event)
      ~keeper_name
      ~detail
      ()
  : unit
  =
  Keeper_event_publisher.publish_keeper_lifecycle ~event ~keeper_name ~detail ()
;;

(** Phase-event helper: the wire event name IS the phase name. *)
let publish_keeper_phase_lifecycle ~phase ~keeper_name ~detail () : unit =
  publish_keeper_lifecycle
    ~event:(Keeper_lifecycle_events.Phase_event phase)
    ~keeper_name
    ~detail
    ()
;;

let publish_keeper_started ~(live_meta : keeper_meta) : unit =
  publish_keeper_lifecycle
    ~event:
      (Keeper_lifecycle_events.Custom_event
         { verb = Keeper_lifecycle_events.Started
         ; phase = Some Keeper_state_machine.Running
         })
    ~keeper_name:live_meta.name
    ~detail:"keepalive"
    ()
;;

(** Launch gate: dispatch [Fiber_started] before forking the keepalive
    fiber. Returns [Error _] when the registry FSM rejects the launch —
    the caller must not fork and must not announce [Started]/[Running]. *)
let dispatch_fiber_started ?lifecycle_token ?entry ~base_path keeper_name =
  let transition =
    match lifecycle_token, entry with
    | Some token, Some entry ->
      Keeper_registry.prepare_fiber_launch_for_lifecycle token entry
    | None, None -> Keeper_registry.prepare_fiber_launch ~base_path keeper_name
    | Some _, None | None, Some _ ->
      invalid_arg "dispatch_fiber_started lifecycle token and entry must be paired"
  in
  match transition with
  | Ok _ -> Ok ()
  | Error err ->
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string DispatchEventFailures)
      ~labels:[ "keeper", keeper_name; "site", "fiber_started_rejected" ]
      ();
    Log.Keeper.emit
      Log.Warn
      ~category:Log.Fsm
      ~details:
        (`Assoc
          [ "keeper", `String keeper_name
          ; "error", `String (Keeper_state_machine.transition_error_to_string err)
          ])
      (Printf.sprintf
         "keeper %s: Fiber_started rejected during launch — launch aborted: %s"
         keeper_name
         (Keeper_state_machine.transition_error_to_string err));
    Error err
;;

(* ── Registry lifecycle helpers ── *)

let resolve_registry_done
      (entry : Keeper_registry.registry_entry)
      ~source
      (value : [ `Stopped | `Crashed of string ])
  : bool
  =
  match Keeper_registry.resolve_done entry ~source value with
  | Keeper_registry.Done_resolved _ -> true
  | Keeper_registry.Done_already_resolved _ -> false
;;

let dispatch_event_exact_unit
      (entry : Keeper_registry.registry_entry)
      event
  =
  match Keeper_registry.dispatch_event_exact entry event with
  | Ok _ -> true
  | Error error ->
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string DispatchEventFailures)
      ~labels:[ "keeper", entry.name; "site", "exact_lane_terminal" ]
      ();
    Log.Keeper.warn
      "%s: exact-lane terminal dispatch failed event=%s error=%s"
      entry.name
      (Keeper_state_machine.event_to_string event)
      (Keeper_state_machine.transition_error_to_string error);
    false
;;

let record_keeper_stopped
      (entry : Keeper_registry.registry_entry)
      ~base_path:_
      ~keeper_name
      ~detail
  : bool
  =
  if resolve_registry_done entry ~source:"keepalive_record_stopped" `Stopped
  then (
    (match dispatch_event_exact_unit entry Keeper_state_machine.Stop_requested with
     | false -> ()
     | true ->
       (match dispatch_event_exact_unit entry Keeper_state_machine.Drain_complete with
        | true | false -> ()));
    publish_keeper_phase_lifecycle
      ~phase:Keeper_state_machine.Stopped
      ~keeper_name
      ~detail
      ();
    true)
  else false
;;

let record_keeper_crashed
      (entry : Keeper_registry.registry_entry)
      ~base_path:_
      ~keeper_name
      ~failure_reason
  : unit
  =
  let reason = Keeper_registry.failure_reason_to_string failure_reason in
  if resolve_registry_done entry ~source:"keepalive_record_crashed" (`Crashed reason)
  then (
    let outcome = reason in
    ignore
      (Keeper_registry.set_failure_reason_exact entry (Some failure_reason)
       |> Keeper_registry.exact_update_succeeded
            entry
            ~site:"record_keeper_crashed.failure_reason");
    ignore
      (dispatch_event_exact_unit
         entry
         (Keeper_state_machine.Fiber_terminated
            { outcome; provider_id = None; http_status = None }));
    ignore
      (Keeper_registry.record_crash_exact entry (Time_compat.now ()) reason
       |> Keeper_registry.exact_update_succeeded
            entry
            ~site:"record_keeper_crashed.crash_log");
    Keeper_registry_error_recording.record_exact entry reason;
    publish_keeper_phase_lifecycle
      ~phase:Keeper_state_machine.Crashed
      ~keeper_name
      ~detail:reason
      ())
;;

(* ── Keeper lifecycle start/stop ── *)

type start_keepalive_outcome =
  | Keepalive_started of Keeper_registry.registry_entry
  | Keepalive_already_registered of Keeper_registry.registry_entry
  | Keepalive_persistence_denied of Keeper_persistence_admission.block_reason
  | Keepalive_lifecycle_denied of Keeper_lifecycle_admission.autonomous_denial
  | Keepalive_identity_unrepairable
  | Keepalive_registration_rejected of Keeper_registry.registration_error
  | Keepalive_fiber_start_rejected of Keeper_state_machine.transition_error
  | Keepalive_lane_ownership_lost
  | Keepalive_fork_rejected of Keeper_lane.start_error

let start_keepalive_outcome_to_string = function
  | Keepalive_started entry ->
    Printf.sprintf "started lane=%s" (Keeper_lane.Id.to_string (Keeper_lane.id entry.lane))
  | Keepalive_already_registered entry ->
    Printf.sprintf
      "already registered phase=%s lane=%s"
      (Keeper_state_machine.phase_to_string entry.phase)
      (Keeper_lane.Id.to_string (Keeper_lane.id entry.lane))
  | Keepalive_persistence_denied reason ->
    Keeper_persistence_admission.block_reason_to_wire reason
  | Keepalive_lifecycle_denied denial ->
    Keeper_lifecycle_admission.autonomous_denial_to_wire denial
  | Keepalive_identity_unrepairable -> "keeper identity drift could not be repaired"
  | Keepalive_registration_rejected
      (Keeper_registry.Registration_shutdown_reserved operation_id) ->
    Printf.sprintf
      "shutdown operation %s owns keeper admission"
      (Keeper_shutdown_types.Operation_id.to_string operation_id)
  | Keepalive_registration_rejected
      (Keeper_registry.Registration_lifecycle_reserved owner) ->
    Printf.sprintf
      "keeper lifecycle reservation conflict: %s"
      (Keeper_lifecycle_reservation.snapshot_to_string owner)
  | Keepalive_registration_rejected
      (Keeper_registry.Registration_invalid validation_error) ->
    Keeper_registry.registry_entry_validation_error_to_string validation_error
  | Keepalive_registration_rejected
      (Keeper_registry.Registration_event_queue_unavailable { keeper_name; detail }) ->
    Printf.sprintf "event queue unavailable for %s: %s" keeper_name detail
  | Keepalive_fiber_start_rejected error ->
    Printf.sprintf
      "Fiber_started rejected: %s"
      (Keeper_state_machine.transition_error_to_string error)
  | Keepalive_lane_ownership_lost -> "lane ownership lost before fiber fork"
  | Keepalive_fork_rejected error -> Keeper_lane.start_error_to_string error

let record_lifecycle_start_denial
      (meta : keeper_meta)
      (denial : Keeper_lifecycle_admission.autonomous_denial)
  =
  let reason = Keeper_lifecycle_admission.autonomous_denial_to_wire denial in
  Otel_metric_store.inc_counter
    Keeper_metrics.(to_string LifecycleDispatchRejections)
    ~labels:
      [ "keeper", meta.name
      ; "event", "autonomous_keepalive_start"
      ; "reason", reason
      ]
    ();
  publish_keeper_lifecycle
    ~event:
      (Keeper_lifecycle_events.Custom_event
         { verb = Keeper_lifecycle_events.Admission_denied
         ; phase = Some Keeper_state_machine.Offline
         })
    ~keeper_name:meta.name
    ~detail:reason
    ();
  Log.Keeper.emit
    Log.Info
    ~category:Log.Heartbeat
    ~details:
      (`Assoc
        [ "keeper", `String meta.name
        ; "reason", `String reason
        ; "lifecycle_state"
        , `String
            (Keeper_lifecycle_admission.state_to_wire
               (Keeper_lifecycle_admission.state
                  ~paused:meta.paused
                  ~latched_reason:meta.latched_reason))
        ])
    (Printf.sprintf
       "start_keepalive denied for %s by lifecycle admission: %s"
       meta.name
       reason)
;;

let start_keepalive
      ?(proactive_warmup_sec = 0)
      ?lifecycle_token
      (ctx : _ context)
  (m : keeper_meta)
  : start_keepalive_outcome
  =
  match
    Keeper_persistence_admission.block_reason
      ~base_path:ctx.config.base_path
      ~keeper_name:m.name
  with
  | Some reason ->
    let reason_label = Keeper_persistence_admission.block_reason_to_wire reason in
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string LifecycleDispatchRejections)
      ~labels:
        [ "keeper", m.name
        ; "event", "autonomous_keepalive_start"
        ; "reason", reason_label
        ]
      ();
    publish_keeper_lifecycle
      ~event:
        (Keeper_lifecycle_events.Custom_event
           { verb = Keeper_lifecycle_events.Admission_denied
           ; phase = Some Keeper_state_machine.Offline
           })
      ~keeper_name:m.name
      ~detail:reason_label
      ();
    Log.Keeper.error
      "start_keepalive denied for %s by startup persistence admission: %s"
      m.name
      reason_label;
    Keepalive_persistence_denied reason
  | None ->
  let lifecycle_state =
    Keeper_lifecycle_admission.state
      ~paused:m.paused
      ~latched_reason:m.latched_reason
  in
  match Keeper_lifecycle_admission.admit_autonomous lifecycle_state with
  | Keeper_lifecycle_admission.Autonomous_denied denial ->
    record_lifecycle_start_denial m denial;
    Keepalive_lifecycle_denied denial
  | Keeper_lifecycle_admission.Autonomous_admitted ->
  match repair_identity_drift_for_keepalive ?lifecycle_token ~ctx m with
  | None ->
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string HeartbeatFailures)
      ~labels:[ "keeper", m.name; "phase", "identity_drift_unrepairable" ]
      ();
    Log.Keeper.emit
      Log.Error
      ~category:Log.Heartbeat
      ~details:(`Assoc [ "keeper", `String m.name; "reason", `String "identity_drift_unrepairable" ])
      (Printf.sprintf "start_keepalive skipped %s: identity drift could not be repaired" m.name);
    Keepalive_identity_unrepairable
  | Some m ->
    let existing_entry =
      Keeper_registry.get ~base_path:ctx.config.base_path m.name
    in
    let reclaimable_stale_entry (entry : Keeper_registry.registry_entry) =
      let finished =
        Option.is_some (Eio.Promise.peek entry.done_p)
        && Keeper_registry.lane_has_exited entry
      in
      match entry.phase with
      | Keeper_state_machine.Stopped -> finished
      | Keeper_state_machine.Failing
      | Keeper_state_machine.Overflowed
      | Keeper_state_machine.Compacting
      | Keeper_state_machine.HandingOff
      | Keeper_state_machine.Draining
      | Keeper_state_machine.Crashed
      | Keeper_state_machine.Dead -> finished
      | Keeper_state_machine.Running
      | Keeper_state_machine.Paused
      | Keeper_state_machine.Restarting
      | Keeper_state_machine.Offline -> false
    in
    (match existing_entry with
     | Some entry when reclaimable_stale_entry entry ->
       Log.Keeper.emit
         Log.Info
         ~category:Log.Heartbeat
         ~details:
           (`Assoc
             [ "keeper", `String m.name
             ; "phase", `String (Keeper_state_machine.phase_to_string entry.phase)
             ])
         (Printf.sprintf
            "start_keepalive: reclaiming stale registered entry %s phase=%s"
            m.name
            (Keeper_state_machine.phase_to_string entry.phase));
       (match
          match lifecycle_token with
          | None -> Keeper_registry.unregister_exact entry
          | Some token -> Keeper_registry.unregister_exact_for_lifecycle token entry
        with
        | Keeper_registry.Exact_unregistered
        | Keeper_registry.Exact_entry_missing -> ()
        | Keeper_registry.Exact_entry_replaced ->
          Log.Keeper.info
            "start_keepalive: stale entry for %s was already replaced; keeping the newer lane"
            m.name
        | Keeper_registry.Exact_unregister_lifecycle_reserved owner ->
          Log.Keeper.warn
            "start_keepalive: stale entry reclaim rejected by lifecycle reservation for %s: %s"
            m.name
            (Keeper_lifecycle_reservation.snapshot_to_string owner))
     | _ -> ());
    match Keeper_registry.get ~base_path:ctx.config.base_path m.name with
    | Some registered ->
      Log.Keeper.emit
        Log.Info
        ~category:Log.Heartbeat
        ~details:(`Assoc [ "keeper", `String m.name ])
        (Printf.sprintf "start_keepalive: skipped %s (already registered)" m.name);
      Keepalive_already_registered registered
    | None ->
      (* Register in Keeper_registry first — single source of truth. *)
      (match
         match lifecycle_token with
         | None ->
           Keeper_registry.register_offline_if_admitted
             ~base_path:ctx.config.base_path
             m.name
             m
         | Some token ->
           Keeper_registry.register_offline_if_admitted_for_lifecycle
             token
             ~base_path:ctx.config.base_path
             m.name
             m
       with
       | Error (Keeper_registry.Registration_shutdown_reserved operation_id) ->
         Log.Keeper.info
           "start_keepalive: skipped %s because shutdown operation %s owns admission"
           m.name
           (Keeper_shutdown_types.Operation_id.to_string operation_id);
         Keepalive_registration_rejected
           (Keeper_registry.Registration_shutdown_reserved operation_id)
       | Error (Keeper_registry.Registration_lifecycle_reserved owner) ->
         Log.Keeper.warn
           "start_keepalive: lifecycle reservation rejected %s: %s"
           m.name
           (Keeper_lifecycle_reservation.snapshot_to_string owner);
         Keepalive_registration_rejected
           (Keeper_registry.Registration_lifecycle_reserved owner)
       | Error (Keeper_registry.Registration_invalid validation_error) ->
         Log.Keeper.error
           "start_keepalive: registry validation rejected %s: %s"
           m.name
           (Keeper_registry.registry_entry_validation_error_to_string validation_error);
         Keepalive_registration_rejected
           (Keeper_registry.Registration_invalid validation_error)
       | Error (Keeper_registry.Registration_event_queue_unavailable { keeper_name; detail }) ->
         Log.Keeper.error
           "start_keepalive: registry event queue unavailable keeper=%s: %s"
           keeper_name
           detail;
         Keepalive_registration_rejected
           (Keeper_registry.Registration_event_queue_unavailable
              { keeper_name; detail })
       | Ok reg ->
      (* Restore persisted tool usage stats from previous session *)
      Keeper_registry_tool_usage_persistence.restore ~base_path:ctx.config.base_path m.name;
      (* Launch gate FIRST: every launch side effect (gRPC heartbeat fiber,
         grpc_close registration, live-meta bootstrap/update) must come after
         the registry FSM accepts [Fiber_started]. Starting the sidecar
         heartbeat before the gate left a live gRPC resource behind a
         rejected launch — the same half-commit class this change removes
         from the fiber-fork path. *)
      match
        match lifecycle_token with
        | None ->
          dispatch_fiber_started ~base_path:ctx.config.base_path m.name
        | Some token ->
          dispatch_fiber_started
            ~lifecycle_token:token
            ~entry:reg
            ~base_path:ctx.config.base_path
            m.name
      with
      | Error err ->
        (* Fail closed: the registry FSM refused [Fiber_started], so no
           keepalive fiber may fork and [Started]/[Running] must not be
           announced. Resolve the fresh entry through the crash path so the
           supervisor sweep observes a typed outcome and re-queues with the
           usual lane-local backoff instead of leaving a never-resolved entry. *)
        let reason =
          Printf.sprintf
            "fiber_start_rejected: %s"
            (Keeper_state_machine.transition_error_to_string err)
        in
        Keeper_registry.set_failure_reason
          ~base_path:ctx.config.base_path
          m.name
          (Some (Keeper_registry.Exception reason));
        Keeper_registry.record_crash
          ~base_path:ctx.config.base_path
          m.name
          (Time_compat.now ())
          reason;
        Keeper_registry_error_recording.record
          ~base_path:ctx.config.base_path
          m.name
          reason;
        if resolve_registry_done reg ~source:"keepalive_launch_rejected" (`Crashed reason)
        then
          publish_keeper_phase_lifecycle
            ~phase:Keeper_state_machine.Crashed
            ~keeper_name:m.name
            ~detail:reason
            ();
        (match Keeper_lane.reject_before_start reg.lane ~reason:(Failure reason) with
         | Ok () -> ()
         | Error lane_error ->
           Log.Keeper.error
             "%s: rejected launch could not close lane join contract: %s"
             m.name
             (Keeper_lane.start_error_to_string lane_error));
        Keepalive_fiber_start_rejected err
      | Ok () ->
        let stop = reg.fiber_stop in
        let wakeup = reg.fiber_wakeup in
        let live_meta = bootstrap_live_keeper_meta ?lifecycle_token ~ctx m in
        let live_meta_installed =
          (match lifecycle_token with
           | None ->
             Keeper_registry.update_entry_exact reg (fun current ->
               { current with meta = live_meta })
           | Some token ->
             Keeper_registry.update_entry_exact_for_lifecycle token reg (fun current ->
               { current with meta = live_meta }))
          |> Keeper_registry.exact_update_succeeded reg ~site:"start_keepalive.live_meta"
        in
        if not live_meta_installed
        then (
          let failure_reason = Keeper_registry.Exception "lane_ownership_lost_before_fork" in
          record_keeper_crashed
            reg
            ~base_path:ctx.config.base_path
            ~keeper_name:live_meta.name
            ~failure_reason;
          (match
            Keeper_lane.reject_before_start
              reg.lane
              ~reason:(Failure "lane ownership lost before fork")
          with
          | Ok () -> ()
          | Error error ->
            Log.Keeper.warn
              "%s: failed to close rejected stale lane: %s"
              live_meta.name
              (Keeper_lane.start_error_to_string error));
          Keepalive_lane_ownership_lost)
        else (
        (* Telemetry feedback refresh loop removed in #6814:
         behavioral_stats no longer consumed by build_prompt. *)
        let current_failure_reason () =
          match Keeper_registry.get ~base_path:ctx.config.base_path live_meta.name with
          | Some current
            when Keeper_lane.Id.equal
                   (Keeper_lane.id current.lane)
                   (Keeper_lane.id reg.lane) ->
            current.last_failure_reason
          | Some _ | None -> None
        in
        let record_crash failure_reason =
          record_keeper_crashed
            reg
            ~base_path:ctx.config.base_path
            ~keeper_name:live_meta.name
            ~failure_reason
        in
        let record_stopped detail =
          ignore
            (record_keeper_stopped
               reg
               ~base_path:ctx.config.base_path
               ~keeper_name:live_meta.name
               ~detail)
        in
        let record_completed_lane () =
          record_stopped (if Atomic.get stop then "manual stop" else "normal exit")
        in
        let terminalize_lane = function
          | Keeper_lane.Completed -> record_completed_lane ()
          | Keeper_lane.Shutdown_before_start ->
            record_stopped "shutdown requested before lane start"
          | Keeper_lane.Shutdown_requested -> record_stopped "shutdown requested"
          | Keeper_lane.Cancelled_by_parent _ ->
            if Atomic.get stop || Shutdown.is_shutting_down_global ()
            then record_stopped "cancelled during shutdown"
            else
              record_crash
                (Keeper_registry.Fiber_unresolved Keeper_registry.Cancelled_by_parent)
          | Keeper_lane.Failed Keeper_registry.Keeper_fiber_crash ->
            (match current_failure_reason () with
             | Some reason -> record_crash reason
             | None when Atomic.get stop -> record_stopped "manual stop"
             | None -> record_crash (Keeper_registry.Exception "fiber_crash"))
          | Keeper_lane.Failed exn ->
            if Atomic.get stop
            then record_stopped "manual stop"
            else (
              Otel_metric_store.inc_counter
                Keeper_metrics.(to_string HeartbeatFailures)
                ~labels:[ "keeper", live_meta.name; "phase", "lane_crash" ]
                ();
              Log.Keeper.emit
                Log.Error
                ~category:Log.Heartbeat
                ~details:
                  (`Assoc
                    [ "keeper", `String live_meta.name
                    ; "error", `String (Printexc.to_string exn)
                    ])
                (Printf.sprintf
                   "keeper lane for %s crashed: %s"
                   live_meta.name
                   (Printexc.to_string exn));
              record_crash (Keeper_registry.Exception (Printexc.to_string exn)))
        in
        (* Lane cleanup is declared outside [run] because [Keeper_lane.fork]
           invokes it only after the run scope and all child fibers join. *)
        let cleanup_tracking outcome =
          let terminal_result =
            try
              terminalize_lane outcome;
              Ok ()
            with
            | exn -> Error (Printexc.to_string exn)
          in
          let tracking_result =
          try
            (match Keeper_registry.cleanup_tracking_exact reg with
             | Keeper_registry.Exact_updated
             | Keeper_registry.Exact_update_missing -> Ok ()
             | Keeper_registry.Exact_update_replaced ->
               Log.Keeper.info
                 "%s: lane cleanup retained newer same-name registry entry"
                 live_meta.name;
               Ok ()
             | Keeper_registry.Exact_update_invalid validation_error ->
               Error
                 (Keeper_registry.registry_entry_validation_error_to_string
                    validation_error))
          with
          | Eio.Cancel.Cancelled _ as exn -> Error (Printexc.to_string exn)
          | e ->
            let detail = Printexc.to_string e in
            Otel_metric_store.inc_counter
              Keeper_metrics.(to_string CleanupTrackingFailures)
              ~labels:[ "keeper", live_meta.name; "site", "heartbeat_finally" ]
              ();
            Log.Keeper.emit
              Log.Warn
              ~category:Log.Heartbeat
              ~details:
                (`Assoc
                  [ "keeper", `String live_meta.name
                  ; "error", `String detail
                  ])
              (Printf.sprintf
                 "%s: cleanup_tracking in heartbeat finally raised: %s"
                 live_meta.name
                 detail);
            Error detail
          in
          match terminal_result, tracking_result with
          | Ok (), Ok () -> Ok ()
          | Error detail, Ok () | Ok (), Error detail -> Error detail
          | Error terminal_detail, Error tracking_detail ->
            Error
              (Printf.sprintf
                 "terminal cleanup failed: %s; tracking cleanup failed: %s"
                 terminal_detail
                 tracking_detail)
        in
        publish_keeper_started ~live_meta;
        (match
           Keeper_lane.fork
             ~sw:ctx.sw
             reg.lane
             ~run:(fun lane_sw ->
        let ctx = { ctx with sw = lane_sw } in
        (* The sidecar is part of this Keeper lane. It cannot outlive the
           lane's structured-concurrency scope. *)
        let grpc_close = start_keeper_grpc_heartbeat ~ctx ~m ~stop in
        (match grpc_close with
         | Some _ ->
           Atomic.set reg.grpc_close grpc_close
         | None -> ());
        run_heartbeat_loop ~proactive_warmup_sec ctx live_meta stop ~wakeup)
             ~cleanup:cleanup_tracking
         with
         | Ok () -> Keepalive_started reg
         | Error error ->
           let detail = Keeper_lane.start_error_to_string error in
           record_keeper_crashed
             reg
             ~base_path:ctx.config.base_path
             ~keeper_name:live_meta.name
             ~failure_reason:(Keeper_registry.Exception detail);
           Keepalive_fork_rejected error))
        )
;;

type joined_stop =
  { lane_exit : Keeper_lane.exit
  ; terminal : Keeper_registry.done_resolution
  }

type joined_stop_result =
  | Keeper_not_registered
  | Keeper_joined of joined_stop

let request_entry_stop (entry : Keeper_registry.registry_entry) =
       (* tla-lint: allow-mutation: fiber signal — stop+wakeup pair triggers cooperative shutdown *)
       Atomic.set entry.fiber_stop true;
       Atomic.set entry.fiber_wakeup true;
       (* Cycle 43: KeeperHeartbeat.tla WakeupSignal post-condition fires
          even on stop_keepalive — the wakeup atomic must be observable
          as TRUE before the heartbeat fiber consumes its termination
          signal. *)
       post_wakeup_signal ~wakeup:entry.fiber_wakeup;
       (match Atomic.get entry.grpc_close with
        | Some close_fn ->
          (try close_fn () with
           | Eio.Cancel.Cancelled _ as e -> raise e
           | _exn ->
             Otel_metric_store.inc_counter
               "masc_keeper_grpc_close_failures"
               ~labels:[ "keeper", entry.meta.name ]
               ())
        | None -> ())
;;

let stop_keepalive ?base_path name =
  Keeper_registry.all ?base_path ()
  |> List.filter (fun (entry : Keeper_registry.registry_entry) ->
    String.equal entry.name name)
  |> List.iter request_entry_stop
;;

let stop_keepalive_and_await ~base_path name =
  match Keeper_registry.get ~base_path name with
  | None -> Keeper_not_registered
  | Some entry ->
    request_entry_stop entry;
    let lane_exit = Keeper_lane.await_exit entry.lane in
    let terminal = Eio.Promise.await entry.done_p in
    Keeper_joined { lane_exit; terminal }
;;

(** Stop all running keepers. Used in test cleanup to prevent orphaned
    keepalive loops from blocking process exit. *)
let stop_all_keepalives () =
  Keeper_registry.all ()
  |> List.iter (fun (entry : Keeper_registry.registry_entry) -> stop_keepalive entry.name)
;;
