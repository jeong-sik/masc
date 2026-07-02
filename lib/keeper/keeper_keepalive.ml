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
    auto_resume_after_sec = None;
    runtime = { meta.runtime with last_blocker = None };
    updated_at = now_iso ();
  }
;;

let clear_no_progress_loop_for_operator_resume (entry : Keeper_registry.registry_entry) =
  let previous_failure_reason = entry.last_failure_reason in
  match
    Keeper_unified_turn_no_progress.clear_for_operator_resume
      ~base_path:entry.base_path
      entry.meta
  with
  | Error _ as err -> err
  | Ok updated_meta ->
    if updated_meta == entry.meta then Ok updated_meta
    else (
      match persist_directive_meta_update entry ~updated_meta with
      | Ok () -> Ok updated_meta
      | Error msg ->
        (* RFC-0303 Phase 3: restore the prior failure_reason on persist failure.
           The no-progress detector re-latch that used to run here is gone with
           the retired detector. *)
        Keeper_registry.set_failure_reason
          ~base_path:entry.base_path
          entry.name
          previous_failure_reason;
        Error msg)
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
       (* On resume, dropping the no-progress recovery stimulus is a cosmetic
          cleanup that must NOT gate the authoritative unpause. A disk failure in
          [clear_no_progress_loop_for_operator_resume] used to short-circuit the
          resume and leave the keeper paused forever: no_progress pause is
          [Manual_resume_required], so there is no other recovery path. Run it
          best-effort and always fall through to the paused-state write below;
          the authoritative [persist_directive_meta_update] stays fail-closed.
          KLV-2 / RFC-0152. *)
       let directive_source_meta =
         if paused then entry.meta
         else (
           match clear_no_progress_loop_for_operator_resume entry with
           | Ok cleared_meta -> cleared_meta
           | Error err ->
             Otel_metric_store.inc_counter
               Keeper_metrics.(to_string DirectiveFailures)
               ~labels:[ "keeper", entry.name; "site", "no_progress_resume_clear" ]
               ();
             Log.Keeper.warn
               "directive resume: best-effort no_progress clear failed for %s; \
                proceeding with unpause: %s"
               entry.name
               err;
             entry.meta)
       in
       let cleared_completion_contract =
         if paused then directive_source_meta
       else
         Keeper_unified_turn_completion_contract.clear_for_operator_resume
           ~base_path:entry.base_path
           directive_source_meta
       in
       let updated_meta = directive_paused_meta cleared_completion_contract paused in
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
            Keeper_turn_livelock.reset_keeper_livelock
              ~base_path:entry.base_path
              ~keeper:entry.name;
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
           "directive claim: meta persist failed for %s task=%s: %s"
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

(** Process a single directive received from a gRPC HeartbeatAck.
    Directives are string commands: "pause", "resume", "wakeup",
    "claim:<task_id>". Unknown directives are logged and ignored. *)
let process_directive ~agent_name directive =
  match directive with
  | "pause" ->
    Log.Keeper.emit
      Log.Info
      ~category:Log.Directive
      ~details:(`Assoc [ "agent_name", `String agent_name; "action", `String "pause" ])
      (Printf.sprintf "directive: pausing keeper %s" agent_name);
    set_keeper_paused_state ~agent_name true
  | "resume" ->
    Log.Keeper.emit
      Log.Info
      ~category:Log.Directive
      ~details:(`Assoc [ "agent_name", `String agent_name; "action", `String "resume" ])
      (Printf.sprintf "directive: resuming keeper %s" agent_name);
    set_keeper_paused_state ~agent_name false
  | "wakeup" ->
    (* Auto-resume on wakeup: dashboard "깨우기" surfaces a single button,
       but auto-pause (stale_fleet_batch / turn_timeout) silently persists
       [meta.paused = true]. Without this branch, wakeup signals fiber_wakeup
       but the heartbeat loop honors paused state and skips — user clicks
       "깨우기" with no observable effect. Treat wakeup as a superset of
       resume so paused keepers re-enter the run loop.
       Also clear any persisted livelock attempt counter regardless of which
       branch runs: older turn-livelock blocks only recorded a `pause_human`
       receipt, and current blocks may persist [meta.paused = true] after the
       guard fires.  In both cases a wakeup should start from a fresh counter
       instead of immediately re-blocking the same turn. *)
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
    let clear_wakeup_no_progress_if_needed () =
      match entry_opt with
      | None -> true
      | Some e ->
        Keeper_turn_livelock.reset_keeper_livelock
          ~base_path:e.base_path
          ~keeper:e.name;
        (match clear_no_progress_loop_for_operator_resume e with
         | Ok (_ : keeper_meta) -> true
         | Error err ->
           Otel_metric_store.inc_counter
             Keeper_metrics.(to_string DirectiveFailures)
             ~labels:
               [ "keeper", e.name; "site", "no_progress_resume_clear" ]
             ();
           Log.Keeper.error
             "directive wakeup: no_progress clear failed for %s: %s"
             e.name
           err;
           false)
    in
    if entry_paused
    then (
      Log.Keeper.emit
        Log.Info
        ~category:Log.Directive
        ~details:(`Assoc [ "agent_name", `String agent_name; "action", `String "wakeup_auto_resume" ])
        (Printf.sprintf "directive: waking up %s (was paused — auto-resuming)" agent_name);
      set_keeper_paused_state ~agent_name false)
    else (
      Log.Keeper.emit
        Log.Debug
        ~category:Log.Directive
        ~details:(`Assoc [ "agent_name", `String agent_name; "action", `String "wakeup" ])
        (Printf.sprintf "directive: waking up %s" agent_name);
      if clear_wakeup_no_progress_if_needed ()
      then wakeup_keeper_by_agent_name ~agent_name)
  | s when String.length s > 6 && String.starts_with s ~prefix:"claim:" ->
    let task_id = String.sub s 6 (String.length s - 6) in
    (match Keeper_id.Task_id.of_string task_id with
     | Ok parsed_task_id ->
       Log.Keeper.emit
         Log.Info
         ~category:Log.Directive
         ~details:
           (`Assoc
             [ "agent_name", `String agent_name
             ; "action", `String "claim"
             ; "task_id", `String task_id
             ])
         (Printf.sprintf "directive: server assigned task %s to %s" task_id agent_name);
       assign_keeper_task_from_directive ~agent_name ~task_id:parsed_task_id
     | Error err ->
       Log.Keeper.emit
         Log.Warn
         ~category:Log.Directive
         ~details:
           (`Assoc
             [ "agent_name", `String agent_name
             ; "action", `String "claim"
             ; "task_id", `String task_id
             ; "error", `String err
             ])
         (Printf.sprintf "directive: ignoring invalid task assignment for %s (%s): %s" agent_name task_id err))
  | unknown ->
    Log.Keeper.emit
      Log.Warn
      ~category:Log.Directive
      ~details:(`Assoc [ "agent_name", `String agent_name; "directive", `String unknown ])
      (Printf.sprintf "unknown gRPC directive for %s: %s" agent_name unknown)
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

let bootstrap_live_keeper_meta ~(ctx : _ context) (m : keeper_meta) : keeper_meta =
  try
    if not (Workspace_utils.is_initialized ctx.config)
    then (
      let (_init_msg : string) = Workspace.init ctx.config ~agent_name:None in
      ());
    let m =
      match repair_identity_drift_for_keepalive ~ctx m with
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
    (match
       write_meta_with_merge
         ~merge:Keeper_meta_merge.monotonic_usage_counters ctx.config synced
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
         (Printf.sprintf "write_meta failed (bootstrap): %s" e));
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
let dispatch_fiber_started ~base_path keeper_name =
  match Keeper_registry.prepare_fiber_launch ~base_path keeper_name with
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

let record_keeper_stopped
      (entry : Keeper_registry.registry_entry)
      ~base_path
      ~keeper_name
      ~detail
  : bool
  =
  if resolve_registry_done entry ~source:"keepalive_record_stopped" `Stopped
  then (
    Keeper_registry.dispatch_event_unit
      ~base_path
      keeper_name
      Keeper_state_machine.Stop_requested;
    Keeper_registry.dispatch_event_unit
      ~base_path
      keeper_name
      Keeper_state_machine.Drain_complete;
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
      ~base_path
      ~keeper_name
      ~failure_reason
  : unit
  =
  let reason = Keeper_registry.failure_reason_to_string failure_reason in
  if resolve_registry_done entry ~source:"keepalive_record_crashed" (`Crashed reason)
  then (
    let outcome = reason in
    Keeper_registry.set_failure_reason ~base_path keeper_name (Some failure_reason);
    Keeper_registry.dispatch_event_unit
      ~base_path
      keeper_name
      (Keeper_state_machine.Fiber_terminated { outcome; provider_id = None; http_status = None });
    Keeper_registry.record_crash ~base_path keeper_name (Time_compat.now ()) reason;
    Keeper_registry_error_recording.record ~base_path keeper_name reason;
    publish_keeper_phase_lifecycle
      ~phase:Keeper_state_machine.Crashed
      ~keeper_name
      ~detail:reason
      ())
;;

(* ── Keeper lifecycle start/stop ── *)

let start_keepalive ?(proactive_warmup_sec = 0) (ctx : _ context) (m : keeper_meta) : unit
  =
  match repair_identity_drift_for_keepalive ~ctx m with
  | None ->
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string HeartbeatFailures)
      ~labels:[ "keeper", m.name; "phase", "identity_drift_unrepairable" ]
      ();
    Log.Keeper.emit
      Log.Error
      ~category:Log.Heartbeat
      ~details:(`Assoc [ "keeper", `String m.name; "reason", `String "identity_drift_unrepairable" ])
      (Printf.sprintf "start_keepalive skipped %s: identity drift could not be repaired" m.name)
  | Some m ->
    let existing_entry =
      Keeper_registry.get ~base_path:ctx.config.base_path m.name
    in
    let reclaimable_stale_entry (entry : Keeper_registry.registry_entry) =
      let finished = Option.is_some (Eio.Promise.peek entry.done_p) in
      match entry.phase with
      | Keeper_state_machine.Stopped -> finished
      | Keeper_state_machine.Failing
      | Keeper_state_machine.Overflowed
      | Keeper_state_machine.Compacting
      | Keeper_state_machine.HandingOff
      | Keeper_state_machine.Draining
      | Keeper_state_machine.Crashed
      | Keeper_state_machine.Dead
      | Keeper_state_machine.Zombie -> finished
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
       Keeper_registry.unregister ~base_path:ctx.config.base_path m.name
     | _ -> ());
    if Keeper_registry.is_registered ~base_path:ctx.config.base_path m.name
    then
      Log.Keeper.emit
        Log.Info
        ~category:Log.Heartbeat
        ~details:(`Assoc [ "keeper", `String m.name ])
        (Printf.sprintf "start_keepalive: skipped %s (already registered)" m.name)
    else
      match Keeper_registry.spawn_slots_decision () with
      | Error reason ->
        Keeper_registry.record_spawn_slot_denied ~keeper_name:m.name ~surface:"keepalive" reason;
        publish_keeper_lifecycle
          ~event:
            (Keeper_lifecycle_events.Custom_event
               { verb = Keeper_lifecycle_events.Admission_denied
               ; phase = Some Keeper_state_machine.Offline
               })
          ~keeper_name:m.name
          ~detail:(Keeper_registry.spawn_slot_denial_reason_to_detail reason)
          ()
      | Ok () -> (
      (* Register in Keeper_registry first — single source of truth. *)
      let reg =
        Keeper_registry.register_offline ~base_path:ctx.config.base_path m.name m
      in
      (* Restore persisted tool usage stats from previous session *)
      Keeper_registry_tool_usage_persistence.restore ~base_path:ctx.config.base_path m.name;
      let stop = reg.fiber_stop in
      let wakeup = reg.fiber_wakeup in
      (* Start optional gRPC heartbeat fiber *)
      let grpc_close = start_keeper_grpc_heartbeat ~ctx ~m ~stop in
      (match grpc_close with
       | Some _ ->
         Keeper_registry.set_grpc_close ~base_path:ctx.config.base_path m.name grpc_close
       | None -> ());
      let live_meta = bootstrap_live_keeper_meta ~ctx m in
      Keeper_registry.update_meta ~base_path:ctx.config.base_path m.name live_meta;
      (* Telemetry feedback refresh loop removed in #6814:
       behavioral_stats no longer consumed by build_prompt. *)
      match dispatch_fiber_started ~base_path:ctx.config.base_path live_meta.name with
      | Error err ->
        (* Fail closed: the registry FSM refused [Fiber_started], so no
           keepalive fiber may fork and [Started]/[Running] must not be
           announced. Resolve the fresh entry through the crash path so the
           supervisor sweep observes a typed outcome and re-queues with the
           usual backoff/budget instead of leaving a never-resolved entry. *)
        let reason =
          Printf.sprintf
            "fiber_start_rejected: %s"
            (Keeper_state_machine.transition_error_to_string err)
        in
        Keeper_registry.set_failure_reason
          ~base_path:ctx.config.base_path
          live_meta.name
          (Some (Keeper_registry.Exception reason));
        Keeper_registry.record_crash
          ~base_path:ctx.config.base_path
          live_meta.name
          (Time_compat.now ())
          reason;
        Keeper_registry_error_recording.record
          ~base_path:ctx.config.base_path
          live_meta.name
          reason;
        if resolve_registry_done reg ~source:"keepalive_launch_rejected" (`Crashed reason)
        then
          publish_keeper_phase_lifecycle
            ~phase:Keeper_state_machine.Crashed
            ~keeper_name:live_meta.name
            ~detail:reason
            ()
      | Ok () ->
        publish_keeper_started ~live_meta;
        Eio.Fiber.fork ~sw:ctx.sw (fun () ->
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
        let record_loop_exit () =
          match Keeper_registry.get ~base_path:ctx.config.base_path live_meta.name with
          | Some
              { Keeper_registry.last_failure_reason =
                  Some
                    (( Keeper_registry.Stale_turn_timeout _
                     | Keeper_registry.Stale_termination_storm _
                     | Keeper_registry.Stale_fleet_batch _
                     | Keeper_registry.Provider_timeout_loop _ ) as reason)
              ; _
              } -> record_crash reason
          | _ -> record_stopped "normal exit"
        in
        (* Cancel-safe finally (#9747 iter 2): [cleanup_tracking] touches
         registry state that can raise transiently during shutdown.
         Stdlib [Fun.protect] would wrap that as [Fun.Finally_raised],
         masking the body's Cancelled / Keeper_fiber_crash. Swallow
         Cancelled (the outer one is in flight) and log non-cancel
         exceptions instead of propagating them. Mirrors
         keeper_agent_run.ml and keeper_unified_turn.ml:990. *)
        let safe_cleanup_tracking () =
          try
            Keeper_registry.cleanup_tracking
              ~base_path:ctx.config.base_path
              live_meta.name
          with
          | Eio.Cancel.Cancelled _ -> ()
          | e ->
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
                  ; "error", `String (Printexc.to_string e)
                  ])
              (Printf.sprintf
                 "%s: cleanup_tracking in heartbeat finally raised: %s"
                 live_meta.name
                 (Printexc.to_string e))
        in
        Eio_guard.protect
          (fun () ->
             try
               run_heartbeat_loop ~proactive_warmup_sec ctx live_meta stop ~wakeup;
               record_loop_exit ()
             with
             | Keeper_registry.Keeper_fiber_crash ->
               if Atomic.get stop
               then record_stopped "manual stop"
               else (
                 let reason =
                   match
                     Keeper_registry.get ~base_path:ctx.config.base_path live_meta.name
                   with
                   | Some e ->
                     Option.value
                       ~default:(Keeper_registry.Exception "fiber_crash")
                       e.last_failure_reason
                   | None -> Keeper_registry.Exception "fiber_crash"
                 in
                 record_crash reason)
             | Eio.Cancel.Cancelled _ ->
               record_stopped "cancelled"
             | exn ->
               if Atomic.get stop
               then record_stopped "manual stop"
               else (
                 Otel_metric_store.inc_counter
                   Keeper_metrics.(to_string HeartbeatFailures)
                   ~labels:[ "keeper", live_meta.name; "phase", "loop_crash" ]
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
                      "heartbeat loop for %s crashed: %s"
                      live_meta.name
                      (Printexc.to_string exn));
                 record_crash (Keeper_registry.Exception (Printexc.to_string exn))))
          ~finally:safe_cleanup_tracking))
;;

let stop_keepalive ?base_path name =
  let entries =
    Keeper_registry.all ?base_path ()
    |> List.filter (fun (e : Keeper_registry.registry_entry) -> String.equal e.name name)
  in
  List.iter
    (fun (entry : Keeper_registry.registry_entry) ->
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
        | None -> ());
       match entry.phase with
       | Keeper_state_machine.Crashed | Keeper_state_machine.Dead -> ()
       | _ ->
         if
           record_keeper_stopped
             entry
             ~base_path:entry.base_path
             ~keeper_name:entry.name
             ~detail:"manual stop"
         then Keeper_registry.cleanup_tracking ~base_path:entry.base_path entry.name)
    entries
;;

(** Stop all running keepers. Used in test cleanup to prevent orphaned
    keepalive loops from blocking process exit. *)
let stop_all_keepalives () =
  Keeper_registry.all ()
  |> List.iter (fun (entry : Keeper_registry.registry_entry) -> stop_keepalive entry.name)
;;
