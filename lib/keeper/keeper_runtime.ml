(** Keeper_runtime — keeper reconciliation and keepalive bootstrap.
    Runtime-only mutable state stays behind keeper runtime/execution modules. *)

open Keeper_types

type boot_meta_resolution = {
  meta : keeper_meta;
  materialized : bool;
}

let bootable_keeper_names config =
  configured_keeper_names config
  |> List.filter (fun name ->
         match read_meta_file_path (keeper_meta_path config name) with
         | Ok (Some meta) -> not meta.paused && meta.autoboot_enabled
         | Ok None ->
             (match (load_keeper_profile_defaults name).autoboot_enabled with
              | Some false -> false
              | Some true | None -> true)
         | Error _ -> true)

(** Apply a TOML profile default to a runtime meta value.
    [Some v] from TOML overrides; [None] keeps the current runtime value. *)
let apply_default opt current = match opt with Some v -> v | None -> current

(** Same as [apply_default] but both TOML and meta are option-typed. *)
let apply_default_opt opt current = match opt with Some _ -> opt | None -> current

let contains_substring haystack needle =
  let haystack_len = String.length haystack in
  let needle_len = String.length needle in
  let rec loop idx =
    if needle_len = 0 then true
    else if idx + needle_len > haystack_len then false
    else if String.sub haystack idx needle_len = needle then true
    else loop (idx + 1)
  in
  loop 0

let invalid_profile_defaults_error ~keeper_name detail =
  if contains_substring detail "cascade_name" then
    Printf.sprintf
      "invalid profile.cascade_name for keeper %s: unknown cascade_name: %s"
      keeper_name detail
  else
    Printf.sprintf "invalid keeper profile for keeper %s: %s" keeper_name detail

let effective_declarative_cascade_name
    (defaults : Keeper_types_profile.keeper_profile_defaults)
    (meta : keeper_meta) =
  match defaults.cascade_name, defaults.manifest_path with
  | Some cascade_name, _ ->
      Keeper_cascade_profile.normalize_declared_name cascade_name
  | None, Some _ -> Keeper_config.default_cascade_name
  | None, None ->
      Keeper_cascade_profile.normalize_declared_name meta.cascade_name

let resynced_tool_access
    (defaults : Keeper_types_profile.keeper_profile_defaults)
    (meta : keeper_meta) =
  let current_preset =
    match meta.tool_access with
    | Preset { preset; _ } -> Some preset
    | Custom _ -> None
  in
  let current_also_allow = tool_access_also_allowlist meta.tool_access in
  let target_preset =
    match defaults.tool_preset with
    | Some raw -> tool_preset_of_string raw
    | None -> current_preset
  in
  let target_also_allow =
    apply_default defaults.tool_also_allow current_also_allow
  in
  match target_preset with
  | Some preset ->
      Preset { preset; also_allow = target_also_allow }
  | None -> meta.tool_access

let ensure_keeper_meta config name =
  match read_meta config name with
  | Ok (Some meta) ->
    (
    (* Re-sync ALL declarative keeper fields from profile/env defaults on bootstrap.
       Persisted meta may have stale values from a previous session;
       persona config (TOML) plus explicit env overrides are the source of truth.
       Fields where TOML has [Some v] are overwritten; [None] keeps runtime value. *)
    let defaults_result =
      Keeper_types_profile.load_keeper_profile_defaults_result meta.name
    in
    match defaults_result with
    | Error detail ->
        Error (invalid_profile_defaults_error ~keeper_name:meta.name detail)
    | Ok defaults ->

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
    let target_models = apply_default defaults.models meta.models in
    let target_social_model =
      apply_default defaults.social_model meta.social_model
      |> Keeper_social_model.normalize_social_model in
    let target_cascade_name =
      effective_declarative_cascade_name defaults meta
    in
    match
      Cascade_catalog_runtime.resolve_declared_name
        ~raw_name:target_cascade_name
        ()
    with
    | Error detail ->
        let field =
          match defaults.cascade_name, defaults.manifest_path with
          | Some _, _ -> "profile.cascade_name"
          | None, Some _ -> "manifest.default_cascade_name"
          | None, None -> "meta.cascade_name"
        in
        let raw_value =
          match defaults.cascade_name, defaults.manifest_path with
          | Some cascade_name, _ -> cascade_name
          | None, Some _ -> Keeper_config.default_cascade_name
          | None, None -> meta.cascade_name
        in
        let msg =
          Printf.sprintf
            "invalid %s %S for keeper %s: %s"
            field raw_value meta.name detail
        in
        Log.Keeper.error "%s" msg;
        Error msg
    | Ok resolved_target_cascade_name ->
    let target_tool_access = resynced_tool_access defaults meta in
    let target_tool_preset_source =
      match defaults.tool_preset_source with
      | Some _ as s -> s
      | None -> meta.tool_preset_source
    in

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
    let target_autoboot_enabled =
      apply_default defaults.autoboot_enabled meta.autoboot_enabled in
    let target_mention_targets =
      match defaults.mention_targets with [] -> meta.mention_targets | xs -> xs in
    let target_active_goal_ids =
      apply_default defaults.active_goal_ids meta.active_goal_ids in
    (* Infrastructure fields use system defaults when TOML is silent,
       so removing a key from TOML actually reverts the runtime value. *)
    let target_sandbox_profile =
      apply_default defaults.sandbox_profile Keeper_types_profile.default_sandbox_profile in
    let target_network_mode =
      apply_default defaults.network_mode
        (Keeper_types_profile.default_network_mode_for_profile target_sandbox_profile) in
    let target_shared_memory_scope =
      apply_default defaults.shared_memory_scope Keeper_types_profile.default_shared_memory_scope in
    let target_allowed_paths =
      apply_default defaults.allowed_paths [] in

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

    (* --- Per-Provider Timeout --- *)
    let target_per_provider_timeout =
      match defaults.per_provider_timeout_state with
      | Keeper_types_profile.Per_provider_timeout_unset ->
          normalize_per_provider_timeout_opt
            ~source:(Printf.sprintf "keeper runtime %s" name)
            meta.per_provider_timeout_s
      | Keeper_types_profile.Per_provider_timeout_invalid -> None
      | Keeper_types_profile.Per_provider_timeout_set ->
          defaults.per_provider_timeout
    in

    (* --- Always Approve --- *)
    let target_always_approve =
      apply_default_opt defaults.always_approve meta.always_approve
    in

    (* --- Change detection by category --- *)
    let proactive_changed =
      meta.proactive.enabled <> target_proactive
      || meta.proactive.idle_sec <> target_idle_sec
      || meta.proactive.cooldown_sec <> target_cooldown_sec in
    let signal_changed =
      meta.room_signal_prompt_enabled <> target_room_signal_prompt_enabled in
    let denylist_changed = meta.tool_denylist <> target_denylist in
    let models_changed = meta.models <> target_models in
    let social_model_changed = meta.social_model <> target_social_model in
    (* [meta.cascade_name] may be a raw TOML/JSON value while
       [resolved_target_cascade_name] is the validated runtime catalog
       name. Normalize the meta side only so alias cleanup does not
       register as a semantic change. *)
    let cascade_changed =
      Keeper_cascade_profile.normalize_declared_name meta.cascade_name
      <> resolved_target_cascade_name
    in
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
      || meta.autoboot_enabled <> target_autoboot_enabled
      || meta.mention_targets <> target_mention_targets
      || meta.active_goal_ids <> target_active_goal_ids
      || meta.tool_access <> target_tool_access
      || meta.tool_preset_source <> target_tool_preset_source
      || meta.sandbox_profile <> target_sandbox_profile
      || meta.network_mode <> target_network_mode
      || meta.shared_memory_scope <> target_shared_memory_scope
      || meta.allowed_paths <> target_allowed_paths
      || meta.always_approve <> target_always_approve in
    let discovery_changed =
      meta.work_discovery_enabled <> target_wd_enabled
      || meta.work_discovery_sources <> target_wd_sources
      || meta.work_discovery_interval_sec <> target_wd_interval
      || meta.work_discovery_guidance <> target_wd_guidance in
    let telemetry_changed =
      meta.telemetry_feedback_enabled <> target_tf_enabled
      || meta.telemetry_feedback_window_hours <> target_tf_window in
    let timeout_policy_changed =
      meta.per_provider_timeout_s <> target_per_provider_timeout in
    let any_changed =
      proactive_changed || signal_changed || denylist_changed || models_changed
      || social_model_changed
      || cascade_changed
      || personality_changed || policy_changed || discovery_changed
      || telemetry_changed || timeout_policy_changed in

    if any_changed then begin
      let cats = List.filter_map Fun.id [
        (if proactive_changed then Some "proactive" else None);
        (if signal_changed then Some "signal" else None);
        (if denylist_changed then Some "denylist" else None);
        (if models_changed then Some "models" else None);
        (if social_model_changed then Some "social_model" else None);
        (if cascade_changed then Some "cascade" else None);
        (if personality_changed then Some "personality" else None);
        (if policy_changed then Some "policy" else None);
        (if discovery_changed then Some "discovery" else None);
        (if telemetry_changed then Some "telemetry" else None);
        (if timeout_policy_changed then Some "timeout_policy" else None);
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
        models = target_models;
        social_model = target_social_model;
        (* Preserve raw [meta.cascade_name] when the cascade itself did
           not change, even if another field (personality, policy, ...)
           triggered a re-sync.  Otherwise a reconcile caused by an
           unrelated field would silently canonicalize cascade_name and
           hide drift from the dashboard [canonical] column. *)
        cascade_name =
          if cascade_changed then resolved_target_cascade_name
          else meta.cascade_name;
        goal = target_goal;
        short_goal = target_short_goal;
        mid_goal = target_mid_goal;
        long_goal = target_long_goal;
        will = target_will;
        needs = target_needs;
        desires = target_desires;
        instructions = target_instructions;
        policy_voice_enabled = target_policy_voice_enabled;
        autoboot_enabled = target_autoboot_enabled;
        mention_targets = target_mention_targets;
        active_goal_ids = target_active_goal_ids;
        tool_access = target_tool_access;
        tool_preset_source = target_tool_preset_source;
        sandbox_profile = target_sandbox_profile;
        network_mode = target_network_mode;
        shared_memory_scope = target_shared_memory_scope;
        allowed_paths = target_allowed_paths;
        work_discovery_enabled = target_wd_enabled;
        work_discovery_sources = target_wd_sources;
        work_discovery_interval_sec = target_wd_interval;
        work_discovery_guidance = target_wd_guidance;
        telemetry_feedback_enabled = target_tf_enabled;
        telemetry_feedback_window_hours = target_tf_window;
        per_provider_timeout_s = target_per_provider_timeout;
        always_approve = target_always_approve;
        updated_at = now_iso ();
      } in
      match write_meta config updated with
      | Ok () -> Ok updated
      | Error e ->
        Log.Keeper.warn "ensure_keeper_meta: write_meta re-sync failed: %s" e;
        Ok meta
    end
    else Ok meta)
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
    let max_keepers = Keeper_runtime_resolved.bootstrap_max_active_keepers () in
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
                   | Ok updated_meta ->
                       (* Propagate the updated meta back into the registry so
                          subsequent turns observe the new cascade_name (and
                          any other reconciled fields) immediately.  Without
                          this the file is updated but the in-memory
                          [registry_entry.meta] stays stale until restart. *)
                       Keeper_registry.update_meta ~base_path entry.name updated_meta
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

let stop_keepalive ?base_path name =
  Keeper_keepalive.stop_keepalive ?base_path name

let reset_test_state base_path =
  stop_supervisor_sweep base_path;
  Hashtbl.remove existing_keepalive_bootstrap_done base_path
