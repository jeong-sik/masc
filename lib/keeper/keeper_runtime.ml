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
    exceeds [Keeper_config.prompt_render_max_bytes] (e.g. a 357-byte
    [instructions]), the read path normalises to ~319 bytes, while
    [target_instructions] computed from
    [apply_default defaults.instructions meta.instructions] keeps the
    raw 357-byte value.  trim-only compare flagged that 38-byte gap as
    drift on every reconcile tick (~2880 redundant writes/day).
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

type boot_meta_failure_cause =
  | Missing_meta
  | Meta_read_error
  | Config_invalid
  | Sandbox_profile_required
  | Materialization_failed

let boot_meta_failure_cause_label = function
  | Missing_meta -> "missing_meta"
  | Meta_read_error -> "meta_read_error"
  | Config_invalid -> "config_invalid"
  | Sandbox_profile_required -> "sandbox_profile_required"
  | Materialization_failed -> "materialization_failed"

type boot_meta_error = {
  cause : boot_meta_failure_cause;
  config_error : keeper_toml_load_error option;
  message : string;
}

let boot_meta_error ?config_error cause message = { cause; config_error; message }

type boot_meta_failure = {
  keeper_name : string;
  base_path : string;
  cause : boot_meta_failure_cause;
  config_error : keeper_toml_load_error option;
  error : string;
  recorded_at : string;
  recorded_at_unix : float;
}

let boot_meta_failures : (string, boot_meta_failure) Hashtbl.t =
  Hashtbl.create 32
let boot_meta_failures_mu = Stdlib.Mutex.create ()

let boot_meta_failure_key ~base_path ~name = base_path ^ "\000" ^ name

let with_boot_meta_failures_lock f =
  Stdlib.Mutex.lock boot_meta_failures_mu;
  Fun.protect ~finally:(fun () -> Stdlib.Mutex.unlock boot_meta_failures_mu) f

let record_boot_meta_failure ~base_path ~name ~cause ~config_error ~error =
  let failure =
    {
      keeper_name = name;
      base_path;
      cause;
      config_error;
      error;
      recorded_at = now_iso ();
      recorded_at_unix = Time_compat.now ();
    }
  in
  with_boot_meta_failures_lock (fun () ->
      Hashtbl.replace boot_meta_failures
        (boot_meta_failure_key ~base_path ~name)
        failure)

let clear_boot_meta_failure ~base_path ~name =
  with_boot_meta_failures_lock (fun () ->
      Hashtbl.remove boot_meta_failures
        (boot_meta_failure_key ~base_path ~name))

let clear_boot_meta_failures_for_base_path base_path =
  with_boot_meta_failures_lock (fun () ->
      let keys =
        Hashtbl.fold
          (fun key (failure : boot_meta_failure) acc ->
            if String.equal failure.base_path base_path then key :: acc else acc)
          boot_meta_failures
          []
      in
      List.iter (Hashtbl.remove boot_meta_failures) keys)

let boot_meta_failure_for ~base_path ~name =
  with_boot_meta_failures_lock (fun () ->
      Hashtbl.find_opt boot_meta_failures
        (boot_meta_failure_key ~base_path ~name))

let profile_defaults_result_for_config config name =
  load_keeper_profile_defaults_result_for_base_path
    ~base_path:config.Workspace.base_path
    name

let keeper_toml_path_opt_for_config config name =
  keeper_toml_path_opt_for_base_path
    ~base_path:config.Workspace.base_path
    name

let remember_boot_meta_result ctx name result =
  let base_path = ctx.config.base_path in
  match result with
  | Ok value ->
      clear_boot_meta_failure ~base_path ~name;
      Ok value
  | Error { cause; config_error; message } ->
      record_boot_meta_failure ~base_path ~name ~cause ~config_error ~error:message;
      Error message

type autoboot_exclusion_reason =
  | Paused
  | Declarative_autoboot_disabled
  | Autoboot_disabled

let autoboot_exclusion_reason_to_string = function
  | Paused -> "paused"
  | Declarative_autoboot_disabled -> "declarative_autoboot_disabled"
  | Autoboot_disabled -> "autoboot_disabled"

let autoboot_exclusion_reason_to_yojson reason =
  `String (autoboot_exclusion_reason_to_string reason)

let autoboot_exclusion_reason_opt_to_yojson = function
  | Some reason -> autoboot_exclusion_reason_to_yojson reason
  | None -> `Null

type autoboot_exclusion = {
  keeper_name : string;
  reason : autoboot_exclusion_reason;
}

let autoboot_exclusion_reason config name =
  match read_meta_file_path (keeper_meta_path config name) with
  | Ok (Some meta) ->
    if meta.paused then Some Paused
    else
      (match profile_defaults_result_for_config config name with
       | Error _ -> None
       | Ok defaults ->
         (match defaults.autoboot_enabled with
          | Some true -> None
          | Some false -> Some Declarative_autoboot_disabled
          | None ->
            if meta.autoboot_enabled then None else Some Autoboot_disabled))
  | Ok None ->
    (match profile_defaults_result_for_config config name with
     | Error _ -> None
     | Ok defaults ->
       (match defaults.autoboot_enabled with
        | Some false -> Some Declarative_autoboot_disabled
        | Some true | None -> None))
  | Error _ ->
    (* Preserve existing behavior: corrupt/unreadable meta still enters the
       boot path so load_or_materialize_boot_meta can emit the precise error. *)
    None

let bootstrap_candidate_keeper_names config =
  configured_keeper_names config
  |> List.filter (fun name -> Option.is_none (autoboot_exclusion_reason config name))

let bootable_keeper_names config =
  bootstrap_candidate_keeper_names config
  |> List.filter (fun name ->
       Result.is_ok (profile_defaults_result_for_config config name))

let autoboot_excluded_keeper_reasons config =
  configured_keeper_names config
  |> List.filter_map (fun name ->
       match autoboot_exclusion_reason config name with
       | Some reason -> Some { keeper_name = name; reason }
       | None -> None)

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

let profile_defaults_boot_error ~keeper_name error =
  boot_meta_error ~config_error:error Config_invalid
    (Printf.sprintf
       "invalid keeper profile for keeper %s: %s"
       keeper_name
       (keeper_toml_load_error_to_string error))

let sandbox_profile_required_boot_error ~keeper_name ~manifest_path =
  let manifest_hint =
    match manifest_path with
    | Some path -> Printf.sprintf " (loaded from %s)" path
    | None -> ""
  in
  let msg =
    Printf.sprintf
      "keeper %s rejected: sandbox_profile is required (allowed: %s)%s. \
       Add e.g. `sandbox_profile = \"docker\"` to the keeper TOML."
      keeper_name
      (String.concat ", " Keeper_types_profile.valid_sandbox_profile_strings)
      manifest_hint
  in
  Log.Keeper.warn "%s" msg;
  boot_meta_error Sandbox_profile_required msg

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

let drift_if label changed =
  if changed then Some label else None

let keeper_meta_persistent_drift_categories
    ~(defaults : Keeper_types_profile.keeper_profile_defaults)
    ~(current : keeper_meta)
    ~(target : keeper_meta) =
  List.filter_map Fun.id
    [
      drift_if "persona" (current.persona <> target.persona);
      drift_if "instructions"
        (not (personality_text_equal current.instructions target.instructions));
      drift_if "oas_env" (current.oas_env <> target.oas_env);
    ]

let keeper_meta_overlay_drift_categories
    ~(defaults : Keeper_types_profile.keeper_profile_defaults)
    ~(current : keeper_meta)
    ~(target : keeper_meta) =
  List.filter_map Fun.id
    [
      drift_if "proactive" (current.proactive <> target.proactive);
      drift_if "autoboot_enabled"
        (current.autoboot_enabled <> target.autoboot_enabled);
      drift_if "mention_targets"
        (current.mention_targets <> target.mention_targets);
      drift_if "sandbox_profile"
        (current.sandbox_profile <> target.sandbox_profile);
      drift_if "sandbox_image" (current.sandbox_image <> target.sandbox_image);
      drift_if "network_mode" (current.network_mode <> target.network_mode);
      drift_if "allowed_paths"
        (Option.is_some defaults.allowed_paths
         && current.allowed_paths <> target.allowed_paths);
      drift_if "telemetry_feedback_enabled"
        (current.telemetry_feedback_enabled <> target.telemetry_feedback_enabled);
      drift_if "telemetry_feedback_window_hours"
        (current.telemetry_feedback_window_hours
         <> target.telemetry_feedback_window_hours);
      drift_if "always_allow"
        (current.always_allow <> target.always_allow);
    ]

let emit_keeper_meta_overlay_drift ~keeper_name categories =
  match categories with
  | [] -> ()
  | cats ->
    Log.Keeper.debug
      "ensure_keeper_meta: overlaying TOML-only [%s] for %s without writing \
       runtime meta JSON"
      (String.concat "," cats)
      keeper_name;
    List.iter
      (fun field ->
         Otel_metric_store.inc_counter
           Keeper_metrics.(to_string KeeperMetaOverlayDrift)
           ~labels:[("keeper", keeper_name); ("field", field)]
           ())
      cats

let ensure_keeper_meta_with_cause config name =
  match read_meta config name with
  | Ok (Some meta) ->
    (
    (* Re-sync ALL declarative keeper fields from profile/env defaults on bootstrap.
       Persisted meta may have stale values from a previous session;
       persona config (TOML) plus explicit env overrides are the source of truth.
       Fields where TOML has [Some v] are overwritten; [None] keeps runtime value. *)
    let defaults_result =
      profile_defaults_result_for_config config meta.name
    in
    match defaults_result with
    | Error error ->
        Error (profile_defaults_boot_error ~keeper_name:meta.name error)
    | Ok defaults ->
    let target_persona = apply_default_opt defaults.persona_name meta.persona in

    (* --- Proactive --- *)
    let target_proactive =
      apply_default defaults.proactive_enabled Keeper_config.default_proactive_enabled in
    (* --- Personality --- *)
    let target_instructions = apply_default defaults.instructions meta.instructions in

    (* --- Policy --- *)
    let target_autoboot_enabled =
      apply_default defaults.autoboot_enabled meta.autoboot_enabled in
    let target_mention_targets =
      match defaults.mention_targets with [] -> meta.mention_targets | xs -> xs in
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
        Error
          (sandbox_profile_required_boot_error
             ~keeper_name:meta.name
             ~manifest_path:defaults.manifest_path)
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
    let target_always_allow =
      apply_default_opt defaults.always_allow meta.always_allow
    in
    (* --- OAS Env --- *)
    let target_oas_env =
      match defaults.oas_env with
      | [] -> meta.oas_env
      | env -> env
    in
    let overlayed =
      { meta with
        persona = target_persona;
        proactive = {
          enabled = target_proactive;
        };
        instructions = target_instructions;
        autoboot_enabled = target_autoboot_enabled;
        mention_targets = target_mention_targets;
        sandbox_profile = target_sandbox_profile;
        sandbox_image = target_sandbox_image;
        network_mode = target_network_mode;
        allowed_paths = target_allowed_paths;
        telemetry_feedback_enabled = target_tf_enabled;
        telemetry_feedback_window_hours = target_tf_window;
        always_allow = target_always_allow;
        oas_env = target_oas_env;
      }
    in
    (* Keep the runtime snapshot honest as well as the live overlay for fields
       that are actually emitted by [meta_to_json].  TOML-only config fields
       (sandbox policy, cadence, etc.) remain overlay-only; if
       they triggered writes here, [meta_to_json]/scrub would drop them from disk
       and the next reconcile tick would see the same drift again. *)
    let overlay_cats =
      keeper_meta_overlay_drift_categories
        ~defaults
        ~current:meta
        ~target:overlayed
    in
    emit_keeper_meta_overlay_drift ~keeper_name:meta.name overlay_cats;
    (* Keep the runtime snapshot honest as well as the live overlay.  The
       previous overlay-only path made operators see stale JSON forever
       (for example persona=analyst while TOML declared masc-improver),
       which hid prompt/tool/autonomy drift from health and bootstrap
       checks. *)
    let cats =
      keeper_meta_persistent_drift_categories
        ~defaults
        ~current:meta
        ~target:overlayed
    in
    if cats <> [] then begin
      Log.Keeper.info
        "ensure_keeper_meta: re-syncing [%s] for %s"
        (String.concat "," cats)
        meta.name;
      let updated_at = now_iso () in
      let effective_updated = { overlayed with updated_at } in
      match write_meta config effective_updated with
      | Ok () -> Ok { effective_updated with meta_version = effective_updated.meta_version + 1 }
      | Error e ->
        Otel_metric_store.inc_counter
          Keeper_metrics.(to_string WriteMetaFailures)
          ~labels:[("keeper", effective_updated.name); ("phase", "ensure_meta_resync")]
          ();
        Log.Keeper.warn "ensure_keeper_meta: write_meta re-sync failed: %s" e;
        Ok overlayed
    end
    else Ok overlayed))
  | Ok None ->
    Log.Keeper.warn
      "ensure_keeper_meta: no persistent meta for %s — run keeper_up to initialize" name;
    Error
      (boot_meta_error Missing_meta
         (Printf.sprintf
            "no persistent meta for %s — run keeper_up to initialize"
            name))
  | Error msg -> Error (boot_meta_error Meta_read_error msg)

let ensure_keeper_meta config name =
  match ensure_keeper_meta_with_cause config name with
  | Ok meta -> Ok meta
  | Error err -> Error err.message

let declarative_materialization_args name _defaults =
  `Assoc [ "name", `String name ]

let declarative_materialization_defaults config name =
  match profile_defaults_result_for_config config name with
  | Error error -> Error (profile_defaults_boot_error ~keeper_name:name error)
  | Ok defaults -> (
      match defaults.sandbox_profile with
      | Some _ -> Ok defaults
      | None ->
          Error
            (sandbox_profile_required_boot_error
               ~keeper_name:name
               ~manifest_path:defaults.manifest_path))

let materialization_failed_boot_error ~name ~toml_path ~body =
  boot_meta_error Materialization_failed
    (Printf.sprintf
       "failed to materialize declarative keeper %s from %s: %s"
       name toml_path body)

let materialized_reload_boot_error ~name ~toml_path (err : boot_meta_error) =
  boot_meta_error ?config_error:err.config_error err.cause
    (Printf.sprintf
       "materialized declarative keeper %s from %s but failed to reload meta: %s"
       name toml_path err.message)

let load_or_materialize_boot_meta (ctx : _ context) name
    : (boot_meta_resolution, string) result =
  let result =
    match ensure_keeper_meta_with_cause ctx.config name with
    | Ok meta -> Ok { meta; materialized = false }
    | Error original_error -> (
        match keeper_toml_path_opt_for_config ctx.config name with
        | None -> Error original_error
        | Some toml_path -> (
            Log.Keeper.info
              "bootstrapping declarative keeper %s from %s"
              name toml_path;
            match declarative_materialization_defaults ctx.config name with
            | Error err -> Error err
            | Ok defaults ->
            let result =
              Keeper_turn.handle_keeper_up ctx
                (declarative_materialization_args name defaults)
            in
            if not (tool_result_success result) then
              Error
                (materialization_failed_boot_error
                   ~name
                   ~toml_path
                   ~body:(tool_result_body result))
            else
              match read_meta ctx.config name with
              | Ok None ->
                  Error
                    (boot_meta_error Missing_meta
                       (Printf.sprintf
                          "materialized declarative keeper %s from %s but no meta was written"
                          name toml_path))
              | Error msg ->
                  Error
                    (boot_meta_error Meta_read_error
                       (Printf.sprintf
                          "materialized declarative keeper %s from %s but failed to reload meta: %s"
                          name toml_path msg))
              | Ok (Some _) -> (
                  match ensure_keeper_meta_with_cause ctx.config name with
                  | Ok meta -> Ok { meta; materialized = true }
                  | Error msg ->
                      Error (materialized_reload_boot_error ~name ~toml_path msg))))
  in
  remember_boot_meta_result ctx name result

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
    let entries = bootstrap_candidate_keeper_names ctx.config |> take max_scan in
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
                  Keeper_registry.is_running
                    ~base_path:ctx.config.base_path m.name
                else if already_running then false
                else (
                  Keeper_supervisor.supervise_keepalive
                    ~proactive_warmup_sec ctx m;
                  Keeper_registry.is_running
                    ~base_path:ctx.config.base_path m.name
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
    let load_or_materialize_keeper_meta ctx name =
      match load_or_materialize_boot_meta ctx name with
      | Ok { meta; _ } -> Ok (Some meta)
      | Error err -> Error err
    in
    let consumer : (module Pulse.Consumer) =
      (module struct
        let name = "keeper-supervisor-sweep"
        let should_act _beat = true
        let on_beat _beat =
          (try
             Keeper_supervisor.sweep_and_recover
               ~load_or_materialize_keeper_meta
               ctx
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
                 other phases skip (a Stopped/Crashed/Dead
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
                    match keeper_toml_path_opt_for_config ctx.config entry.name with
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
                              Otel_metric_store.inc_counter
                                Keeper_metrics.(to_string TomlReconcileDedup)
                                ~labels:
                                  [ "keeper", entry.name
                                  ; "outcome", "repeated"
                                  ]
                                ();
                              Log.Keeper.warn
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
              | Keeper_state_machine.Dead -> ())
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
    let sweep_sec = Runtime_params.get Runtime_settings.keeper_supervisor_sweep_sec in
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
    (* The sweep is owned by the context that constructed it. Detached
       lifecycle workers use [Keeper_process_switch]; this context-bound
       producer must not silently substitute one switch authority for the
       other. *)
    Pulse.run ~sw:ctx.sw p;
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
  bootstrap_candidate_keeper_names config <> []

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
  clear_boot_meta_failures_for_base_path base_path;
  Hashtbl.remove existing_keepalive_bootstrap_done base_path
