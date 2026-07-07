(* keeper_run_context — Steps 0–4 of run_turn: inference params, session dir,
   checkpoint load, base prompt, working context, checkpoint hygiene.

   Extracted from keeper_agent_run.ml. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile

(** Resolved inference and session context needed before prompt construction. *)
type run_context =
  { meta : keeper_meta
  ; temperature : float
  ; max_tokens : int
  ; context_injector : Agent_sdk.Hooks.context_injector
  ; shared_context : Agent_sdk.Context.t
  ; session_dir : string
  ; session : Keeper_types.session_context
  ; loaded_checkpoint_present : bool
  ; base_system_prompt : string
  ; ctx_work : working_context
  ; resume_oas_checkpoint : Agent_sdk.Checkpoint.t option
  ; pre_dispatch_compacted : bool
  ; pre_dispatch_compaction_trigger : string option
  ; pre_dispatch_compaction_before_tokens : int option
  ; pre_dispatch_compaction_after_tokens : int option
  ; pre_dispatch_checkpoint_error : Agent_sdk.Error.sdk_error option
  ; start_turn_count : int
  ; receipt_started_at : string
  ; config_root : string
  ; runtime_config_path : string option
  }

let prompt_profile_default default current =
  (* DET-OK: keeper TOML/persona profile defaults are the declarative
     prompt-config boundary; persisted meta is the legacy fallback. *)
  match default with
  | Some value -> value
  | None -> current

let build_base_system_prompt
      ~(config : Workspace.config)
      ~(profile_defaults : Keeper_types_profile.keeper_profile_defaults)
      ~(meta : keeper_meta)
  =
  let persona_extended =
    Keeper_types_profile.resolved_persona_name ~keeper_name:meta.name
      profile_defaults
    |> Keeper_types_profile.load_persona_extended
    |> Option.value ~default:""
  in
  let active_goals =
    List.filter_map
      (fun goal_id ->
         match Goal_store.get_goal config ~goal_id with
         (* RFC-0294: active_goals tuple dropped its horizon element. *)
         | Some { Goal_store.id; title; _ } -> Some (id, title)
         | None -> None)
      meta.active_goal_ids
  in
  let registered_repos =
    (* Enumerate registered repository ids so the system prompt can list the
       valid [repos/<name>] segments. A failed catalog read yields [] (no
       block), matching the empty-goals/empty-home degrade-to-silence policy. *)
    match Repo_store.load_all ~base_path:config.base_path with
    | Ok repos -> List.map (fun (r : Repo_manager_types.repository) -> r.id) repos
    | Error _ -> []
  in
  Keeper_prompt.build_keeper_system_prompt
    ~goal:(prompt_profile_default profile_defaults.goal meta.goal)
    ~instructions:
      (prompt_profile_default profile_defaults.instructions meta.instructions)
    ~persona_extended
    ~keeper_name:meta.name
    ~active_goals
    ~home_ground:config.base_path
    ~registered_repos
    ()

let max_tokens_fallback ~keeper_name profile_defaults () =
  match
    Keeper_types_profile.unified_max_tokens_override_of_oas_env
      ~keeper_name
      profile_defaults.oas_env
  with
  | Some value -> value
  | None -> 8192

let resolve_max_tokens_for_runtime_with_profile ~keeper_name ~profile_defaults
      ?max_tokens ~runtime_id ()
  =
  match max_tokens with
  | Some t ->
    Runtime_inference.cap_max_tokens_to_runtime_ceiling
      ~runtime_id
      ~source:"caller_override"
      t
  | None ->
    Runtime_inference.resolve_max_tokens
      ~runtime_id
      ~fallback:(max_tokens_fallback ~keeper_name profile_defaults)

let resolve_max_tokens_for_runtime ~keeper_name ~runtime_id ?max_tokens () =
  let profile_defaults =
    Keeper_types_profile.load_keeper_profile_defaults keeper_name
  in
  resolve_max_tokens_for_runtime_with_profile
    ~keeper_name ~profile_defaults ?max_tokens ~runtime_id ()

let prepare_run_context
      ~(config : Workspace.config)
      ~(meta : keeper_meta)
      ~(base_dir : string)
      ~(max_context : int)
      ~(runtime_id : string)
      ?temperature
      ?max_tokens
      ?shared_context
      ~(generation : int)
      ()
  =
  let receipt_started_at = Masc_domain.now_iso () in
  let meta = Keeper_agent_tool_surface.sync_current_task_id_from_backlog ~config meta in
  let validated_goal_ids =
    Keeper_runtime_contract.validate_active_goal_ids ~config ~meta ()
  in
  let meta =
    if List.length validated_goal_ids <> List.length meta.active_goal_ids then
      { meta with active_goal_ids = validated_goal_ids }
    else
      meta
  in
  let profile_defaults = Keeper_types_profile.load_keeper_profile_defaults meta.name in
  (* 0. Resolve inference parameters via Runtime_inference *)
  let temperature =
    match temperature with
    | Some t -> t
    | None ->
      Runtime_inference.resolve_temperature
        ~runtime_id ~fallback:(fun () -> 0.3)
  in
  let max_tokens =
    resolve_max_tokens_for_runtime_with_profile
      ~keeper_name:meta.name
      ~profile_defaults
      ?max_tokens
      ~runtime_id
      ()
  in
  (* 0b. Create context injector for temporal awareness *)
  let injector_config = Masc_context_injector.default_config () in
  let context_injector = Masc_context_injector.make ~config:injector_config () in
  let shared_context =
    match shared_context with
    | Some ctx -> ctx
    | None -> Agent_sdk.Context.create ()
  in
  (* 1. Ensure session directory tree exists *)
  let session_dir =
    Filename.concat base_dir (Keeper_id.Trace_id.to_string meta.runtime.trace_id)
  in
  let (_ : string) = Keeper_fs.ensure_dir session_dir in
  (* 2. Load checkpoint *)
  let session, ctx_opt =
    Keeper_context_runtime.load_context_from_checkpoint
      ~max_checkpoint_messages:meta.compaction.max_checkpoint_messages
      ~trace_id:(Keeper_id.Trace_id.to_string meta.runtime.trace_id)
      ~primary_model_max_tokens:max_context
      ~base_dir
  in
  let loaded_checkpoint_present = Option.is_some ctx_opt in
  (* 3. Build base system prompt from meta *)
  let config_root =
    let inputs = Config_dir_resolver.inputs_from_env () in
    let resolution =
      Config_dir_resolver.resolve_with
        { inputs with env_base_path = Some config.base_path }
    in
    resolution.Config_dir_resolver.config_root.path
  in
  let runtime_config_path = Runtime.config_path () in
  let base_system_prompt =
    build_base_system_prompt ~config ~profile_defaults ~meta
  in
  (* 4. Create or restore working context, re-apply current prompt *)
  let base_ctx =
    match ctx_opt with
    | Some c -> c
    | None ->
      Keeper_context_runtime.create ~eio:true ~system_prompt:base_system_prompt
        ~max_tokens:max_context
  in
  let ctx_work =
    Keeper_context_runtime.set_system_prompt base_ctx ~system_prompt:base_system_prompt
  in
  let checkpoint_hygiene =
    Keeper_agent_checkpoint_hygiene.prepare_resume_checkpoint_for_dispatch
      ~meta
      ~now_ts:(Time_compat.now ())
      ~loaded_checkpoint_present
      ~save_checkpoint:(fun compacted_ctx ->
        Keeper_context_runtime.save_oas_checkpoint
          ~max_checkpoint_messages:meta.compaction.max_checkpoint_messages
          ~multimodal_policy:meta.multimodal_policy
          ~keeper_name:meta.name
          ~session
          ~agent_name:meta.agent_name
          ~ctx:compacted_ctx
          ~generation)
      ctx_work
  in
  let ctx_work = checkpoint_hygiene.context in
  let resume_oas_checkpoint = checkpoint_hygiene.resume_checkpoint in
  let pre_dispatch_compacted = checkpoint_hygiene.compacted in
  let pre_dispatch_compaction_trigger =
    match checkpoint_hygiene.trigger with
    | Some trigger -> Some (Compaction_trigger.to_human trigger)
    | None -> None
  in
  let pre_dispatch_compaction_before_tokens =
    if checkpoint_hygiene.applied then Some checkpoint_hygiene.before_tokens else None
  in
  let pre_dispatch_compaction_after_tokens =
    if checkpoint_hygiene.applied then Some checkpoint_hygiene.after_tokens else None
  in
  let pre_dispatch_checkpoint_error =
    match checkpoint_hygiene.save_error with
    | Some detail ->
      Otel_metric_store.inc_counter
        Keeper_metrics.(to_string RunContextFailures)
        ~labels:[("keeper", meta.name)]
        ();
      Log.Keeper.error
        "%s: pre-dispatch checkpoint compaction save failed: %s"
        meta.name detail;
      Some
        (Keeper_agent_error.checkpoint_persistence_error
           ~keeper_name:meta.name
           ~detail:("pre-dispatch checkpoint compaction save failed: " ^ detail))
    | None -> None
  in
  (let decision =
     match checkpoint_hygiene.trigger with
     | Some trigger -> Compaction_trigger.to_human trigger
     | None ->
       Keeper_compact_policy.compaction_decision_to_string
         checkpoint_hygiene.decision
   in
   let before_ratio =
     if max_context <= 0 then 0.0
     else float_of_int checkpoint_hygiene.before_tokens /. float_of_int max_context
   in
   if checkpoint_hygiene.applied then
     Log.Keeper.info
       "%s: pre-dispatch compaction %s trigger=%s tokens=%d->%d \
        max_context=%d ratio=%.4f checkpoint=%b"
       meta.name
       (if checkpoint_hygiene.meaningful_reduction then "applied" else "attempted")
       decision checkpoint_hygiene.before_tokens checkpoint_hygiene.after_tokens
       max_context before_ratio loaded_checkpoint_present
  else
     Log.Keeper.routine
       "%s: pre-dispatch compaction skipped decision=%s tokens=%d \
        max_context=%d ratio=%.4f checkpoint=%b"
       meta.name decision checkpoint_hygiene.before_tokens max_context before_ratio
       loaded_checkpoint_present);
  let start_turn_count =
    match resume_oas_checkpoint with
    | Some cp -> cp.turn_count
    | None -> 0
  in
  { meta
  ; temperature
  ; max_tokens
  ; context_injector
  ; shared_context
  ; session_dir
  ; session
  ; loaded_checkpoint_present
  ; base_system_prompt
  ; ctx_work
  ; resume_oas_checkpoint
  ; pre_dispatch_compacted
  ; pre_dispatch_compaction_trigger
  ; pre_dispatch_compaction_before_tokens
  ; pre_dispatch_compaction_after_tokens
  ; pre_dispatch_checkpoint_error
  ; start_turn_count
  ; receipt_started_at
  ; config_root
  ; runtime_config_path
  }
