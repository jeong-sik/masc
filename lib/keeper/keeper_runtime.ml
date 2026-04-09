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

(** Apply a TOML profile default to a runtime meta value.
    [Some v] from TOML overrides; [None] keeps the current runtime value. *)
let apply_default opt current = match opt with Some v -> v | None -> current

(** Same as [apply_default] but both TOML and meta are option-typed. *)
let apply_default_opt opt current = match opt with Some _ -> opt | None -> current

let ensure_keeper_meta config name =
  match read_meta config name with
  | Ok (Some meta) ->
    (* Re-sync ALL declarative keeper fields from profile/env defaults on bootstrap.
       Persisted meta may have stale values from a previous session;
       persona config (TOML) plus explicit env overrides are the source of truth.
       Fields where TOML has [Some v] are overwritten; [None] keeps runtime value. *)
    let defaults = Keeper_types_profile.load_keeper_profile_defaults meta.name in

    (* --- Proactive --- *)
    let target_proactive =
      apply_default defaults.proactive_enabled Keeper_config.default_proactive_enabled in
    let target_idle_sec =
      apply_default defaults.proactive_idle_sec Keeper_config.default_proactive_idle_sec in
    let target_cooldown_sec =
      apply_default defaults.proactive_cooldown_sec Keeper_config.default_proactive_cooldown_sec in
    let target_room_signal_prompt_enabled =
      match Keeper_config.keeper_room_signal_prompt_enabled_override () with
      | Some override -> override
      | None ->
          Option.value ~default:Keeper_config.default_room_signal_prompt_enabled
            defaults.room_signal_prompt_enabled
    in
    let target_denylist = apply_default defaults.tool_denylist meta.tool_denylist in
    let target_cascade_name = apply_default defaults.cascade_name meta.cascade_name in

    (* --- Personality --- *)
    let target_goal = apply_default defaults.goal meta.goal in
    let target_short_goal = apply_default defaults.short_goal meta.short_goal in
    let target_mid_goal = apply_default defaults.mid_goal meta.mid_goal in
    let target_long_goal = apply_default defaults.long_goal meta.long_goal in
    let target_will = apply_default defaults.will meta.will in
    let target_needs = apply_default defaults.needs meta.needs in
    let target_desires = apply_default defaults.desires meta.desires in
    let target_instructions = apply_default defaults.instructions meta.instructions in

    (* --- Policy --- *)
    let target_policy_voice_enabled =
      apply_default defaults.policy_voice_enabled meta.policy_voice_enabled in
    let target_room_scope = apply_default defaults.room_scope meta.room_scope in
    let target_scope_kind = apply_default defaults.scope_kind meta.scope_kind in
    let target_mention_targets =
      match defaults.mention_targets with [] -> meta.mention_targets | xs -> xs in
    let target_execution_scope =
      apply_default defaults.execution_scope meta.execution_scope in
    let target_allowed_paths =
      apply_default defaults.allowed_paths meta.allowed_paths in

    (* --- Work Discovery --- *)
    let target_wd_enabled =
      apply_default_opt defaults.work_discovery_enabled meta.work_discovery_enabled in
    let target_wd_sources =
      apply_default_opt defaults.work_discovery_sources meta.work_discovery_sources in
    let target_wd_interval =
      apply_default_opt defaults.work_discovery_interval_sec meta.work_discovery_interval_sec in
    let target_wd_guidance =
      apply_default_opt defaults.work_discovery_guidance meta.work_discovery_guidance in

    (* --- Telemetry Feedback --- *)
    let target_tf_enabled =
      apply_default_opt defaults.telemetry_feedback_enabled meta.telemetry_feedback_enabled in
    let target_tf_window =
      apply_default_opt defaults.telemetry_feedback_window_hours meta.telemetry_feedback_window_hours in

    (* --- Change detection by category --- *)
    let proactive_changed =
      meta.proactive.enabled <> target_proactive
      || meta.proactive.idle_sec <> target_idle_sec
      || meta.proactive.cooldown_sec <> target_cooldown_sec in
    let signal_changed =
      meta.room_signal_prompt_enabled <> target_room_signal_prompt_enabled in
    let denylist_changed = meta.tool_denylist <> target_denylist in
    let cascade_changed = meta.cascade_name <> target_cascade_name in
    let personality_changed =
      meta.goal <> target_goal
      || meta.short_goal <> target_short_goal
      || meta.mid_goal <> target_mid_goal
      || meta.long_goal <> target_long_goal
      || meta.will <> target_will
      || meta.needs <> target_needs
      || meta.desires <> target_desires
      || meta.instructions <> target_instructions in
    let policy_changed =
      meta.policy_voice_enabled <> target_policy_voice_enabled
      || meta.room_scope <> target_room_scope
      || meta.scope_kind <> target_scope_kind
      || meta.mention_targets <> target_mention_targets
      || meta.execution_scope <> target_execution_scope
      || meta.allowed_paths <> target_allowed_paths in
    let discovery_changed =
      meta.work_discovery_enabled <> target_wd_enabled
      || meta.work_discovery_sources <> target_wd_sources
      || meta.work_discovery_interval_sec <> target_wd_interval
      || meta.work_discovery_guidance <> target_wd_guidance in
    let telemetry_changed =
      meta.telemetry_feedback_enabled <> target_tf_enabled
      || meta.telemetry_feedback_window_hours <> target_tf_window in
    let any_changed =
      proactive_changed || signal_changed || denylist_changed || cascade_changed
      || personality_changed || policy_changed || discovery_changed
      || telemetry_changed in

    if any_changed then begin
      let cats = List.filter_map Fun.id [
        (if proactive_changed then Some "proactive" else None);
        (if signal_changed then Some "signal" else None);
        (if denylist_changed then Some "denylist" else None);
        (if cascade_changed then Some "cascade" else None);
        (if personality_changed then Some "personality" else None);
        (if policy_changed then Some "policy" else None);
        (if discovery_changed then Some "discovery" else None);
        (if telemetry_changed then Some "telemetry" else None);
      ] in
      Log.Keeper.info
        "ensure_keeper_meta: re-syncing [%s] for %s"
        (String.concat "," cats)
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
        goal = target_goal;
        short_goal = target_short_goal;
        mid_goal = target_mid_goal;
        long_goal = target_long_goal;
        will = target_will;
        needs = target_needs;
        desires = target_desires;
        instructions = target_instructions;
        policy_voice_enabled = target_policy_voice_enabled;
        room_scope = target_room_scope;
        scope_kind = target_scope_kind;
        mention_targets = target_mention_targets;
        execution_scope = target_execution_scope;
        allowed_paths = target_allowed_paths;
        work_discovery_enabled = target_wd_enabled;
        work_discovery_sources = target_wd_sources;
        work_discovery_interval_sec = target_wd_interval;
        work_discovery_guidance = target_wd_guidance;
        telemetry_feedback_enabled = target_tf_enabled;
        telemetry_feedback_window_hours = target_tf_window;
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
          (* TOML hot-reload: re-sync declarative fields for running keepers.
             Runs after sweep_and_recover so TOML edits take effect within
             one sweep cycle (~30s) without server restart. *)
          (try
            Keeper_registry.all ~base_path ()
            |> List.iter (fun (entry : Keeper_registry.registry_entry) ->
              match entry.phase with
              | Keeper_state_machine.Running ->
                  (match ensure_keeper_meta ctx.config entry.name with
                   | Ok _meta -> ()
                   | Error e ->
                       Log.Keeper.warn "TOML reconcile failed for %s: %s"
                         entry.name e)
              | _ -> ())
           with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
             Log.Keeper.error "TOML reconcile sweep failed: %s"
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

let stop_keepalive name =
  Keeper_keepalive.stop_keepalive name

let reset_test_state base_path =
  stop_supervisor_sweep base_path;
  Hashtbl.remove existing_keepalive_bootstrap_done base_path
