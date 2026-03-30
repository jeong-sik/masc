(** Keeper_runtime — keeper reconciliation and keepalive bootstrap.
    Runtime-only mutable state stays behind keeper runtime/execution modules. *)

open Keeper_types

let maybe_promote_live_persistent_keeper config name =
  ignore config;
  ignore name

let ensure_keeper_meta config name =
  match read_meta config name with
  | Ok (Some meta) ->
    (* Re-sync proactive_enabled from persona defaults on bootstrap.
       Persisted meta may have stale values from a previous session;
       persona config is the source of truth for declarative settings. *)
    let defaults = Keeper_types_profile.load_keeper_profile_defaults meta.name in
    let target_proactive =
      match defaults.proactive_enabled with
      | Some v -> v
      | None -> Keeper_config.default_proactive_enabled
    in
    let target_tool_tier =
      Option.value ~default:"essential" defaults.tool_tier
    in
    let target_extra_masc_tools =
      Option.value ~default:[] defaults.extra_masc_tools
    in
    let needs_update =
      meta.proactive.enabled <> target_proactive
      || meta.tool_tier <> target_tool_tier
      || meta.extra_masc_tools <> target_extra_masc_tools
    in
    if needs_update then begin
      if meta.proactive.enabled <> target_proactive then
        Log.Keeper.info "ensure_keeper_meta: re-syncing proactive.enabled %b -> %b for %s"
          meta.proactive.enabled target_proactive meta.name;
      if meta.tool_tier <> target_tool_tier then
        Log.Keeper.info "ensure_keeper_meta: re-syncing tool_tier %s -> %s for %s"
          meta.tool_tier target_tool_tier meta.name;
      let updated = { meta with
        proactive = { meta.proactive with enabled = target_proactive };
        tool_tier = target_tool_tier;
        extra_masc_tools = target_extra_masc_tools;
        updated_at = now_iso ();
      } in
      match write_meta config updated with
      | Ok () -> Ok updated
      | Error e ->
        Log.Keeper.warn "ensure_keeper_meta: write_meta re-sync failed: %s" e;
        Ok meta
    end
    else Ok meta
  | Ok None ->
    Log.Keeper.warn
      "ensure_keeper_meta: no persistent meta for %s — run keeper_up to initialize" name;
    Error (Printf.sprintf "no persistent meta for %s — run keeper_up to initialize" name)
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
           max 0 (max_keepers - Keeper_registry.count_running ())
         else
           max_int)
    in
    let entries =
      keeper_names ctx.config
      |> take max_scan
    in
    let (enabled, scanned, started, stale, recovering) =
      List.fold_left
        (fun (enabled_acc, scanned_acc, started_acc, stale_acc, recovering_acc) name ->
          match ensure_keeper_meta ctx.config name with
          | Error _ ->
              (enabled_acc, scanned_acc + 1, started_acc, stale_acc, recovering_acc)
          | Ok m ->
              if m.paused then
                (enabled_acc, scanned_acc + 1, started_acc, stale_acc, recovering_acc)
              else
              let stale_now =
                stale_turn_sec > 0.0
                && (m.runtime.usage.last_turn_ts <= 0.0
                    || now_ts -. m.runtime.usage.last_turn_ts >= stale_turn_sec)
              in
              let already_running =
                Keeper_registry.is_running ~base_path:ctx.config.base_path m.name
              in
              let started_here =
                if already_running then false
                else if max_keepers > 0 && !remaining_slots <= 0 then false
                else (
                  Keeper_supervisor.supervise_keepalive
                    ~proactive_warmup_sec ctx m;
                  let started_now =
                    Keeper_registry.is_running
                      ~base_path:ctx.config.base_path m.name
                  in
                  if started_now && max_keepers > 0 then
                    remaining_slots := !remaining_slots - 1;
                  started_now
                )
              in
              ( true,
                scanned_acc + 1,
                started_acc + (if started_here then 1 else 0),
                stale_acc + (if stale_now then 1 else 0),
                recovering_acc + (if stale_now && started_here then 1 else 0) ))
        (false, 0, 0, 0, 0)
        entries
    in
    { enabled; scanned; started; stale; recovering }

(** Start the supervisor sweep Pulse loop.
    Runs alongside existing keepalive bootstrap, scanning for
    zombie fibers and restarting them with exponential backoff.
    Called once from start_existing_keepalives after bootstrap. *)
let supervisor_sweeps : (string, Pulse.t) Hashtbl.t =
  Hashtbl.create 4
let supervisor_sweeps_mu = Eio.Mutex.create ()

let with_sweeps_ro f = Eio_guard.with_mutex_ro supervisor_sweeps_mu f
let with_sweeps_rw f = Eio_guard.with_mutex supervisor_sweeps_mu f

let supervisor_sweep_running base_path =
  with_sweeps_ro (fun () ->
    match Hashtbl.find_opt supervisor_sweeps base_path with
    | Some pulse -> Pulse.is_alive pulse
    | None -> false)

let stop_supervisor_sweep base_path =
  with_sweeps_rw (fun () ->
    match Hashtbl.find_opt supervisor_sweeps base_path with
    | Some pulse ->
      Pulse.shutdown pulse;
      Hashtbl.remove supervisor_sweeps base_path
    | None -> ())

let start_supervisor_sweep ctx =
  let base_path = ctx.config.base_path in
  if supervisor_sweep_running base_path then ()
  else begin
    let consumer : (module Pulse.Consumer) =
      (module struct
        let name = "keeper-supervisor-sweep"
        let should_act _beat = true
        let on_beat _beat =
          (try Keeper_supervisor.sweep_and_recover ctx
           with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
             Log.Keeper.error "supervisor sweep failed: %s"
               (Printexc.to_string exn));
          Ok ()
      end)
    in
    let p = Pulse.create
      ~clock:ctx.clock
      ~rhythm:{ Pulse.base_s = Env_config.KeeperSupervisor.sweep_interval_sec;
                 min_s = Env_config.KeeperSupervisor.sweep_interval_sec;
                 max_s = Env_config.KeeperSupervisor.sweep_interval_sec;
                 quiet = (0, 0) }
      ~lifecycle:Perpetual
      ~consumers:[consumer]
    in
    with_sweeps_rw (fun () ->
      Hashtbl.replace supervisor_sweeps base_path p);
    Pulse.run ~sw:ctx.sw p;
    Log.Keeper.info "keeper supervisor sweep started (interval %.0fs)"
      Env_config.KeeperSupervisor.sweep_interval_sec
  end

let existing_keepalive_bootstrap_done : (string, unit) Hashtbl.t =
  Hashtbl.create 4

let has_boot_entries config =
  keepalive_keeper_names config <> []

let maybe_start_supervisor_sweep ctx (stats : keeper_bootstrap_stats) =
  if stats.enabled
     && (stats.started > 0
         || Keeper_registry.count_running ~base_path:ctx.config.base_path () > 0
         || has_boot_entries ctx.config)
  then start_supervisor_sweep ctx

let start_existing_keepalives ctx =
  let base_path = ctx.config.base_path in
  (* Atomic check-and-set: eliminates TOCTOU race on the gate. *)
  let should_run =
    if Hashtbl.mem existing_keepalive_bootstrap_done base_path then false
    else begin
      Hashtbl.replace existing_keepalive_bootstrap_done base_path ();
      true
    end
  in
  if not should_run then ()
  else begin
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

let reset_test_state base_path =
  stop_supervisor_sweep base_path;
  Hashtbl.remove existing_keepalive_bootstrap_done base_path
