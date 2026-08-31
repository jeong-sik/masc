(** Keeper_runtime — keeper reconciliation and keepalive bootstrap.
    Runtime-only mutable state stays behind keeper runtime/execution modules. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_meta_store
open Keeper_types_profile

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
  | Shutdown_admission_fence

let autoboot_exclusion_reason_to_string = function
  | Paused -> "paused"
  | Declarative_autoboot_disabled -> "declarative_autoboot_disabled"
  | Autoboot_disabled -> "autoboot_disabled"
  | Shutdown_admission_fence -> "shutdown_admission_fence"

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
  match
    read_meta_file_path
      ~ownership_root:config.Workspace.base_path
      (keeper_meta_path config name)
  with
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
  (* The keeper's runtime is assigned in runtime.toml,
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
      drift_if "instructions"
        (not
           (Keeper_runtime_instructions.text_equal
              current.instructions target.instructions));
      drift_if "agent_core_env" (current.agent_core_env <> target.agent_core_env);
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
       Keeper config plus explicit env overrides are the source of truth.
       Fields where TOML has [Some v] are overwritten; [None] keeps runtime value. *)
    let defaults_result =
      profile_defaults_result_for_config config meta.name
    in
    match defaults_result with
    | Error error ->
        Error (profile_defaults_boot_error ~keeper_name:meta.name error)
    | Ok defaults ->
    (* --- Proactive --- *)
    let target_proactive =
      apply_default defaults.proactive_enabled Keeper_config.default_proactive_enabled in
    (* --- Keeper instructions --- *)
    let target_instructions = apply_default defaults.instructions meta.instructions in

    (* --- Policy --- *)
    let target_autoboot_enabled =
      apply_default defaults.autoboot_enabled meta.autoboot_enabled in
    let target_mention_targets =
      match defaults.mention_targets with [] -> meta.mention_targets | xs -> xs in
    (* Defense-in-depth (#11080 sibling): keeper sandbox_profile MUST be
       declared. The behaviour before #32078 fell through to a default that
       named host execution, so an operator who forgot the key got no
       isolation and no error. There is no such default now, and no host arm
       to fall through to; this rejects at reconcile time so the keeper
       visibly fails to boot rather than booting on a profile nobody
       chose.

       Every Keeper must declare a TOML sandbox profile. The
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

    (* --- Telemetry Feedback --- *)
    let target_tf_enabled =
      apply_default_opt defaults.telemetry_feedback_enabled meta.telemetry_feedback_enabled in
    let target_tf_window =
      apply_default_opt defaults.telemetry_feedback_window_hours meta.telemetry_feedback_window_hours in

    (* --- Always Approve --- *)
    let target_always_allow =
      apply_default_opt defaults.always_allow meta.always_allow
    in
    (* --- AGENT_CORE Env --- *)
    let target_agent_core_env =
      match defaults.agent_core_env with
      | [] -> meta.agent_core_env
      | env -> env
    in
    let overlayed =
      { meta with
        proactive = {
          enabled = target_proactive;
        };
        instructions = target_instructions;
        autoboot_enabled = target_autoboot_enabled;
        mention_targets = target_mention_targets;
        sandbox_profile = target_sandbox_profile;
        sandbox_image = target_sandbox_image;
        network_mode = target_network_mode;
        telemetry_feedback_enabled = target_tf_enabled;
        telemetry_feedback_window_hours = target_tf_window;
        always_allow = target_always_allow;
        agent_core_env = target_agent_core_env;
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
    (* Keep the runtime snapshot honest as well as the live overlay. *)
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
      let persisted_updated = effective_updated in
      match
        Keeper_owner_registry.apply_meta
          ~base_path:config.base_path
          ~keeper_name:persisted_updated.name
          (Keeper_owner_reducer.Update_profile
             { instructions = persisted_updated.instructions
             ; sandbox_profile = persisted_updated.sandbox_profile
             ; sandbox_image = persisted_updated.sandbox_image
             ; network_mode = persisted_updated.network_mode
             ; mention_targets = persisted_updated.mention_targets
             ; proactive_enabled = persisted_updated.proactive.enabled
             ; max_context_override = persisted_updated.max_context_override
             ; autoboot_enabled = persisted_updated.autoboot_enabled
             ; telemetry_feedback_enabled = persisted_updated.telemetry_feedback_enabled
             ; telemetry_feedback_window_hours =
                 persisted_updated.telemetry_feedback_window_hours
             ; always_allow = persisted_updated.always_allow
             ; agent_core_env = persisted_updated.agent_core_env
             ; updated_at = persisted_updated.updated_at
             })
      with
      | Ok (Some committed) ->
        Ok committed
      | Ok None ->
        Error
          (boot_meta_error
             Meta_read_error
             (Printf.sprintf
                "ensure_keeper_meta: owner metadata disappeared for %s"
                effective_updated.name))
      | Error error ->
        let detail = Keeper_owner_registry.command_error_to_string error in
        Otel_metric_store.inc_counter
          Keeper_metrics.(to_string WriteMetaFailures)
          ~labels:[("keeper", effective_updated.name); ("phase", "ensure_meta_resync")]
          ();
        Log.Keeper.warn "ensure_keeper_meta: owner re-sync failed: %s" detail;
        Error (boot_meta_error Meta_read_error detail)
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

(* #29610 reads a meta this binary cannot decode as absent and leaves the
   file in place for the operator — but this boot path then persists a fresh
   meta over that same file, which is how the 2026-08-29 schema cut zeroed
   nine keepers' counters with no copy left. Before re-materialising, move
   the unreadable file aside; parking failure never blocks recovery. *)
let park_unreadable_meta_before_rematerialization config name =
  let path = Keeper_types_profile.keeper_meta_path config name in
  if Fs_compat.file_exists path
  then (
    let parked = Printf.sprintf "%s.rejected-%d" path (int_of_float (Unix.time ())) in
    match Sys.rename path parked with
    | () ->
      Log.Keeper.warn
        "parked unreadable keeper meta %s -> %s (counters preserved for operator recovery)"
        path
        parked
    | exception e ->
      Log.Keeper.warn
        "could not park unreadable keeper meta %s before re-materialization: %s"
        path
        (Printexc.to_string e))
;;

let load_or_materialize_boot_meta (ctx : _ context) name
    : (boot_meta_resolution, string) result =
  let result =
    match ensure_keeper_meta_with_cause ctx.config name with
    | Ok meta -> Ok { meta; materialized = false }
    | Error ({ cause = Missing_meta; _ } as original_error) -> (
        match keeper_toml_path_opt_for_config ctx.config name with
        | None -> Error original_error
        | Some toml_path -> (
            Log.Keeper.info
              "bootstrapping declarative keeper %s from %s"
              name toml_path;
            park_unreadable_meta_before_rematerialization ctx.config name;
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
    | Error original_error -> Error original_error
  in
  remember_boot_meta_result ctx name result

(** Start the supervisor sweep Pulse loop.
    Runs alongside server-owned autoboot, scanning for zombie fibers and
    restarting them with exponential backoff. *)
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
                 other phases skip (a Stopped/Crashed
                 keeper has no in-memory meta to update;
                 Offline / Paused / Failing / Draining / Restarting
                 are all transient or paused states). A future phase (e.g. Migrating, Healing)
                 would silently skip reconcile under [_ -> ()] without
                 a review point. Same FSM Sparse Match anti-pattern as
                 PR #14857. *)
              match entry.phase with
              | Keeper_state_machine.Running ->
                  (match
                     remember_boot_meta_result
                       ctx
                       entry.name
                       (ensure_keeper_meta_with_cause ctx.config entry.name)
                   with
                   | Ok _ -> ()
                   | Error e ->
                       Log.Keeper.warn
                         "TOML reconcile failed for %s: %s"
                         entry.name
                         e)
              | Keeper_state_machine.Offline
              | Keeper_state_machine.Failing
              | Keeper_state_machine.Draining
              | Keeper_state_machine.Paused
              | Keeper_state_machine.Stopped
              | Keeper_state_machine.Crashed
              | Keeper_state_machine.Restarting -> ())
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

let stop_keepalive ?base_path name =
  Keeper_keepalive.stop_keepalive ?base_path name

let reset_test_state base_path =
  stop_supervisor_sweep base_path;
  clear_boot_meta_failures_for_base_path base_path
