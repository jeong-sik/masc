(** Keeper_turn_up_create -- create a new keeper from parsed arguments.

    Extracted from keeper_turn_up.ml (Ok None branch).
    Handles initial keeper meta construction, checkpoint creation,
    keepalive start, and response JSON generation. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_meta_store
open Keeper_types_profile
open Keeper_keepalive
open Keeper_execution
open Keeper_turn_up_args


(* #9749: bootstrap can race a heartbeat/supervisor meta write after
   crash recovery. Retry on CAS conflict while keeping heartbeat-owned
   cursors from disk. *)
let write_initial_meta config meta =
  write_meta_with_merge
    ~merge:Keeper_meta_merge.heartbeat_fields_from_disk
    config meta

(* Single derivation of the create-time keeper fields from [parsed_args]
   (operator args > profile defaults > env/runtime-param defaults). The boot
   create path and the configured-only (no_boot) create path must resolve
   these identically — one function is what keeps the two paths from
   drifting. Deterministic given [p] and the config/env snapshot: no clock,
   no id generation, no filesystem writes. Validation (empty goal, unknown
   active_goal_ids, sandbox settings) stays with the callers because the
   error surfaces differ per path. *)
type derived_create_inputs = {
  goal : string;
  autoboot_enabled : bool;
  allowed_paths : string list;
  active_goal_ids : string list;
  sandbox_profile : Keeper_types_profile.sandbox_profile;
  network_mode : Keeper_types_profile.network_mode;
  multimodal_policy : Keeper_types_profile.multimodal_policy;
  mention_targets : string list;
  proactive_enabled : bool;
  auto_handoff : bool;
  handoff_threshold : float;
  handoff_cooldown_sec : int;
  instructions : string;
  compaction_profile : string;
  compaction_ratio_gate : float;
  compaction_message_gate : int;
  compaction_token_gate : int;
  compaction_cooldown_sec : int;
  primary_max_context : int;
}

let derive_create_inputs (p : parsed_args) : derived_create_inputs =
  let goal =
    match p.goal_opt with
    | Some goal -> normalize_goal_text goal
    | None ->
        p.profile_defaults.goal |> Option.value ~default:""
        |> normalize_goal_text
  in
  let autoboot_enabled =
    Dashboard_utils.first_some p.autoboot_enabled_opt p.profile_defaults.autoboot_enabled
    |> Option.value ~default:true
  in
  let allowed_paths =
    match p.allowed_paths_opt with
    | Some paths -> paths
    | None -> Option.value ~default:[] p.profile_defaults.allowed_paths
  in
  let active_goal_ids =
    match p.active_goal_ids_opt with
    | Some ids -> ids
    | None -> Option.value ~default:[] p.profile_defaults.active_goal_ids
  in
  let sandbox_profile =
    resolve_sandbox_profile ~fallback:p.profile_defaults.sandbox_profile
  in
  let network_mode =
    resolve_network_mode
      ~sandbox_profile
      ~fallback:p.profile_defaults.network_mode
  in
  (* RFC vision-delegation §2.4: take the profile's policy if set, else the
     safe default (Inherit). *)
  let multimodal_policy =
    match p.profile_defaults.multimodal_policy with
    | Some policy -> policy
    | None -> Keeper_types_profile.default_multimodal_policy
  in
  let mention_targets =
    resolve_mention_targets
      ~mention_targets_opt:p.mention_targets_opt
      ~fallback_targets:p.profile_defaults.mention_targets
      ~name:p.name
  in
  let proactive_enabled =
    Option.value
      ~default:
        (Option.value ~default:default_proactive_enabled
           p.profile_defaults.proactive_enabled)
      p.proactive_enabled_opt
  in
  let auto_handoff = Option.value ~default:true p.auto_handoff_opt in
  let handoff_threshold =
    match p.handoff_threshold_opt with
    | Some threshold -> threshold
    | None ->
        Runtime_params.get Runtime_settings.keeper_handoff_threshold
  in
  let handoff_cooldown_sec =
    match p.handoff_cooldown_sec_opt with
    | Some cooldown_sec -> cooldown_sec
    | None ->
        Runtime_params.get Runtime_settings.keeper_handoff_cooldown_sec
  in
  let instructions = Option.value ~default:"" p.instructions_opt in
  let (env_ratio_gate, env_message_gate, env_token_gate) =
    keeper_compaction_policy_from_env ()
  in
  let compaction_cooldown_sec =
    Option.value
      ~default:(keeper_compaction_cooldown_sec ())
      p.compaction_cooldown_sec_opt
    |> normalize_compaction_cooldown_sec
  in
  let
    ( compaction_profile,
      compaction_ratio_gate,
      compaction_message_gate,
      compaction_token_gate )
    =
    resolve_compaction_policy
      ~profile_opt:p.compaction_profile_opt
      ~ratio_opt:p.compaction_ratio_gate_opt
      ~message_opt:p.compaction_message_gate_opt
      ~token_opt:p.compaction_token_gate_opt
      ~fallback_profile:default_compaction_profile
      ~fallback_ratio:env_ratio_gate
      ~fallback_message:env_message_gate
      ~fallback_token:env_token_gate
  in
  let primary_max_context =
    match p.max_context_override_opt with
    | Some v -> v
    (* Boundary: Keeper consumes an opaque context budget, not a
       provider/model identity. *)
    | None -> Runtime.default_max_context ()
  in
  {
    goal;
    autoboot_enabled;
    allowed_paths;
    active_goal_ids;
    sandbox_profile;
    network_mode;
    multimodal_policy;
    mention_targets;
    proactive_enabled;
    auto_handoff;
    handoff_threshold;
    handoff_cooldown_sec;
    instructions;
    compaction_profile;
    compaction_ratio_gate;
    compaction_message_gate;
    compaction_token_gate;
    compaction_cooldown_sec;
    primary_max_context;
  }

(* Unknown [active_goal_ids] check — only explicit operator input is
   validated; profile-default ids were validated when the profile was
   written. Reads Goal_store, so it lives outside [derive_create_inputs]. *)
let unknown_active_goal_ids_error (config : Workspace.config) (p : parsed_args)
    ~(active_goal_ids : string list) : string option =
  match p.active_goal_ids_opt with
  | None -> None
  | Some _ ->
      let missing =
        List.filter
          (fun goal_id -> Option.is_none (Goal_store.get_goal config ~goal_id))
          active_goal_ids
      in
      if missing = [] then None
      else
        Some
          (Printf.sprintf "unknown active_goal_ids: %s"
             (String.concat ", " missing))

(* Configured-only create (create-without-boot): the caller has already
   written the durable TOML; this materializes the list-visible meta with
   NO boot side effect — no session, no checkpoint, no registry/keepalive,
   no runtime assignment. [autoboot_enabled] is pinned false so reconcile
   classifies the keeper [Declarative_autoboot_disabled]
   (Keeper_runtime.autoboot_exclusion_reason) until an operator boots it
   explicitly via masc_keeper_up. Gates mirror [create_keeper] with the
   same error strings so both paths speak one vocabulary. *)
let create_keeper_configured_only (config : Workspace.config)
    (p : parsed_args) : (keeper_meta, string) result =
  let d = derive_create_inputs p in
  if d.goal = "" then Error "goal is required when creating a keeper"
  else
    match
      unknown_active_goal_ids_error config p
        ~active_goal_ids:d.active_goal_ids
    with
    | Some msg -> Error msg
    | None -> (
        match validate_sandbox_settings ~allowed_paths:d.allowed_paths with
        | Error err -> Error err
        | Ok () -> (
            let now_ts = Time_compat.now () in
            let trace_id = generate_trace_id () in
            match Keeper_id.Trace_id.of_string trace_id with
            | Error err ->
                Error
                  (Printf.sprintf
                     "internal keeper trace_id generation failed: %s" err)
            | Ok trace_id_t ->
                let persona_extended =
                  Keeper_types_profile.resolved_persona_name
                    ~keeper_name:p.name p.profile_defaults
                  |> Keeper_types_profile.load_persona_extended
                  |> Option.value ~default:""
                in
                (* No [next_generation] reservation: a configured-only
                   keeper owns no episode stream yet, and the counter
                   lives under the process-global keepers dir — reserving
                   here would write a runtime artifact outside
                   [config.base_path] for a keeper that never booted.
                   0 is exactly what a fresh reservation yields; the boot
                   path reserves for real on its own create/turn cycle. *)
                let generation = 0 in
                let meta =
                  Keeper_meta_build.initial_meta ~name:p.name
                    ~agent_name:(Keeper_identity.keeper_agent_name p.name)
                    ~persona_extended ~goal:d.goal
                    ~instructions:d.instructions
                    ~sandbox_profile:d.sandbox_profile
                    ~network_mode:d.network_mode
                    ~multimodal_policy:d.multimodal_policy
                    ~allowed_paths:d.allowed_paths
                    ~mention_targets:d.mention_targets
                    ~proactive_enabled:d.proactive_enabled
                    ~compaction_profile:d.compaction_profile
                    ~compaction_mode:
                      (Keeper_config.keeper_compaction_mode_default ())
                    ~compaction_ratio_gate:d.compaction_ratio_gate
                    ~compaction_message_gate:d.compaction_message_gate
                    ~compaction_token_gate:d.compaction_token_gate
                    ~compaction_cooldown_sec:d.compaction_cooldown_sec
                    ~auto_handoff:d.auto_handoff
                    ~handoff_threshold:d.handoff_threshold
                    ~handoff_cooldown_sec:d.handoff_cooldown_sec
                    ~created_at:(now_iso ())
                    ~max_context_override:p.max_context_override_opt
                    ~active_goal_ids:d.active_goal_ids
                    ~autoboot_enabled:false
                    ~telemetry_feedback_enabled:
                      p.profile_defaults.telemetry_feedback_enabled
                    ~telemetry_feedback_window_hours:
                      p.profile_defaults.telemetry_feedback_window_hours
                    ~always_allow:p.profile_defaults.always_allow ~now_ts
                    ~generation ~trace_id:trace_id_t
                    ~keeper_uid:(Keeper_id.Uid.generate ())
                    ~oas_env:p.profile_defaults.oas_env ()
                in
                (match write_initial_meta config meta with
                 | Error e -> Error e
                 | Ok () -> Ok meta)))

let create_keeper (ctx : _ context) (p : parsed_args) : tool_result =
  Log.Keeper.info "create_keeper: starting for name=%s" p.name;
  let task_id = Printf.sprintf "keeper_create_%s" p.name in
  let tracker = Progress.start_tracking ~task_id ~total_steps:6 () in
  Progress.Tracker.step tracker ~message:"Resolving keeper configuration" ();
  let now_ts = Time_compat.now () in
  let {
    goal;
    autoboot_enabled;
    allowed_paths;
    active_goal_ids;
    sandbox_profile;
    network_mode;
    multimodal_policy;
    mention_targets;
    proactive_enabled;
    auto_handoff;
    handoff_threshold;
    handoff_cooldown_sec;
    instructions;
    compaction_profile;
    compaction_ratio_gate;
    compaction_message_gate;
    compaction_token_gate;
    compaction_cooldown_sec;
    primary_max_context;
  } =
    derive_create_inputs p
  in
  let active_goal_ids_error =
    unknown_active_goal_ids_error ctx.config p ~active_goal_ids
  in
  if goal = "" then begin
    Log.Keeper.warn "create_keeper failed: goal is required (name=%s)" p.name;
    tool_result_error "goal is required when creating a keeper"
  end
  else match active_goal_ids_error with
  | Some msg -> tool_result_error msg
  | None ->
    match
      validate_sandbox_settings ~allowed_paths
    with
    | Error err ->
        Otel_metric_store.inc_counter
          Keeper_metrics.(to_string LifecycleDispatchRejections)
          ~labels:[("keeper", p.name); ("event", "create_sandbox_validation")]
          ();
        Log.Keeper.warn "create_keeper failed sandbox validation for %s: %s"
          p.name err;
        tool_result_error err
    | Ok () ->
              Progress.Tracker.step tracker ~message:"Initializing session directory" ();
              let trace_id = generate_trace_id () in
              match Keeper_id.Trace_id.of_string trace_id with
              | Error err ->
                  Otel_metric_store.inc_counter
                    Keeper_metrics.(to_string LifecycleDispatchRejections)
                    ~labels:[("keeper", p.name); ("event", "create_invalid_trace_id")]
                    ();
                  Log.Keeper.error
                    "create_keeper failed: generated invalid trace_id for name=%s: %s"
                    p.name err;
                  Progress.stop_tracking task_id;
                  tool_result_error "internal keeper trace_id generation failed"
              | Ok trace_id_t ->
                  let base_dir = session_base_dir ctx.config in
                  (* Ensure full session dir tree, not just base_dir (issue #3019) *)
                  ignore (Keeper_fs.ensure_dir (Filename.concat base_dir trace_id));
                  let bundle_paths =
                    (* Surface masc-improver/sangsu sandbox boot
                       silent-failure (2026-05-05).  Keeper_fs.ensure_dir
                       raises on filesystem error; the previous [ignore]
                       discarded it.  Now we log + emit a Otel_metric_store
                       counter so the dashboard makes failure visible
                       without aborting keeper boot.  ensure_dir runs under an
                       Eio.Mutex and re-raises [Eio.Cancel.Cancelled], so route
                       through the RFC-0106 SSOT combinator: a bare catch-all
                       would swallow Cancelled and let a cancelled create keep
                       booting a keeper that should not exist. *)
                    Cancel_safe.protect
                      ~on_exn:(fun exn ->
                        Log.Keeper.error
                          "create_keeper sandbox bundle init raised: keeper=%s exn=%s"
                          p.name (Printexc.to_string exn);
                        Otel_metric_store.inc_counter
                          Keeper_metrics.(to_string LifecycleDispatchRejections)
                          ~labels:[("keeper", p.name);
                                   ("event", "sandbox_bundle_init_raised")]
                          ();
                        [])
                      (fun () ->
                        Keeper_alerting_path.ensure_sandbox_bundle_for_profile
                          ~config:ctx.config ~name:p.name ~sandbox_profile)
                  in
                  List.iter (fun bp ->
                    if not (Sys.file_exists bp) then begin
                      Log.Keeper.warn
                        "create_keeper sandbox bundle path missing post-init: keeper=%s path=%s"
                        p.name bp;
                      Otel_metric_store.inc_counter
                        Keeper_metrics.(to_string LifecycleDispatchRejections)
                        ~labels:[("keeper", p.name);
                                 ("event", "sandbox_bundle_missing_post_init")]
                        ()
                    end) bundle_paths;
                  let session =
                    Keeper_context_runtime.create_session ~session_id:trace_id
                      ~base_dir
                  in
        let persona_extended =
          Keeper_types_profile.resolved_persona_name ~keeper_name:p.name
            p.profile_defaults
          |> Keeper_types_profile.load_persona_extended
          |> Option.value ~default:""
        in
        let active_goals =
          List.filter_map
            (fun goal_id ->
               match Goal_store.get_goal ctx.config ~goal_id with
               (* RFC-0294: active_goals tuple dropped its horizon element. *)
               | Some { Goal_store.id; title; _ } ->
                   Some (id, title)
               | None -> None)
            active_goal_ids
        in
        let system_prompt =
          build_keeper_system_prompt
            ~goal
            ~instructions
            ~persona_extended
            ~keeper_name:p.name
            ~active_goals
            ()
      in
      let ctx0 =
        Keeper_context_runtime.create ~eio:true ~system_prompt
          ~max_tokens:primary_max_context
      in
      (* next_generation keys the per-(keeper, trace) counter by the trace_id
         string; episodes live under that same string dir (ensure_dir/of
         session_id above), so pass the raw [trace_id] string, not the typed
         [trace_id_t]. Reuse the reservation for metadata and checkpoint
         creation so they cannot diverge. *)
      let generation =
        Keeper_memory_os_io.next_generation_for_base_path
          ~base_path:ctx.config.base_path
          ~keeper_id:p.name
          ~trace_id
      in
      let meta =
        Keeper_meta_build.initial_meta ~name:p.name
          ~agent_name:(Keeper_identity.keeper_agent_name p.name)
          ~persona_extended ~goal ~instructions ~sandbox_profile ~network_mode
          ~multimodal_policy ~allowed_paths ~mention_targets ~proactive_enabled
          ~compaction_profile
          ~compaction_mode:(Keeper_config.keeper_compaction_mode_default ())
          ~compaction_ratio_gate ~compaction_message_gate ~compaction_token_gate
          ~compaction_cooldown_sec ~auto_handoff ~handoff_threshold
          ~handoff_cooldown_sec ~created_at:(now_iso ())
          ~max_context_override:p.max_context_override_opt ~active_goal_ids
          ~autoboot_enabled
          ~telemetry_feedback_enabled:p.profile_defaults.telemetry_feedback_enabled
          ~telemetry_feedback_window_hours:
            p.profile_defaults.telemetry_feedback_window_hours
          ~always_allow:p.profile_defaults.always_allow ~now_ts ~generation
          ~trace_id:trace_id_t
          ~keeper_uid:(Keeper_id.Uid.generate ())
          ~oas_env:p.profile_defaults.oas_env ()
      in
      Progress.Tracker.step tracker ~message:"Saving initial checkpoint" ();
      let init_save_result =
        try
          Keeper_context_runtime.save_oas_checkpoint
            ~multimodal_policy:meta.multimodal_policy
            ~keeper_name:meta.name
            ~session
            ~agent_name:meta.agent_name
            ~ctx:ctx0
            ~generation
        with
        | Eio.Cancel.Cancelled _ as e -> raise e
        | exn ->
            log_keeper_exn ~label:"save_oas_checkpoint (init) exception" exn;
            Error (Printexc.to_string exn)
      in
      match init_save_result with
      | Error e ->
        Otel_metric_store.inc_counter
          Keeper_metrics.(to_string CheckpointFailures)
          ~labels:[("keeper", p.name); ("site", Keeper_checkpoint_failure_operation.(to_label Create_initial_save))]
          ();
        Log.Keeper.error
          "create_keeper failed: initial checkpoint save error for name=%s: %s"
          p.name e;
        Progress.stop_tracking task_id;
        tool_result_error (Printf.sprintf "initial checkpoint save failed: %s" e)
      | Ok _ ->
      let runtime_assignment_result =
        match p.runtime_id_opt with
        | None -> Ok ()
        | Some runtime_id ->
          Runtime.set_runtime_id_for_keeper
            ~keeper_name:p.name
            ~runtime_id
            ()
      in
      (match runtime_assignment_result with
       | Error e ->
         Otel_metric_store.inc_counter
           Keeper_metrics.(to_string LifecycleDispatchRejections)
           ~labels:[("keeper", p.name); ("event", "create_runtime_assignment")]
           ();
         Log.Keeper.error
           "create_keeper failed: runtime assignment error for name=%s: %s"
           p.name
           e;
         Progress.stop_tracking task_id;
         tool_result_error e
       | Ok () ->
      Progress.Tracker.step tracker ~message:"Writing keeper metadata" ();
      match write_initial_meta ctx.config meta with
      | Error e ->
        Otel_metric_store.inc_counter Keeper_metrics.(to_string WriteMetaFailures)
          ~labels:[("keeper", p.name); ("phase", "create_keeper")] ();
        Log.Keeper.error "create_keeper failed: write_meta error for name=%s: %s" p.name e;
        Progress.stop_tracking task_id;
        tool_result_error e
      | Ok () ->
        Log.Keeper.debug "create_keeper: metadata written for name=%s trace_id=%s"
          p.name (Keeper_id.Trace_id.to_string meta.runtime.trace_id);
        Progress.Tracker.step tracker ~message:"Starting keepalive loop" ();
        Log.Keeper.info "create_keeper: starting keepalive for name=%s" p.name;
        let launch_outcome = start_keepalive ctx meta in
        (match launch_outcome with
         | Keepalive_started _ ->
        Progress.Tracker.complete tracker ~message:"Keeper created" ();
        Log.Keeper.info "create_keeper: completed for name=%s trace_id=%s" p.name (Keeper_id.Trace_id.to_string meta.runtime.trace_id);
        let json = `Assoc [
          ("name", `String meta.name);
          ("agent_name", `String meta.agent_name);
          ("trace_id", `String (Keeper_id.Trace_id.to_string meta.runtime.trace_id));
          ("generation", `Int meta.runtime.generation);
          ("goal", `String meta.goal);
          ("instructions", `String meta.instructions);
          ("proactive_enabled", `Bool meta.proactive.enabled);
          ("compaction_profile", `String meta.compaction.profile);
          ("compaction_mode",
            `String (Keeper_config.compaction_mode_to_string meta.compaction.mode));
          ("compaction_ratio_gate", `Float meta.compaction.ratio_gate);
          ("compaction_message_gate", `Int meta.compaction.message_gate);
          ("compaction_token_gate", `Int meta.compaction.token_gate);
          ("max_context_override", Json_util.int_opt_to_json meta.max_context_override);
          ("auto_handoff", `Bool meta.auto_handoff);
          ("handoff_threshold", `Float meta.handoff_threshold);
          ("oas_env", `Assoc (List.map (fun (k, v) -> (k, `String v)) meta.oas_env));
        ] in
        tool_result_ok_data json
         | ( Keepalive_already_registered _
           | Keepalive_lifecycle_denied _
           | Keepalive_identity_unrepairable
           | Keepalive_registration_rejected _
           | Keepalive_fiber_start_rejected _
           | Keepalive_lane_ownership_lost
           | Keepalive_fork_rejected _ ) as rejected ->
           Progress.stop_tracking task_id;
           tool_result_error
             (Printf.sprintf
                "keeper metadata was created but lane launch failed: %s"
                (start_keepalive_outcome_to_string rejected))))
