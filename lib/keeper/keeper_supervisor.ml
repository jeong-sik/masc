(** Keeper_supervisor — keeper keepalive fiber supervision.

    Supervises the MASC-owned background keepalive fibers that maintain
    keeper presence and heartbeat snapshots. Uses [Keeper_registry] as
    the single source of truth for keeper state. The Promise-based
    liveness tracking ([done_p]/[done_r]) lives in registry entries.

    This is not the OAS [Agent.run] lifecycle; it sits outside the turn
    loop and only manages keepalive liveness/restart policy.

    @since 2.102.0 *)

open Keeper_types
open Keeper_execution

module StringMap = Map.Make (String)

(* ── Pure helpers ────────────────────────────────────────── *)

let backoff_delay attempt =
  let base = Env_config.KeeperSupervisor.backoff_base_s in
  let max_delay = Env_config.KeeperSupervisor.backoff_max_s in
  Float.min max_delay (base *. Float.of_int (1 lsl (min attempt 20)))

let keep_last_n n item lst =
  let full = item :: lst in
  if List.length full <= n then full
  else List.filteri (fun i _ -> i < n) full

let should_cleanup_dead ~now ~dead_ttl_sec
    (entry : Keeper_registry.registry_entry) =
  match entry.phase, entry.dead_since_ts with
  | Keeper_state_machine.Dead, Some dead_since ->
      now -. dead_since >= dead_ttl_sec
  | _ -> false

(** Check if a paused keeper meta file on disk is stale enough to remove. *)
let is_stale_paused_meta ~now ~paused_ttl_sec (meta : keeper_meta) =
  if not meta.paused then false
  else
    let updated_ts =
      Resilience.Time.parse_iso8601_opt meta.updated_at
      |> Option.value ~default:0.0
    in
    updated_ts > 0.0 && now -. updated_ts >= paused_ttl_sec

(* ── Event publishing ────────────────────────────────────── *)

let publish_lifecycle event_name keeper_name detail =
  match Keeper_keepalive.get_bus () with
  | Some bus ->
      Oas_events.publish_keeper_lifecycle bus ~event:event_name
        ~keeper_name ~detail
  | None -> ()

(* ── Supervised fiber launch ─────────────────────────────── *)

let launch_supervised_fiber ~proactive_warmup_sec ctx (meta : keeper_meta)
    (reg : Keeper_registry.registry_entry) =
  let base_path = ctx.config.base_path in
  let keepers_dir =
    Filename.concat (Coord.masc_root_dir ctx.config) "keepers" in
  (match Keeper_registry.dispatch_event ~base_path meta.name
           Keeper_state_machine.Fiber_started with
   | Ok _ -> ()
   | Error err ->
       Log.Keeper.warn
         "%s: Fiber_started rejected during supervised launch: %s"
         meta.name
         (Keeper_state_machine.transition_error_to_string err));
  Eio.Fiber.fork ~sw:ctx.sw (fun () ->
    let resolved = ref false in
    let resolve_done value =
      if not !resolved && Option.is_none (Eio.Promise.peek reg.done_p) then begin
        resolved := true;
        Eio.Promise.resolve reg.done_r value;
        true
      end else
        false
    in
    Fun.protect
      (fun () ->
        (try
           Keeper_keepalive.run_heartbeat_loop ~proactive_warmup_sec
             ctx meta reg.fiber_stop ~wakeup:reg.fiber_wakeup;
           (* Normal exit: stop flag was set — dispatch typed events *)
           ignore (Keeper_registry.dispatch_event ~base_path meta.name
             Keeper_state_machine.Stop_requested);
           ignore (Keeper_registry.dispatch_event ~base_path meta.name
             Keeper_state_machine.Drain_complete);
           if resolve_done `Stopped then
             publish_lifecycle "stopped" meta.name "normal exit"
         with
         | Eio.Cancel.Cancelled _ as e -> raise e
         | exn ->
             (* RFC-0002: unified crash handler.
                Keeper_fiber_crash carries no payload — failure_reason is
                pre-stored in registry by the raise site.
                For unexpected exceptions, wrap in Exception variant. *)
             let fr = match exn with
               | Keeper_registry.Keeper_fiber_crash ->
                 (match Keeper_registry.get ~base_path meta.name with
                  | Some e ->
                    Option.value
                      ~default:(Keeper_registry.Exception "fiber_crash")
                      e.last_failure_reason
                  | None ->
                    Keeper_registry.Exception "fiber_crash (unregistered)")
               | _ -> Keeper_registry.Exception (Printexc.to_string exn)
             in
             let reason = Keeper_registry.failure_reason_to_string fr in
             Keeper_registry.set_failure_reason ~base_path meta.name (Some fr);
             ignore (Keeper_registry.dispatch_event ~base_path meta.name
               (Keeper_state_machine.Fiber_terminated { outcome = reason }));
             let ts = Time_compat.now () in
             Keeper_registry.record_crash ~base_path
               meta.name ts reason;
             let rc = match Keeper_registry.get ~base_path meta.name with
               | Some e -> e.restart_count | None -> 0 in
             Keeper_crash_persistence.enqueue_record ~keepers_dir
               ~name:meta.name ~ts ~reason ~restart_count:rc;
             Keeper_registry.record_error ~base_path meta.name reason;
             if resolve_done (`Crashed reason) then
               publish_lifecycle "crashed" meta.name reason))
      ~finally:(fun () ->
        Keeper_registry.cleanup_tracking ~base_path meta.name;
        if not !resolved then begin
          if Shutdown.is_shutting_down_global () then begin
            Log.Keeper.warn "%s: fiber unresolved during shutdown (not a crash)" meta.name;
            Keeper_registry.mark_dead ~base_path meta.name
              ~at:(Time_compat.now ());
            ignore (resolve_done (`Crashed "shutdown"))
          end else begin
            let reason =
              Keeper_registry.failure_reason_to_string
                Keeper_registry.Fiber_unresolved in
            Keeper_registry.set_failure_reason ~base_path meta.name
              (Some Keeper_registry.Fiber_unresolved);
            let ts = Time_compat.now () in
            Keeper_registry.record_crash ~base_path
              meta.name ts reason;
            let rc = match Keeper_registry.get ~base_path meta.name with
              | Some e -> e.restart_count | None -> 0 in
            Keeper_crash_persistence.enqueue_record ~keepers_dir
              ~name:meta.name ~ts ~reason ~restart_count:rc;
            Keeper_registry.record_error ~base_path meta.name reason;
            ignore (Keeper_registry.dispatch_event ~base_path meta.name
              (Keeper_state_machine.Fiber_terminated { outcome = reason }));
            if resolve_done (`Crashed reason) then
              publish_lifecycle "crashed" meta.name reason
          end
        end))

let supervise_keepalive ~proactive_warmup_sec (ctx : _ context)
    (meta : keeper_meta) =
  if Keeper_registry.is_registered ~base_path:ctx.config.base_path meta.name
  then ()
  else if not (Keeper_registry.spawn_slots_available ()) then ()
  else begin
    (* Register in Keeper_registry — single source of truth. *)
    let reg =
      Keeper_registry.register_offline ~base_path:ctx.config.base_path meta.name meta
    in
    (* Coord initialization *)
    (try
       if not (Coord_utils.is_initialized ctx.config) then
         let (_init_msg : string) = Coord.init ctx.config ~agent_name:None in ()
     with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
       Log.Keeper.error "supervisor room init failed: %s"
         (Printexc.to_string exn));
    let live_meta =
      try
        let synced = ensure_keeper_room_presence ctx.config meta in
        ignore (write_meta ctx.config synced);
        synced
      with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
        Log.Keeper.error "supervisor presence sync failed: %s"
          (Printexc.to_string exn);
        meta
    in
    Keeper_registry.update_meta ~base_path:ctx.config.base_path meta.name
      live_meta;
    publish_lifecycle "started" meta.name "supervised";
    launch_supervised_fiber ~proactive_warmup_sec ctx live_meta reg
  end

(* ── Sweep and recover ───────────────────────────────────── *)

(** Reconcile only orphaned or cleanly stopped durable keepers.
    Running/Paused/Crashed/Dead entries are actively managed by sweep
    and must NOT be re-launched by reconcile. Stopped entries with
    unresolved fibers (done_p = None) are also skipped — sweep will
    handle them once the fiber terminates. *)
let reconcile_keepalive_keepers (ctx : _ context) =
  let base_path = ctx.config.base_path in
  let names = Keeper_types.keepalive_keeper_names ctx.config in
  Log.Keeper.info "reconcile_keepalive_keepers: started (candidates=%d)"
    (List.length names);
  let t0 = Time_compat.now () in
  List.iter (fun name ->
         match read_meta ctx.config name with
         | Ok (Some meta) when not meta.paused ->
             let dominated_by_sweep =
               match Keeper_registry.get ~base_path meta.name with
               | None -> false  (* no entry = orphaned, reconcile OK *)
               | Some e ->
                 match e.phase with
                 | Keeper_state_machine.Running | Keeper_state_machine.Paused -> true
                 | Keeper_state_machine.Crashed | Keeper_state_machine.Dead -> true
                 | Keeper_state_machine.Failing | Keeper_state_machine.Overflowed
                 | Keeper_state_machine.Compacting
                 | Keeper_state_machine.HandingOff | Keeper_state_machine.Draining
                 | Keeper_state_machine.Restarting -> true
                 | Keeper_state_machine.Offline -> false
                 | Keeper_state_machine.Stopped ->
                     (* Stopped with unresolved fiber → sweep will clean up *)
                     Eio.Promise.peek e.done_p = None
             in
             if not dominated_by_sweep then begin
               supervise_keepalive ~proactive_warmup_sec:0 ctx meta;
               if Keeper_registry.is_running ~base_path meta.name then begin
                 publish_lifecycle "reconciled" meta.name "durable keeper";
                 Log.Keeper.info "%s: reconciled durable keeper" meta.name
               end
             end
         | Ok (Some _meta) -> () (* paused, skip *)
         | Ok None -> ()
         | Error err ->
             Log.Keeper.debug "reconcile: read_meta failed for %s: %s" name err)
    names;
  Log.Keeper.info "reconcile_keepalive_keepers: completed (elapsed_ms=%d)"
    (int_of_float ((Time_compat.now () -. t0) *. 1000.0))

let cleanup_dead_tombstone (ctx : _ context)
    (entry : Keeper_registry.registry_entry) =
  match read_meta ctx.config entry.name with
  | Ok (Some meta) ->
      let persisted_paused =
        if meta.paused then true
        else
          match write_meta ctx.config { meta with paused = true } with
          | Ok () -> true
          | Error err ->
              Log.Keeper.warn
                "%s: dead tombstone cleanup paused write failed: %s"
                entry.name err;
              false
      in
      Keeper_registry.unregister ~base_path:ctx.config.base_path entry.name;
      if persisted_paused then begin
        publish_lifecycle "dead_cleaned" entry.name "paused meta persisted";
        Log.Keeper.info "%s: dead tombstone cleaned up" entry.name
      end else begin
        publish_lifecycle "dead_cleaned" entry.name "meta write failed, unregistered anyway";
        Log.Keeper.warn "%s: dead tombstone unregistered despite meta write failure" entry.name
      end
  | Ok None ->
      Keeper_registry.unregister ~base_path:ctx.config.base_path entry.name;
      publish_lifecycle "dead_cleaned" entry.name "meta missing";
      Log.Keeper.warn "%s: dead tombstone unregistered (meta missing)" entry.name
  | Error err ->
      Keeper_registry.unregister ~base_path:ctx.config.base_path entry.name;
      publish_lifecycle "dead_cleaned" entry.name
        (Printf.sprintf "meta read error: %s" err);
      Log.Keeper.warn "%s: dead tombstone unregistered (meta error: %s)"
        entry.name err

(** Cohort key from structured failure_reason ADT.
    Groups failures by variant, ignoring parameters (e.g. failure count). *)
let cohort_key_of_reason = function
  | Some (Keeper_registry.Heartbeat_consecutive_failures _) -> "heartbeat_failures"
  | Some (Keeper_registry.Turn_consecutive_failures _) -> "turn_failures"
  | Some (Keeper_registry.Ambiguous_partial_commit _) -> "ambiguous_partial_commit"
  | Some Keeper_registry.Fiber_unresolved -> "fiber_unresolved"
  | Some (Keeper_registry.Exception _) -> "exception"
  | None -> "unknown"

(** Self-preservation gate. Suppresses restarts when a dominant failure
    cohort exceeds ratio threshold AND minimum candidate count. *)
let apply_self_preservation ~keepers_dir ~total_keepers to_restart =
  let sp_ratio = Env_config.KeeperSupervisor.self_preservation_ratio in
  let sp_min = Env_config.KeeperSupervisor.self_preservation_min_candidates in
  let n_candidates = List.length to_restart in
  let n_total = max 1 total_keepers in
  let ratio = float_of_int n_candidates /. float_of_int n_total in
  if ratio > sp_ratio
     && n_candidates >= sp_min
  then begin
    (* Group by failure_reason ADT variant (not string prefix) *)
    let insert_cohort acc (entry : Keeper_registry.registry_entry) _msg =
      let key = cohort_key_of_reason entry.last_failure_reason in
      let prev = try StringMap.find key acc with Not_found -> [] in
      StringMap.add key ((entry, _msg) :: prev) acc
    in
    let cohorts = List.fold_left (fun acc ((e, m) : _ * string) -> insert_cohort acc e m) StringMap.empty to_restart in
    let dominant_key, dominant_entries =
      StringMap.fold (fun k v (best_k, best_v) ->
        if List.length v > List.length best_v then (k, v) else (best_k, best_v)
      ) cohorts ("", [])
    in
    if List.length dominant_entries >= sp_min then begin
      Log.Keeper.warn
        "self-preservation: suppressing %d/%d restarts (ratio=%.2f, cohort=%s)"
        (List.length dominant_entries) n_total ratio dominant_key;
      publish_lifecycle "self_preservation" "supervisor"
        (Printf.sprintf "%d/%d suppressed, cohort=%s"
           (List.length dominant_entries) n_total dominant_key);
      Keeper_crash_persistence.enqueue_sp_event
        ~keepers_dir
        ~ts:(Time_compat.now ())
        ~suppressed_count:(List.length dominant_entries)
        ~total:n_total
        ~ratio
        ~dominant_cohort:dominant_key;
      let dominant_set =
        List.map (fun ((e : Keeper_registry.registry_entry), _) -> e.name)
          dominant_entries in
      List.filter (fun ((e : Keeper_registry.registry_entry), _) ->
        not (List.mem e.name dominant_set)
      ) to_restart
    end else
      to_restart
  end else
    to_restart

let sweep_and_recover (ctx : _ context) =
  let now = Time_compat.now () in
  let max_restarts = Runtime_params.get Governance_registry.keeper_supervisor_max_restarts in
  let dead_ttl_sec = Runtime_params.get Governance_registry.keeper_dead_ttl_sec in
  let base_path = ctx.config.base_path in
  (* Phase 2: sweep order — restart/unregister FIRST, reconcile LAST.
     This prevents reconcile from re-launching keepers that sweep is about
     to process (defense-in-depth alongside is_registered check). *)
  let entries = Keeper_registry.all ~base_path () in
  let to_restart = ref [] in
  let to_unregister = ref [] in
  let to_mark_dead = ref [] in
  let to_cleanup_dead = ref [] in
  List.iter (fun (entry : Keeper_registry.registry_entry) ->
    match entry.phase with
    | Keeper_state_machine.Dead ->
        (match entry.dead_since_ts with
         | Some dead_since when now -. dead_since >= dead_ttl_sec ->
             to_cleanup_dead := entry :: !to_cleanup_dead
         | _ -> ())
    | Keeper_state_machine.Stopped ->
        to_unregister := entry :: !to_unregister
    | Keeper_state_machine.Running | Keeper_state_machine.Paused
    | Keeper_state_machine.Crashed
    | Keeper_state_machine.Failing | Keeper_state_machine.Overflowed
    | Keeper_state_machine.Compacting
    | Keeper_state_machine.HandingOff | Keeper_state_machine.Draining
    | Keeper_state_machine.Restarting | Keeper_state_machine.Offline ->
      (match Eio.Promise.peek entry.done_p with
      | None when entry.phase = Keeper_state_machine.Stopped ->
          to_unregister := entry :: !to_unregister
      | None -> ()  (* Alive — skip *)
      | Some `Stopped ->
          to_unregister := entry :: !to_unregister
      | Some (`Crashed msg) ->
          if entry.restart_count >= max_restarts then
            to_mark_dead := (entry, msg) :: !to_mark_dead
          else begin
            let delay = backoff_delay entry.restart_count in
            if now -. entry.last_restart_ts >= delay then
              to_restart := (entry, msg) :: !to_restart
          end)
  ) entries;
  List.iter (fun (entry : Keeper_registry.registry_entry) ->
    Keeper_registry.unregister ~base_path entry.name
  ) !to_unregister;
  List.iter (fun ((entry : Keeper_registry.registry_entry), msg) ->
    (* RFC-0002: dispatch budget exhaustion before marking dead *)
    ignore (Keeper_registry.dispatch_event ~base_path entry.name
      Keeper_state_machine.Restart_budget_exhausted);
    Keeper_registry.mark_dead ~base_path entry.name ~at:now;
    publish_lifecycle "dead" entry.name
      (Printf.sprintf "restart budget exhausted (%d), last: %s"
         max_restarts msg);
    Log.Keeper.error "%s: restart budget exhausted (%d). Dead."
      entry.name max_restarts
  ) !to_mark_dead;
  List.iter (cleanup_dead_tombstone ctx) !to_cleanup_dead;
  let active_count =
    List.length (List.filter (fun (e : Keeper_registry.registry_entry) ->
      e.phase = Keeper_state_machine.Running || e.phase = Keeper_state_machine.Crashed
    ) entries) in
  let restart_list =
    let keepers_dir =
      Filename.concat (Coord.masc_root_dir ctx.config) "keepers" in
    apply_self_preservation ~keepers_dir ~total_keepers:active_count !to_restart in
  (* Restart crashed keepers *)
  List.iter (fun ((old_entry : Keeper_registry.registry_entry), crash_msg) ->
    match read_meta ctx.config old_entry.name with
    | Ok (Some meta) ->
        let attempt = old_entry.restart_count + 1 in
        (* RFC-0002: dispatch restart attempt event *)
        ignore (Keeper_registry.dispatch_event ~base_path old_entry.name
          (Keeper_state_machine.Supervisor_restart_attempt { attempt }));
        let old_crash_log = old_entry.crash_log in
        let reg =
          Keeper_registry.register_restarting ~base_path old_entry.name meta
        in
        Keeper_registry.restore_supervisor_state ~base_path old_entry.name
          ~restart_count:attempt ~last_restart_ts:now
          ~crash_log:(keep_last_n 5 (now, crash_msg) old_crash_log);
        launch_supervised_fiber ~proactive_warmup_sec:0 ctx meta reg;
        publish_lifecycle "restarted" old_entry.name
          (Printf.sprintf "attempt %d" attempt);
        Log.Keeper.info "%s: restarted (attempt %d, backoff %.0fs)"
          old_entry.name attempt (backoff_delay (attempt - 1))
    | _ ->
        Log.Keeper.error "%s: cannot read meta for restart, removing"
          old_entry.name;
        Keeper_registry.unregister ~base_path old_entry.name
  ) restart_list;
  (* Phase 2: prune stale paused keeper meta files from disk *)
  let paused_ttl_sec = Env_config.KeeperSupervisor.paused_cleanup_ttl_sec in
  Keeper_types.keeper_names ctx.config
  |> List.iter (fun name ->
         if Keeper_registry.is_running ~base_path name then ()
         else
           match read_meta ctx.config name with
           | Ok (Some meta) when is_stale_paused_meta ~now ~paused_ttl_sec meta ->
               let path = Keeper_types.keeper_meta_path ctx.config name in
               (try
                  Sys.remove path;
                  publish_lifecycle "paused_pruned" name
                    (Printf.sprintf "last_updated=%s" meta.updated_at);
                  Log.Keeper.info "%s: stale paused meta pruned" name
                with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
                  Log.Keeper.warn "%s: paused meta prune failed: %s"
                    name (Printexc.to_string exn))
           | _ -> ());
  (* Phase 3: reconcile LAST — only orphaned durable keepers *)
  reconcile_keepalive_keepers ctx
