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
  match entry.state, entry.dead_since_ts with
  | Keeper_registry.Dead, Some dead_since ->
      now -. dead_since >= dead_ttl_sec
  | _ -> false

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
  Eio.Fiber.fork ~sw:ctx.sw (fun () ->
    let resolved = ref false in
    let resolve_done value =
      if not !resolved then begin
        resolved := true;
        Eio.Promise.resolve reg.done_r value
      end
    in
    Fun.protect
      (fun () ->
        (try
           Keeper_keepalive.run_heartbeat_loop ~proactive_warmup_sec
             ctx meta reg.fiber_stop ~wakeup:reg.fiber_wakeup;
           (* Normal exit: stop flag was set *)
           Keeper_registry.set_state ~base_path meta.name
             Keeper_registry.Stopped;
           resolve_done `Stopped;
           publish_lifecycle "stopped" meta.name "normal exit"
         with
         | Keeper_registry.Keeper_heartbeat_failure info ->
             let reason =
               Keeper_registry.failure_reason_to_string info.reason in
             Keeper_registry.set_failure_reason ~base_path meta.name
               (Some info.reason);
             Keeper_registry.set_state ~base_path meta.name
               Keeper_registry.Crashed;
             Keeper_registry.record_crash ~base_path
               meta.name (Time_compat.now ()) reason;
             Keeper_registry.record_error ~base_path meta.name reason;
             resolve_done (`Crashed reason);
             publish_lifecycle "crashed" meta.name reason
         | Eio.Cancel.Cancelled _ as e -> raise e
         | exn ->
             let fr = Keeper_registry.Exception (Printexc.to_string exn) in
             let reason = Keeper_registry.failure_reason_to_string fr in
             Keeper_registry.set_failure_reason ~base_path meta.name (Some fr);
             Keeper_registry.set_state ~base_path meta.name
               Keeper_registry.Crashed;
             Keeper_registry.record_crash ~base_path
               meta.name (Time_compat.now ()) reason;
             Keeper_registry.record_error ~base_path meta.name reason;
             resolve_done (`Crashed reason);
             publish_lifecycle "crashed" meta.name reason))
      ~finally:(fun () ->
        Keeper_registry.cleanup_tracking ~base_path meta.name;
        if not !resolved then begin
            let reason =
              Keeper_registry.failure_reason_to_string
                Keeper_registry.Fiber_unresolved in
            Keeper_registry.set_failure_reason ~base_path meta.name
              (Some Keeper_registry.Fiber_unresolved);
            Keeper_registry.record_crash ~base_path
              meta.name (Time_compat.now ()) reason;
            Keeper_registry.record_error ~base_path meta.name reason;
            Keeper_registry.set_state ~base_path meta.name
              Keeper_registry.Crashed;
            resolve_done (`Crashed reason);
            publish_lifecycle "crashed" meta.name reason
        end))

let supervise_keepalive ~proactive_warmup_sec (ctx : _ context)
    (meta : keeper_meta) =
  if Keeper_registry.is_running ~base_path:ctx.config.base_path meta.name
  then ()
  else if not (Keeper_registry.spawn_slots_available ()) then ()
  else begin
    (* Register in Keeper_registry — single source of truth. *)
    let reg =
      Keeper_registry.register ~base_path:ctx.config.base_path meta.name meta
    in
    (* Room initialization *)
    (try
       if not (Room_utils.is_initialized ctx.config) then
         let (_init_msg : string) = Room.init ctx.config ~agent_name:None in ()
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
  Keeper_types.keepalive_keeper_names ctx.config
  |> List.iter (fun name ->
         match read_meta ctx.config name with
         | Ok (Some meta) when not meta.paused ->
             let dominated_by_sweep =
               match Keeper_registry.get ~base_path meta.name with
               | None -> false  (* no entry = orphaned, reconcile OK *)
               | Some e ->
                 match e.state with
                 | Keeper_registry.Running | Keeper_registry.Paused -> true
                 | Keeper_registry.Crashed | Keeper_registry.Dead -> true
                 | Keeper_registry.Stopped ->
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
  | Some Keeper_registry.Fiber_unresolved -> "fiber_unresolved"
  | Some (Keeper_registry.Exception _) -> "exception"
  | None -> "unknown"

(** Self-preservation gate. Suppresses restarts when a dominant failure
    cohort exceeds ratio threshold AND minimum candidate count. *)
let apply_self_preservation ~total_keepers to_restart =
  let sp_ratio = Env_config.KeeperSupervisor.self_preservation_ratio in
  let sp_min = Env_config.KeeperSupervisor.self_preservation_min_candidates in
  let n_candidates = List.length to_restart in
  let n_total = max 1 total_keepers in
  let ratio = float_of_int n_candidates /. float_of_int n_total in
  if ratio > sp_ratio
     && n_candidates >= sp_min
  then begin
    (* Group by failure_reason ADT variant (not string prefix) *)
    let cohorts = Hashtbl.create 4 in
    List.iter (fun ((entry : Keeper_registry.registry_entry), _msg) ->
      let key = cohort_key_of_reason entry.last_failure_reason in
      let prev = try Hashtbl.find cohorts key with Not_found -> [] in
      Hashtbl.replace cohorts key ((entry, _msg) :: prev)
    ) to_restart;
    let dominant_key, dominant_entries =
      Hashtbl.fold (fun k v (best_k, best_v) ->
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
  let max_restarts = Env_config.KeeperSupervisor.max_restarts in
  let dead_ttl_sec = Env_config.KeeperSupervisor.dead_ttl_sec in
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
    match entry.state with
    | Keeper_registry.Dead ->
        (match entry.dead_since_ts with
         | Some dead_since when now -. dead_since >= dead_ttl_sec ->
             to_cleanup_dead := entry :: !to_cleanup_dead
         | _ -> ())
    | Keeper_registry.Stopped ->
        to_unregister := entry :: !to_unregister
    | Keeper_registry.Running | Keeper_registry.Paused
    | Keeper_registry.Crashed ->
      (match Eio.Promise.peek entry.done_p with
      | None when entry.state = Keeper_registry.Stopped ->
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
      e.state = Keeper_registry.Running || e.state = Keeper_registry.Crashed
    ) entries) in
  let restart_list =
    apply_self_preservation ~total_keepers:active_count !to_restart in
  (* Restart crashed keepers *)
  List.iter (fun ((old_entry : Keeper_registry.registry_entry), crash_msg) ->
    match read_meta ctx.config old_entry.name with
    | Ok (Some meta) ->
        let attempt = old_entry.restart_count + 1 in
        let old_crash_log = old_entry.crash_log in
        let reg =
          Keeper_registry.register ~base_path old_entry.name meta
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
  (* Phase 2: reconcile LAST — only orphaned durable keepers *)
  reconcile_keepalive_keepers ctx
