(** Keeper_runtime — resident keeper reconciliation and keepalive bootstrap.
    Runtime-only mutable state stays behind keeper runtime/execution modules. *)

open Keeper_types
open Keeper_keepalive
open Keeper_exec_status

let maybe_promote_live_legacy_keeper config name =
  match read_meta config name with
  | Error _ | Ok None -> ()
  | Ok (Some meta) ->
      if is_resident_keeper config meta.name then ()
      else
        match parse_agent_status config ~agent_name:meta.agent_name with
        | `Assoc fields -> (
            let status =
              match List.assoc_opt "status" fields with
              | Some (`String value) -> String.lowercase_ascii value
              | _ -> "offline"
            in
            let agent_type =
              match List.assoc_opt "agent_type" fields with
              | Some (`String value) -> String.lowercase_ascii value
              | _ -> ""
            in
            if agent_type = "keeper" && List.mem status [ "active"; "busy"; "idle"; "listening" ] then
              ignore (register_resident_keeper_from_meta config meta))
        | _ -> ()

let ensure_resident_meta config (spec : resident_keeper_spec) =
  match read_meta config spec.persistent_name with
  | Ok (Some meta) -> Ok meta
  | Ok None -> (
      match meta_of_json spec.seed_meta with
      | Ok meta ->
          let meta =
            { meta with
              name = spec.persistent_name;
              agent_name = keeper_agent_name spec.persistent_name;
              updated_at = now_iso ();
            }
          in
          (match write_meta config meta with
          | Ok () -> Ok meta
          | Error msg -> Error msg)
      | Error msg -> Error msg)
  | Error msg -> Error msg

type keeper_bootstrap_stats = {
  enabled: bool;
  scanned: int;
  started: int;
  stale: int;
  recovering: int;
}

let bootstrap_existing_keepers ctx : keeper_bootstrap_stats =
  if not Env_config.KeeperBootstrap.enabled then
    { enabled = false; scanned = 0; started = 0; stale = 0; recovering = 0 }
  else
    let dir = keeper_dir ctx.config in
    (match Safe_ops.list_dir_safe dir with
    | Ok files ->
        files
        |> List.filter (fun f -> Filename.check_suffix f ".json")
        |> List.iter (fun f ->
               let name = Filename.remove_extension f in
               if validate_name name then maybe_promote_live_legacy_keeper ctx.config name)
    | Error _ -> ());
    let now_ts = Time_compat.now () in
    let proactive_warmup_sec = keeper_bootstrap_proactive_warmup_sec () in
    let stale_turn_sec =
      max 0.0 Env_config.KeeperBootstrap.stale_turn_seconds
    in
    let max_scan =
      max 0 Env_config.KeeperBootstrap.max_scan
    in
    let max_keepers = Env_config.KeeperBootstrap.max_active_keepers in
    let remaining_slots =
      ref
        (if max_keepers > 0 then
           max 0 (max_keepers - running_keepers ())
         else
           max_int)
    in
    let specs =
      list_resident_keepers ctx.config
      |> take max_scan
    in
    let (scanned, started, stale, recovering) =
      List.fold_left
        (fun (scanned_acc, started_acc, stale_acc, recovering_acc) spec ->
          match ensure_resident_meta ctx.config spec with
          | Error _ -> (scanned_acc + 1, started_acc, stale_acc, recovering_acc)
          | Ok m ->
              let stale_now =
                stale_turn_sec > 0.0
                && (m.last_turn_ts <= 0.0
                    || now_ts -. m.last_turn_ts >= stale_turn_sec)
              in
              let already_running = keeper_keepalive_running m.name in
              let started_here =
                if already_running then false
                else if max_keepers > 0 && !remaining_slots <= 0 then false
                else (
                  Keeper_resident_supervisor.supervise_keepalive
                    ~proactive_warmup_sec ctx m;
                  if max_keepers > 0 then remaining_slots := !remaining_slots - 1;
                  true
                )
              in
              ( scanned_acc + 1,
                started_acc + (if started_here then 1 else 0),
                stale_acc + (if stale_now then 1 else 0),
                recovering_acc + (if stale_now && started_here then 1 else 0) ))
        (0, 0, 0, 0)
        specs
    in
    { enabled = true; scanned; started; stale; recovering }

(** Start the supervisor sweep Pulse loop.
    Runs alongside existing keepalive bootstrap, scanning for
    zombie fibers and restarting them with exponential backoff.
    Called once from start_existing_keepalives after bootstrap. *)
let supervisor_sweeps : (string, Pulse.t) Hashtbl.t =
  Hashtbl.create 4

let supervisor_sweep_running base_path =
  match Hashtbl.find_opt supervisor_sweeps base_path with
  | Some pulse -> Pulse.is_alive pulse
  | None -> false

let start_supervisor_sweep ctx =
  let base_path = ctx.config.base_path in
  if supervisor_sweep_running base_path then ()
  else begin
    let consumer : (module Pulse.Consumer) =
      (module struct
        let name = "keeper-resident-supervisor-sweep"
        let should_act _beat = true
        let on_beat _beat =
          (try Keeper_resident_supervisor.sweep_and_recover ctx
           with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
             Log.Keeper.error "supervisor sweep failed: %s"
               (Printexc.to_string exn));
          Ok ()
      end)
    in
    let p = Pulse.create
      ~clock:ctx.clock
      ~rhythm:{ Pulse.base_s = Env_config.KeeperResidentSupervisor.sweep_interval_sec;
                 min_s = Env_config.KeeperResidentSupervisor.sweep_interval_sec;
                 max_s = Env_config.KeeperResidentSupervisor.sweep_interval_sec;
                 quiet = (0, 0) }
      ~lifecycle:Perpetual
      ~consumers:[consumer]
    in
    Hashtbl.replace supervisor_sweeps base_path p;
    Pulse.run ~sw:ctx.sw p;
    Log.Keeper.info "resident supervisor sweep started (interval %.0fs)"
      Env_config.KeeperResidentSupervisor.sweep_interval_sec
  end

let existing_keepalive_bootstrap_done : (string, unit) Hashtbl.t =
  Hashtbl.create 4

let maybe_start_supervisor_sweep ctx (stats : keeper_bootstrap_stats) =
  if stats.started > 0 || Keeper_resident_supervisor.supervised_count () > 0
  then start_supervisor_sweep ctx

let start_existing_keepalives ctx =
  let base_path = ctx.config.base_path in
  if Hashtbl.mem existing_keepalive_bootstrap_done base_path then ()
  else begin
    Hashtbl.replace existing_keepalive_bootstrap_done base_path ();
    try
      let stats = bootstrap_existing_keepers ctx in
      if keeper_debug then
        Log.Keeper.debug "bootstrap_existing_keepers enabled=%b scanned=%d started=%d stale=%d recovering=%d"
          stats.enabled stats.scanned stats.started stats.stale
          stats.recovering;
      maybe_start_supervisor_sweep ctx stats
    with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
      (* Retry bootstrap on next keeper tool call if this attempt failed. *)
      Hashtbl.remove existing_keepalive_bootstrap_done base_path;
      raise exn
  end

let stop_keepalive name =
  Keeper_keepalive.stop_keepalive name
