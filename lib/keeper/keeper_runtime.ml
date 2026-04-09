(** Keeper_runtime — keeper reconciliation and keepalive bootstrap.
    Runtime-only mutable state stays behind keeper runtime/execution modules. *)

open Keeper_types

type boot_meta_resolution = {
  meta : keeper_meta;
  materialized : bool;
}

let declarative_keeper_names () =
  Config_dir_resolver.log_warnings ~context:"KeeperRuntime" ();
  Keeper_types_profile.discover_keepers_toml (Config_dir_resolver.keepers_dir ())
  |> List.map fst

let bootable_keeper_names config =
  dedupe_keep_order (keeper_names config @ declarative_keeper_names ())

let ensure_keeper_meta config name =
  match read_meta config name with
  | Ok (Some meta) ->
    (* Re-sync declarative keeper flags from profile/env defaults on bootstrap.
       Persisted meta may have stale values from a previous session;
       persona config plus explicit env overrides are the source of truth. *)
    let defaults = Keeper_types_profile.load_keeper_profile_defaults meta.name in
    let target_proactive =
      match defaults.proactive_enabled with
      | Some v -> v
      | None -> Keeper_config.default_proactive_enabled
    in
    let target_idle_sec =
      match defaults.proactive_idle_sec with
      | Some v -> v
      | None -> Keeper_config.default_proactive_idle_sec
    in
    let target_cooldown_sec =
      match defaults.proactive_cooldown_sec with
      | Some v -> v
      | None -> Keeper_config.default_proactive_cooldown_sec
    in
    let target_room_signal_prompt_enabled =
      match Keeper_config.keeper_room_signal_prompt_enabled_override () with
      | Some override -> override
      | None ->
          Option.value ~default:Keeper_config.default_room_signal_prompt_enabled
            defaults.room_signal_prompt_enabled
    in
    let target_denylist =
      match defaults.tool_denylist with
      | Some dl -> dl
      | None -> meta.tool_denylist
    in
    let target_cascade_name =
      match defaults.cascade_name with
      | Some name -> name
      | None -> meta.cascade_name
    in
    let denylist_changed = meta.tool_denylist <> target_denylist in
    let cascade_changed = meta.cascade_name <> target_cascade_name in
    let proactive_timers_changed =
      meta.proactive.idle_sec <> target_idle_sec
      || meta.proactive.cooldown_sec <> target_cooldown_sec
    in
    if meta.proactive.enabled <> target_proactive
       || proactive_timers_changed
       || meta.room_signal_prompt_enabled <> target_room_signal_prompt_enabled
       || denylist_changed
       || cascade_changed then begin
      Log.Keeper.info
        "ensure_keeper_meta: re-syncing proactive.enabled %b -> %b, idle_sec %d -> %d, cooldown_sec %d -> %d, room_signal_prompt_enabled %b -> %b, denylist_changed %b, cascade %s -> %s for %s"
        meta.proactive.enabled target_proactive
        meta.proactive.idle_sec target_idle_sec
        meta.proactive.cooldown_sec target_cooldown_sec
        meta.room_signal_prompt_enabled target_room_signal_prompt_enabled
        denylist_changed
        meta.cascade_name target_cascade_name
        meta.name;
      let updated = { meta with
        proactive = {
          enabled = target_proactive;
          idle_sec = target_idle_sec;
          cooldown_sec = target_cooldown_sec;
        };
        room_signal_prompt_enabled = target_room_signal_prompt_enabled;
        tool_denylist = target_denylist;
        cascade_name = target_cascade_name;
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

let load_or_materialize_boot_meta (ctx : _ context) name
    : (boot_meta_resolution, string) result =
  match ensure_keeper_meta ctx.config name with
  | Ok meta -> Ok { meta; materialized = false }
  | Error original_error -> (
      match Config_dir_resolver.keeper_toml_path_opt name with
      | None -> Error original_error
      | Some toml_path ->
          Log.Keeper.info
            "bootstrapping declarative keeper %s from %s"
            name toml_path;
          let ok, body =
            Keeper_turn.handle_keeper_up ctx
              (`Assoc [ ("name", `String name) ])
          in
          if not ok then
            Error
              (Printf.sprintf
                 "failed to materialize declarative keeper %s from %s: %s"
                 name toml_path body)
          else
            match read_meta ctx.config name with
            | Ok (Some meta) -> Ok { meta; materialized = true }
            | Ok None ->
                Error
                  (Printf.sprintf
                     "materialized declarative keeper %s from %s but no meta was written"
                     name toml_path)
            | Error msg ->
                Error
                  (Printf.sprintf
                     "materialized declarative keeper %s from %s but failed to reload meta: %s"
                     name toml_path msg))

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
    let entries = bootable_keeper_names ctx.config |> take max_scan in
    let (enabled, scanned, started, stale, recovering) =
      List.fold_left
        (fun (enabled_acc, scanned_acc, started_acc, stale_acc, recovering_acc) name ->
          match load_or_materialize_boot_meta ctx name with
          | Error _ ->
              (enabled_acc, scanned_acc + 1, started_acc, stale_acc, recovering_acc)
          | Ok { meta = m; materialized } ->
              if m.paused then
                (enabled_acc, scanned_acc + 1, started_acc, stale_acc, recovering_acc)
              else
              let stale_now =
                (not materialized)
                && stale_turn_sec > 0.0
                && (m.runtime.usage.last_turn_ts <= 0.0
                    || now_ts -. m.runtime.usage.last_turn_ts >= stale_turn_sec)
              in
              let already_running =
                Keeper_registry.is_running ~base_path:ctx.config.base_path m.name
              in
              let started_here =
                if materialized then
                  let started_now =
                    Keeper_registry.is_running
                      ~base_path:ctx.config.base_path m.name
                  in
                  if started_now && max_keepers > 0 then
                    remaining_slots := max 0 (!remaining_slots - 1);
                  started_now
                else if already_running then false
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

let update_supervisor_sweep_interval base_path interval_sec =
  with_sweeps_ro (fun () ->
    match Hashtbl.find_opt supervisor_sweeps base_path with
    | Some pulse ->
      let rhythm : Pulse.rhythm =
        { base_s = interval_sec; min_s = interval_sec;
          max_s = interval_sec; quiet = (0, 0) }
      in
      Pulse.set_rhythm pulse rhythm;
      true
    | None -> false)

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
    let sweep_sec = Runtime_params.get Governance_registry.keeper_supervisor_sweep_sec in
    let p = Pulse.create
      ~clock:ctx.clock
      ~rhythm:{ Pulse.base_s = sweep_sec;
                 min_s = sweep_sec;
                 max_s = sweep_sec;
                 quiet = (0, 0) }
      ~lifecycle:Always_on
      ~consumers:[consumer]
    in
    with_sweeps_rw (fun () ->
      Hashtbl.replace supervisor_sweeps base_path p);
    Pulse.run ~sw:ctx.sw p;
    Log.Keeper.info "keeper supervisor sweep started (interval %.0fs)" sweep_sec
  end

let existing_keepalive_bootstrap_done : (string, unit) Hashtbl.t =
  Hashtbl.create 4

let has_boot_entries config =
  bootable_keeper_names config <> []

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

let stop_keepalive ?base_path name =
  Keeper_keepalive.stop_keepalive ?base_path name

let reset_test_state base_path =
  stop_supervisor_sweep base_path;
  Hashtbl.remove existing_keepalive_bootstrap_done base_path
