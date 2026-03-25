(** Keeper_resident_supervisor — resident keepalive fiber supervision.

    Supervises the MASC-owned background keepalive fibers that maintain
    keeper presence and heartbeat snapshots. Uses [Keeper_registry] as
    the single source of truth for keeper state. The Promise-based
    liveness tracking ([done_p]/[done_r]) lives in registry entries.

    This is not the OAS [Agent.run] lifecycle; it sits outside the turn
    loop and only manages resident liveness/restart policy.

    @since 2.102.0 *)

open Keeper_types
open Keeper_execution

(* ── Pure helpers ────────────────────────────────────────── *)

let backoff_delay attempt =
  let base = Env_config.KeeperResidentSupervisor.backoff_base_s in
  let max_delay = Env_config.KeeperResidentSupervisor.backoff_max_s in
  Float.min max_delay (base *. Float.of_int (1 lsl (min attempt 20)))

let keep_last_n n item lst =
  let full = item :: lst in
  if List.length full <= n then full
  else List.filteri (fun i _ -> i < n) full

(* ── Event publishing ────────────────────────────────────── *)

let publish_lifecycle event_name keeper_name detail =
  match Keeper_keepalive.get_bus () with
  | Some bus ->
      Oas_events.publish_keeper_resident_lifecycle bus ~event:event_name
        ~keeper_name ~detail
  | None -> ()

(* ── Supervised fiber launch ─────────────────────────────── *)

let launch_supervised_fiber ~proactive_warmup_sec ctx (meta : keeper_meta)
    (reg : Keeper_registry.registry_entry) =
  Eio.Fiber.fork ~sw:ctx.sw (fun () ->
    Fun.protect
      (fun () ->
        Keeper_keepalive.run_heartbeat_loop ~proactive_warmup_sec
          ctx meta reg.fiber_stop ~wakeup:reg.fiber_wakeup;
        Keeper_registry.set_state ~base_path:ctx.config.base_path meta.name
          Keeper_registry.Stopped;
        Eio.Promise.resolve reg.done_r `Stopped;
        publish_lifecycle "stopped" meta.name "normal exit")
      ~finally:(fun () ->
        Keeper_registry.cleanup_tracking ~base_path:ctx.config.base_path meta.name;
        match Eio.Promise.peek reg.done_p with
        | Some _ -> ()  (* Already resolved in the normal path *)
        | None ->
            let msg = "fiber terminated without resolution" in
            Keeper_registry.record_crash ~base_path:ctx.config.base_path
              meta.name (Time_compat.now ()) msg;
            Keeper_registry.record_error ~base_path:ctx.config.base_path
              meta.name msg;
            Keeper_registry.set_state ~base_path:ctx.config.base_path meta.name
              Keeper_registry.Stopped;
            Eio.Promise.resolve reg.done_r (`Crashed msg);
            publish_lifecycle "crashed" meta.name msg))

let supervise_keepalive ~proactive_warmup_sec (ctx : _ context)
    (meta : keeper_meta) =
  if not meta.presence_keepalive then ()
  else if Keeper_registry.is_running ~base_path:ctx.config.base_path meta.name
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

let reconcile_desired_resident_keepers (ctx : _ context) =
  let base_path = ctx.config.base_path in
  Keeper_types.list_resident_keepers ctx.config
  |> List.iter (fun (spec : Keeper_types.resident_keeper_spec) ->
       if not spec.desired then ()
       else
         match read_meta ctx.config spec.persistent_name with
         | Ok (Some meta)
           when not meta.paused
                && meta.presence_keepalive
                && not (Keeper_registry.is_running ~base_path meta.name) ->
             supervise_keepalive ~proactive_warmup_sec:0 ctx meta;
             if Keeper_registry.is_running ~base_path meta.name then begin
               publish_lifecycle "reconciled" meta.name "late resident registration";
               Log.Keeper.info "%s: reconciled late resident keeper" meta.name
             end
         | _ -> ())
let sweep_and_recover (ctx : _ context) =
  let now = Time_compat.now () in
  let max_restarts = Env_config.KeeperResidentSupervisor.max_restarts in
  let base_path = ctx.config.base_path in
  reconcile_desired_resident_keepers ctx;
  let entries = Keeper_registry.all ~base_path () in
  let to_restart = ref [] in
  let to_unregister = ref [] in
  List.iter (fun (entry : Keeper_registry.registry_entry) ->
    match Eio.Promise.peek entry.done_p with
    | None -> ()  (* Alive — skip *)
    | Some `Stopped ->
        to_unregister := entry :: !to_unregister
    | Some (`Crashed msg) ->
        if entry.restart_count >= max_restarts then begin
          to_unregister := entry :: !to_unregister;
          publish_lifecycle "dead" entry.name
            (Printf.sprintf "restart budget exhausted (%d), last: %s"
               max_restarts msg);
          Log.Keeper.error "%s: restart budget exhausted (%d). Dead."
            entry.name max_restarts
        end else begin
          let delay = backoff_delay entry.restart_count in
          if now -. entry.last_restart_ts >= delay then
            to_restart := (entry, msg) :: !to_restart
        end
  ) entries;
  (* Clean up stopped/dead entries *)
  List.iter (fun (entry : Keeper_registry.registry_entry) ->
    Keeper_registry.unregister ~base_path entry.name
  ) !to_unregister;
  (* Restart zombies *)
  List.iter (fun ((old_entry : Keeper_registry.registry_entry), crash_msg) ->
    match read_meta ctx.config old_entry.name with
    | Ok (Some meta) ->
        let attempt = old_entry.restart_count + 1 in
        let old_crash_log = old_entry.crash_log in
        (* Re-register — fresh refs for the new fiber *)
        let reg =
          Keeper_registry.register ~base_path old_entry.name meta
        in
        (* Carry over supervisor history from previous entry *)
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
  ) !to_restart;
  reconcile_desired_resident_keepers ctx
