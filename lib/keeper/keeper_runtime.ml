(** Keeper_runtime — keeper reconciliation and keepalive bootstrap.
    Runtime-only mutable state stays behind keeper runtime/execution modules. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_meta_store
open Keeper_types_profile

(** #10061: compare personality text fields ignoring leading/trailing
    whitespace.  The TOML heredoc parser drops the newline before the
    closing triple-quote; the state JSON writer preserves the in-
    memory value.  That 1-byte drift drives a re-sync storm on every
    hot-reload tick unless the compare normalizes whitespace.

    Layer 1 (personality SSOT unification, see
    [planning/2026-04-25-keeper-identity-canonicalization-rfc.md]):
    [String.trim] alone is insufficient — when the persisted text
    exceeds [Keeper_config.prompt_render_max_bytes] (e.g. nick0cave's
    357-byte will), the read path normalises to ~319 bytes via
    [normalize_self_model_text], while [target_will] computed from
    [apply_default defaults.will meta.will] keeps the raw 357-byte
    value.  trim-only compare flagged that 38-byte gap as drift on
    every reconcile tick (~2880 redundant writes/day for nick0cave).
    Apply the same byte-cap normalisation on both sides so write
    preserves disk-of-record (raw bytes), but compare uses the
    capped form that the prompt actually renders.  Disk data is
    preserved; loop terminates. *)
let personality_text_equal =
  Keeper_runtime_personality_diff.personality_text_equal
let personality_field_diff_entry =
  Keeper_runtime_personality_diff.personality_field_diff_entry
let personality_diff_summary =
  Keeper_runtime_personality_diff.personality_diff_summary
let personality_field_diff_summary =
  Keeper_runtime_personality_diff.personality_field_diff_summary


type boot_meta_resolution = {
  meta : keeper_meta;
  materialized : bool;
}

type autoboot_exclusion = {
  keeper_name : string;
  reason : string;
}

let autoboot_exclusion_reason config name =
  match read_meta_file_path (keeper_meta_path config name) with
  | Ok (Some meta) ->
    if meta.paused then Some "paused"
    else
      (match (load_keeper_profile_defaults name).autoboot_enabled with
       | Some true -> None
       | Some false -> Some "declarative_autoboot_disabled"
       | None ->
         if meta.autoboot_enabled then None else Some "autoboot_disabled")
  | Ok None ->
    (match (load_keeper_profile_defaults name).autoboot_enabled with
     | Some false -> Some "declarative_autoboot_disabled"
     | Some true | None -> None)
  | Error _ ->
    (* Preserve existing behavior: corrupt/unreadable meta still enters the
       boot path so load_or_materialize_boot_meta can emit the precise error. *)
    None

let bootable_keeper_names config =
  configured_keeper_names config
  |> List.filter (fun name -> Option.is_none (autoboot_exclusion_reason config name))

let autoboot_excluded_keeper_reasons config =
  configured_keeper_names config
  |> List.filter_map (fun name ->
       match autoboot_exclusion_reason config name with
       | Some reason -> Some { keeper_name = name; reason }
       | None -> None)

let auto_recoverable_paused_keeper_names ?now config =
  let now =
    match now with
    | Some value -> value
    | None ->
      (* NDT-OK: cold-start supervisor admission uses wall-clock pause age to decide whether the recovery sweep must run. *)
      Unix.gettimeofday ()
  in
  configured_keeper_names config
  |> List.filter_map (fun name ->
       match read_meta_file_path (keeper_meta_path config name) with
       | Ok (Some meta)
         when meta.paused
              &&
              (match (load_keeper_profile_defaults name).autoboot_enabled with
               | Some value -> value
               | None -> meta.autoboot_enabled)
              && Keeper_supervisor_types.paused_meta_auto_resume_due ~now meta ->
         Some meta.name
       | Ok (Some _) | Ok None -> None
       | Error msg ->
         Otel_metric_store.inc_counter
           Keeper_metrics.(to_string MetaReadFailures)
           ~labels:[ ("keeper", name); ("site", "auto_recoverable_paused_read") ]
           ();
         Log.Keeper.warn
           "auto_recoverable_paused_keeper_names: meta read failed for %s: %s"
           name
           msg;
         None)

(* PR-3b1: convert a credential lookup name to its canonical
   keeper-<n>-agent form when it refers to a bootable keeper.
   Non-keeper names (dashboard, admin, external MCP clients, ...) are
   returned unchanged so this is safe to apply at any lookup site.
   Spec: AuthIdentityFSM.tla I1 IdentityBindsToken (a token must
   bind to one principal -- the bare-name lookup path that
   scaffolded dual-identity is starved by callers always asking for
   the canonical form). *)
let canonicalize_if_keeper config name =
  let stable = Option.value (Keeper_identity.strip_keeper_prefix name) ~default:name in
  if List.mem stable (configured_keeper_names config) then
    Keeper_identity.keeper_agent_name stable
  else
    name

(** Apply a TOML profile default to a runtime meta value.
    [Some v] from TOML overrides; [None] keeps the current runtime value. *)
let apply_default opt current = match opt with Some v -> v | None -> current

(** Same as [apply_default] but both TOML and meta are option-typed. *)
let apply_default_opt opt current = match opt with Some _ -> opt | None -> current


let invalid_profile_defaults_error ~keeper_name detail =
  if String_util.contains_substring detail "runtime_id" then
    Printf.sprintf
      "invalid profile.runtime_id for keeper %s: unknown runtime_id: %s"
      keeper_name detail
  else
    Printf.sprintf "invalid keeper profile for keeper %s: %s" keeper_name detail

let effective_declarative_runtime_id
    (_defaults : Keeper_types_profile.keeper_profile_defaults)
    (meta : keeper_meta) =
  (* persona⊥{model,runtime}: the keeper's runtime is assigned in runtime.toml,
     not in [defaults].  Delegate to {!Keeper_meta_contract.runtime_id_of_meta}
     (the dispatcher) so the declare/status view and the wire share ONE source
     by construction — divergence is structurally impossible, not convention-
     enforced (prevents the reconcile re-sync storm, cf. #10061).  [_defaults]
     is retained in the signature for caller call-sites but no longer carries a
     runtime selection. *)
  runtime_id_of_meta meta

let resynced_tool_access
    (defaults : Keeper_types_profile.keeper_profile_defaults)
    (meta : keeper_meta) =
  match defaults.tool_access with
  | Some tools -> normalize_tool_names tools
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
    let target_tool_access = resynced_tool_access defaults meta in
    let target_denylist = apply_default defaults.tool_denylist meta.tool_denylist in
    let target_social_model =
      apply_default defaults.social_model meta.social_model
      |> Keeper_social_model.normalize_social_model in
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
    let target_autoboot_enabled =
      apply_default defaults.autoboot_enabled meta.autoboot_enabled in
    let target_mention_targets =
      match defaults.mention_targets with [] -> meta.mention_targets | xs -> xs in
    let target_active_goal_ids =
      apply_default defaults.active_goal_ids meta.active_goal_ids in
    (* Defense-in-depth (#11080 sibling): keeper sandbox_profile MUST be
       declared. The previous behaviour silently fell through to
       [default_sandbox_profile = Local] when TOML omitted the key,
       which strips docker isolation from any operator who forgets to
       set it (or copies a stale persona JSON: persona profiles are
       declared elsewhere as not allowed to own this field). Reject at
       reconcile time so the keeper visibly fails to boot rather than
       running un-sandboxed.

       Persona-only keepers cannot satisfy this check today and must
       gain a TOML wrapper that sets [sandbox_profile]. The
       [Keeper_types_profile.default_sandbox_profile] constant is left
       in place because other read paths (JSON parser, env override,
       turn_up_args) still need a value when reading already-persisted
       meta. *)
    let target_sandbox_profile_result =
      match defaults.sandbox_profile with
      | Some sp -> Ok sp
      | None ->
        let manifest_hint =
          match defaults.manifest_path with
          | Some path -> Printf.sprintf " (loaded from %s)" path
          | None -> ""
        in
        let msg =
          Printf.sprintf
            "keeper %s rejected: sandbox_profile is required (allowed: %s)%s. \
             Add e.g. `sandbox_profile = \"docker\"` to the keeper TOML."
            meta.name
            (String.concat ", "
               Keeper_types_profile.valid_sandbox_profile_strings)
            manifest_hint
        in
        Log.Keeper.warn "%s" msg;
        Error msg
    in
    (match target_sandbox_profile_result with
     | Error e -> Error e
     | Ok target_sandbox_profile ->
    let target_sandbox_image =
      apply_default_opt defaults.sandbox_image meta.sandbox_image in
    let target_network_mode =
      apply_default defaults.network_mode
        (Keeper_types_profile.default_network_mode_for_profile target_sandbox_profile) in
    let target_allowed_paths =
      apply_default defaults.allowed_paths [] in

    (* --- Telemetry Feedback --- *)
    let target_tf_enabled =
      apply_default_opt defaults.telemetry_feedback_enabled meta.telemetry_feedback_enabled in
    let target_tf_window =
      apply_default_opt defaults.telemetry_feedback_window_hours meta.telemetry_feedback_window_hours in

    (* --- Always Approve --- *)
    let target_always_approve =
      apply_default_opt defaults.always_approve meta.always_approve
    in
    (* --- OAS Env --- *)
    let target_oas_env =
      match defaults.oas_env with
      | [] -> meta.oas_env
      | env -> env
    in
    let overlayed =
      { meta with
        proactive = {
          enabled = target_proactive;
          idle_sec = target_idle_sec;
          cooldown_sec = target_cooldown_sec;
        };
        tool_denylist = target_denylist;
        social_model = target_social_model;
        goal = target_goal;
        short_goal = target_short_goal;
        mid_goal = target_mid_goal;
        long_goal = target_long_goal;
        will = target_will;
        needs = target_needs;
        desires = target_desires;
        instructions = target_instructions;
        autoboot_enabled = target_autoboot_enabled;
        mention_targets = target_mention_targets;
        active_goal_ids = target_active_goal_ids;
        tool_access = target_tool_access;
        sandbox_profile = target_sandbox_profile;
        sandbox_image = target_sandbox_image;
        network_mode = target_network_mode;
        allowed_paths = target_allowed_paths;
        telemetry_feedback_enabled = target_tf_enabled;
        telemetry_feedback_window_hours = target_tf_window;
        always_approve = target_always_approve;
        oas_env = target_oas_env;
      }
    in
    (* Runtime JSON intentionally omits TOML-owned config/personality
       fields.  They must be overlaid into the returned meta for the
       live registry, but comparing those omitted fields against TOML
       would classify every reconcile tick as a write-worthy drift.
       [active_goal_ids] can also be runtime-owned when set explicitly via
       keeper_up, but when supplied by TOML it remains an overlay-only
       declarative scope rather than being copied into runtime JSON. *)
    let oas_env_changed = meta.oas_env <> target_oas_env in
    let persistent_changed = oas_env_changed in
    let overlay_without_persistent_changes =
      { overlayed with
        oas_env = meta.oas_env;
      }
    in

    if persistent_changed then begin
      let cats = List.filter_map Fun.id [
        (if oas_env_changed then Some "oas_env" else None);
      ] in
      Log.Keeper.info
        "ensure_keeper_meta: re-syncing [%s] for %s"
        (String.concat "," cats)
        meta.name;
      let updated = { overlayed with updated_at = now_iso () } in
      match write_meta config updated with
      | Ok () -> Ok { updated with meta_version = updated.meta_version + 1 }
      | Error e ->
        Otel_metric_store.inc_counter
          Keeper_metrics.(to_string WriteMetaFailures)
          ~labels:[("keeper", updated.name); ("phase", "ensure_meta_resync")]
          ();
        Log.Keeper.warn "ensure_keeper_meta: write_meta re-sync failed: %s" e;
        Ok overlay_without_persistent_changes
    end
    else Ok overlayed))
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
          let result =
            Keeper_turn.handle_keeper_up ctx
              (`Assoc [ ("name", `String name) ])
          in
          if not (tool_result_success result) then
            Error
              (Printf.sprintf
                 "failed to materialize declarative keeper %s from %s: %s"
                 name toml_path (tool_result_body result))
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
  scanned: int;
  started: int;
  stale: int;
  recovering: int;
}

let bootstrap_existing_keepers ctx : keeper_bootstrap_stats =
  if not Env_config.KeeperBootstrap.enabled then
    { scanned = 0; started = 0; stale = 0; recovering = 0 }
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
    let (scanned, started, stale, recovering) =
      List.fold_left
        (fun (scanned_acc, started_acc, stale_acc, recovering_acc) name ->
          match load_or_materialize_boot_meta ctx name with
          | Error _ ->
              (scanned_acc + 1, started_acc, stale_acc, recovering_acc)
          | Ok { meta = m; materialized } ->
              if m.paused then
                (scanned_acc + 1, started_acc, stale_acc, recovering_acc)
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
              ( scanned_acc + 1,
                started_acc + (if started_here then 1 else 0),
                stale_acc + (if stale_now then 1 else 0),
                recovering_acc + (if stale_now && started_here then 1 else 0) ))
        (0, 0, 0, 0)
        entries
    in
    { scanned; started; stale; recovering }

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
             Otel_metric_store.inc_counter
               Keeper_metrics.(to_string SupervisorSweepFailures)
               ~labels:[("origin", "keeper_runtime")]
               ();
             Log.Keeper.error "supervisor sweep failed: %s"
               (Printexc.to_string exn));
          (* TOML hot-reload: re-sync declarative fields for running keepers.
             Runs after sweep_and_recover so TOML edits take effect within
             one sweep cycle (~30s) without server restart. *)
          (try
            Keeper_registry.all ~base_path ()
            |> List.iter (fun (entry : Keeper_registry.registry_entry) ->
              (* Enumerate every phase so the compiler flags any new
                 variant added to [Keeper_state_machine.phase]. TOML
                 hot-reload only reconciles Running keepers; the other
                 12 phases must skip (a Stopped/Crashed/Dead/Zombie
                 keeper has no in-memory meta to update; a Compacting
                 or HandingOff keeper is mid-transition and reconcile
                 would race; Offline / Paused / Failing / Overflowed /
                 Draining / Restarting are all transient or paused
                 states). A future phase (e.g. Migrating, Healing)
                 would silently skip reconcile under [_ -> ()] without
                 a review point. Same FSM Sparse Match anti-pattern as
                 PR #14857. *)
              match entry.phase with
              | Keeper_state_machine.Running ->
                  (* TOML mtime probe — best effort. Used by
                     [Keeper_reconcile_state] to (a) clear a parked
                     keeper when the user edits the TOML, and (b)
                     record the mtime at failure time so a later edit
                     re-arms the reconciler. If the path cannot be
                     resolved or stat fails, we still attempt one
                     reconcile and let any [Error] flow through the
                     standard back-off. *)
                  let toml_mtime =
                    match Config_dir_resolver.keeper_toml_path_opt entry.name with
                    | None -> 0.0
                    | Some path ->
                        (try (Unix.stat path).Unix.st_mtime
                         with Unix.Unix_error _ -> 0.0)
                  in
                  let _reset_happened : bool =
                    Keeper_reconcile_state.reset_on_mtime_change
                      ~keeper:entry.name
                      ~new_mtime:toml_mtime
                  in
                  if Keeper_reconcile_state.is_disabled ~keeper:entry.name
                  then
                    (* Parked: skip the reconcile call entirely. The
                       reconcile-disabled counter was incremented once when
                       the threshold crossed; we do not double-count per
                       sweep. *)
                    ()
                  else
                    (match ensure_keeper_meta ctx.config entry.name with
                     | Ok updated_meta ->
                         (* Propagate the updated meta back into the registry so
                            subsequent turns observe the new runtime_id (and
                            any other reconciled fields) immediately.  Without
                            this the file is updated but the in-memory
                            [registry_entry.meta] stays stale until restart. *)
                         Keeper_registry.update_meta ~base_path entry.name updated_meta;
                         Keeper_reconcile_state.record_success ~keeper:entry.name
                     | Error e ->
                         let outcome =
                           Keeper_reconcile_state.record_failure
                             ~keeper:entry.name
                             ~error:e
                             ~toml_mtime
                         in
                         (* Three-way branch is exhaustive over
                            [Keeper_reconcile_state.record_outcome] so
                            the compiler flags any new variant. *)
                         (match outcome with
                          | `First ->
                              Log.Keeper.warn "TOML reconcile failed for %s: %s"
                                entry.name e
                          | `Repeated ->
                              (* WORKAROUND-CARRYOVER §Symptom-억제: demote
                                 repeats to DEBUG so the system_log isn't
                                 flooded by invalid TOML drift. Root fix is
                                 keeper TOML correction + runtime.toml
                                 [keeper_assignable] policy (separate RFC). *)
                              Otel_metric_store.inc_counter
                                Keeper_metrics.(to_string TomlReconcileDedup)
                                ~labels:
                                  [ "keeper", entry.name
                                  ; "outcome", "repeated"
                                  ]
                                ();
                              Log.Keeper.debug
                                "TOML reconcile still failing for %s (dedup): %s"
                                entry.name e
                          | `Threshold_disable ->
                              (* One explicit escalation at the moment
                                 the reconciler parks this keeper. *)
                              Otel_metric_store.inc_counter
                                Keeper_metrics.(to_string TomlReconcileDedup)
                                ~labels:
                                  [ "keeper", entry.name
                                  ; "outcome", "threshold_disable"
                                  ]
                                ();
                              Otel_metric_store.inc_counter
                                Keeper_metrics.(to_string ReconcileDisabled)
                                ~labels:[ "keeper", entry.name ]
                                ();
                              Log.Keeper.error
                                "TOML reconcile disabled for %s after %d \
                                 consecutive failures (resumes on TOML edit): %s"
                                entry.name
                                Keeper_reconcile_state.default_disable_threshold
                                e))
              | Keeper_state_machine.Offline
              | Keeper_state_machine.Failing
              | Keeper_state_machine.Overflowed
              | Keeper_state_machine.Compacting
              | Keeper_state_machine.HandingOff
              | Keeper_state_machine.Draining
              | Keeper_state_machine.Paused
              | Keeper_state_machine.Stopped
              | Keeper_state_machine.Crashed
              | Keeper_state_machine.Restarting
              | Keeper_state_machine.Dead
              | Keeper_state_machine.Zombie -> ())
           with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
             Otel_metric_store.inc_counter
               Keeper_metrics.(to_string TomlReconcileSweepFailures)
               ~labels:[("origin", "keeper_runtime")]
               ();
             Log.Keeper.error "TOML reconcile sweep failed: %s"
               (Printexc.to_string exn));
          (* #10125: advance the supervisor liveness gauge after a
             completed beat.  Stale gauge (now - last > 2 × interval)
             tells operators the sweep stopped. *)
          Otel_metric_store.set_gauge
            Keeper_metrics.(to_string SupervisorLastSweepUnixtime)
            ~labels:[ ("base_path", base_path) ]
            (Unix.gettimeofday ());
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
    let sw = Option.value (Keeper_supervisor.get_global_switch ()) ~default:ctx.sw in
    Pulse.run ~sw p;
    (* #10125: counter increments once per actual Pulse start.
       After a server restart, if this stays at 0 the supervisor
       never came up — operators alert on absence of advancement. *)
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string SupervisorSweepStarts)
      ~labels:[ ("base_path", base_path) ]
      ();
    (* Initialize the liveness gauge to "now" so dashboards do not
       start at unixtime=0 (which would look infinitely stale).  The
       on_beat will overwrite this on every subsequent sweep. *)
    Otel_metric_store.set_gauge
      Keeper_metrics.(to_string SupervisorLastSweepUnixtime)
      ~labels:[ ("base_path", base_path) ]
      (Unix.gettimeofday ());
    Log.Keeper.info "keeper supervisor sweep started (interval %.0fs)" sweep_sec
  end

(** #10125: supervisor sweep age helper.  Returns the wall-clock
    seconds since the last successful sweep beat, or [None] if the
    gauge was never set (i.e., the sweep never started in this
    process).  Dashboards use this to render a [stale] badge when
    the sweep stalls; tests use it to verify the gauge advances. *)
let supervisor_sweep_age_seconds ~(base_path : string) : float option =
  match
    Otel_metric_store.get_metric_value
      Keeper_metrics.(to_string SupervisorLastSweepUnixtime)
      ~labels:[ ("base_path", base_path) ]
      ()
  with
  | None -> None
  | Some last ->
    let now = Unix.gettimeofday () in
    Some (now -. last)

let existing_keepalive_bootstrap_done : (string, unit) Hashtbl.t =
  Hashtbl.create 4

let has_boot_entries config =
  bootable_keeper_names config <> []
  || auto_recoverable_paused_keeper_names config <> []

(* #10125: extracted predicate so it can be unit-tested without
   spinning up an Eio + Pulse runtime.  See [maybe_start_supervisor_sweep]
   for the WHY. *)
let should_start_supervisor_sweep
    ~(config : Workspace.config)
    ~(stats : keeper_bootstrap_stats) : bool =
  stats.started > 0
  || Keeper_registry.count_running ~base_path:config.base_path () > 0
  || has_boot_entries config

let maybe_start_supervisor_sweep ctx (stats : keeper_bootstrap_stats) =
  (* #10125: supervisor startup is decoupled from bootstrap success.
     If there are bootable keepers on disk OR any are already running
     OR any started this boot, run the sweep.  The supervisor can
     recover keepers that bootstrap failed to load — exactly what
     the sweep is for — so a transient bootstrap failure must not
     silently disable auto-recovery for the rest of the server
     lifetime (2026-04-24 incident: 14 keeper meta files on disk,
     every bootstrap entry hit a transient
     [load_or_materialize_boot_meta] error, fleet stayed dead 4h+). *)
  if should_start_supervisor_sweep ~config:ctx.config ~stats
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
        Log.Keeper.debug "bootstrap_existing_keepers scanned=%d started=%d stale=%d recovering=%d"
          stats.scanned stats.started stats.stale
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
