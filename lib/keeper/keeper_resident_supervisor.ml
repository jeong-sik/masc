(** Keeper_resident_supervisor — resident keepalive fiber supervision.

    Supervises the MASC-owned background keepalive fibers that maintain
    keeper presence and heartbeat snapshots. This is not the OAS [Agent.run]
    lifecycle; it sits outside the turn loop and only manages resident
    liveness/restart policy for keepalive work.

    @since 2.102.0 *)

open Keeper_types
open Keeper_execution

(* ── Internal Types ──────────────────────────────────────── *)

type supervised_entry = {
  name : string;
  stop : bool ref;
  started_at : float; [@warning "-69"]
  done_p : [ `Stopped | `Crashed of string ] Eio.Promise.t;
  done_r : [ `Stopped | `Crashed of string ] Eio.Promise.u;
  restart_count : int ref;
  last_restart_ts : float ref;
  crash_log : (float * string) list ref;
}

(* ── Public query type ───────────────────────────────────── *)

type supervised_state = {
  name : string;
  fiber_health : fiber_health;
  restart_count : int;
  last_restart_ts : float;
  crash_log : (float * string) list;
}

(* ── Registries ──────────────────────────────────────────── *)

let supervised_registry : (string, supervised_entry) Hashtbl.t =
  Hashtbl.create 8

let bus_ref : Agent_sdk.Event_bus.t option ref = ref None

let init ~bus =
  bus_ref := Some bus

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
  match !bus_ref with
  | Some bus ->
      Oas_events.publish_keeper_resident_lifecycle bus ~event:event_name
        ~keeper_name ~detail
  | None -> ()

(* ── Fiber health queries ────────────────────────────────── *)

let fiber_health_of name =
  match Hashtbl.find_opt supervised_registry name with
  | None -> Fiber_unknown
  | Some entry ->
      match Eio.Promise.peek entry.done_p with
      | None -> Fiber_alive
      | Some `Stopped -> Fiber_unknown  (* cleaned up by sweep *)
      | Some (`Crashed _) ->
          if !(entry.restart_count) >= Env_config.KeeperResidentSupervisor.max_restarts
          then Fiber_dead
          else Fiber_zombie

let supervised_state_of name =
  match Hashtbl.find_opt supervised_registry name with
  | None -> None
  | Some entry ->
      Some {
        name = entry.name;
        fiber_health = fiber_health_of name;
        restart_count = !(entry.restart_count);
        last_restart_ts = !(entry.last_restart_ts);
        crash_log = !(entry.crash_log);
      }

let crash_log_of name =
  match Hashtbl.find_opt supervised_registry name with
  | None -> []
  | Some entry -> !(entry.crash_log)

let supervised_count () = Hashtbl.length supervised_registry

(* ── Supervised fiber launch ─────────────────────────────── *)

let launch_supervised_fiber ~proactive_warmup_sec ctx (meta : keeper_meta) entry =
  Eio.Fiber.fork ~sw:ctx.sw (fun () ->
    Fun.protect
      (fun () ->
        Keeper_keepalive.run_heartbeat_loop ~proactive_warmup_sec
          ctx meta entry.stop;
        Eio.Promise.resolve entry.done_r `Stopped;
        publish_lifecycle "stopped" meta.name "normal exit")
      ~finally:(fun () ->
        Keeper_keepalive.unregister_keepalive meta.name;
        match Eio.Promise.peek entry.done_p with
        | Some _ -> ()  (* Already resolved in the normal path *)
        | None ->
            let msg = "fiber terminated without resolution" in
            entry.crash_log :=
              keep_last_n 5 (Time_compat.now (), msg) !(entry.crash_log);
            Eio.Promise.resolve entry.done_r (`Crashed msg);
            publish_lifecycle "crashed" meta.name msg))

let supervise_keepalive ~proactive_warmup_sec (ctx : _ context)
    (meta : keeper_meta) =
  if not meta.presence_keepalive then ()
  else if Hashtbl.mem supervised_registry meta.name then ()
  else if not (Keeper_keepalive.keeper_spawn_slots_available ()) then ()
  else begin
    let stop = ref false in
    let now = Time_compat.now () in
    let done_p, done_r = Eio.Promise.create () in
    let entry = {
      name = meta.name;
      stop; started_at = now;
      done_p; done_r;
      restart_count = ref 0;
      last_restart_ts = ref 0.0;
      crash_log = ref [];
    } in
    Hashtbl.replace supervised_registry meta.name entry;
    (* Backward compat: register in legacy keepalive registry *)
    Keeper_keepalive.register_keepalive meta.name
      { Keeper_keepalive.stop; started_at = now };
    (* Room initialization *)
    (try
       if not (Room_utils.is_initialized ctx.config) then
         ignore (Room.init ctx.config ~agent_name:None)
     with exn ->
       Log.Keeper.error "supervisor room init failed: %s"
         (Printexc.to_string exn));
    (* Presence sync *)
    (try
       let synced = ensure_keeper_room_presence ctx.config meta in
       ignore (write_meta ctx.config synced)
     with exn ->
       Log.Keeper.error "supervisor presence sync failed: %s"
         (Printexc.to_string exn));
    publish_lifecycle "started" meta.name "supervised";
    launch_supervised_fiber ~proactive_warmup_sec ctx meta entry
  end

(* ── Sweep and recover ───────────────────────────────────── *)

let sweep_and_recover (ctx : _ context) =
  let now = Time_compat.now () in
  let max_restarts = Env_config.KeeperResidentSupervisor.max_restarts in
  let to_restart = ref [] in
  let to_remove = ref [] in
  Hashtbl.iter (fun name entry ->
    match Eio.Promise.peek entry.done_p with
    | None -> ()  (* Alive — skip *)
    | Some `Stopped ->
        to_remove := name :: !to_remove
    | Some (`Crashed msg) ->
        if !(entry.restart_count) >= max_restarts then begin
          to_remove := name :: !to_remove;
          publish_lifecycle "dead" name
            (Printf.sprintf "restart budget exhausted (%d), last: %s"
               max_restarts msg);
          Log.Keeper.error "%s: restart budget exhausted (%d). Dead."
            name max_restarts
        end else begin
          let delay = backoff_delay !(entry.restart_count) in
          if now -. !(entry.last_restart_ts) >= delay then
            to_restart := (name, entry, msg) :: !to_restart
        end
  ) supervised_registry;
  (* Clean up stopped/dead entries *)
  List.iter (fun name -> Hashtbl.remove supervised_registry name) !to_remove;
  (* Restart zombies *)
  List.iter (fun (name, (old_entry : supervised_entry), crash_msg) ->
    match read_meta ctx.config name with
    | Ok (Some meta) ->
        let attempt = !(old_entry.restart_count) + 1 in
        let done_p, done_r = Eio.Promise.create () in
        let new_entry = {
          name;
          stop = ref false;
          started_at = now;
          done_p; done_r;
          restart_count = ref attempt;
          last_restart_ts = ref now;
          crash_log = ref (keep_last_n 5 (now, crash_msg) !(old_entry.crash_log));
        } in
        Hashtbl.replace supervised_registry name new_entry;
        Keeper_keepalive.register_keepalive name
          { Keeper_keepalive.stop = new_entry.stop; started_at = now };
        launch_supervised_fiber ~proactive_warmup_sec:0 ctx meta new_entry;
        publish_lifecycle "restarted" name
          (Printf.sprintf "attempt %d" attempt);
        Log.Keeper.info "%s: restarted (attempt %d, backoff %.0fs)"
          name attempt (backoff_delay (attempt - 1))
    | _ ->
        Log.Keeper.error "%s: cannot read meta for restart, removing" name;
        Hashtbl.remove supervised_registry name
  ) !to_restart
