(* keeper_run_context — Steps 0–4 of run_turn: inference params, session dir,
   checkpoint load, base prompt, working context, checkpoint hygiene.

   Extracted from keeper_agent_run.ml. *)

open Keeper_types

(** Resolved inference and session context needed before prompt construction. *)
type run_context =
  { temperature : float
  ; max_tokens : int
  ; context_injector : Agent_sdk.Hooks.context_injector
  ; shared_context : Oas.Context.t
  ; session_dir : string
  ; session : Keeper_types.session_context
  ; loaded_checkpoint_present : bool
  ; base_system_prompt : string
  ; ctx_work : working_context
  ; resume_oas_checkpoint : Oas.Checkpoint.t option
  ; pre_dispatch_compacted : bool
  ; start_turn_count : int
  ; receipt_started_at : string
  ; config_root : string
  ; cascade_config_path : string option
  ; gemini_mcp_disabled : bool
  ; approval_mode_effective : string option
  ; approval_mode_derived : bool
  ; keeper_oas_context : Keeper_types_profile.keeper_oas_context
  }

let prepare_run_context
      ~(config : Coord.config)
      ~(meta : keeper_meta)
      ~(base_dir : string)
      ~(max_context : int)
      ~(cascade_name : string)
      ?temperature
      ?max_tokens
      ?shared_context
      ~(generation : int)
      ()
  =
  let receipt_started_at = Types.now_iso () in
  let meta = Keeper_agent_tool_surface.sync_current_task_id_from_backlog ~config meta in
  (* 0. Resolve inference parameters via Cascade_inference *)
  let temperature =
    match temperature with
    | Some t -> t
    | None ->
      Cascade_inference.resolve_temperature ~cascade_name ~fallback:(fun () -> 0.3)
  in
  let max_tokens =
    match max_tokens with
    | Some t -> t
    | None ->
      Cascade_inference.resolve_max_tokens
        ~cascade_name
          (* 8192 allows complex multi-tool reasoning per turn.
           Cloudflare tunnel 100s is no longer a constraint with
           streaming responses. *)
        ~fallback:(fun () -> 8192)
  in
  (* 0b. Create context injector for temporal awareness *)
  let injector_config = Masc_context_injector.default_config () in
  let context_injector = Masc_context_injector.make ~config:injector_config () in
  let shared_context =
    match shared_context with
    | Some ctx -> ctx
    | None -> Oas.Context.create ()
  in
  (* 1. Ensure session directory tree exists *)
  let session_dir =
    Filename.concat base_dir (Keeper_id.Trace_id.to_string meta.runtime.trace_id)
  in
  mkdir_p session_dir;
  (* 2. Load checkpoint *)
  let session, ctx_opt =
    Keeper_exec_context.load_context_from_checkpoint
      ~max_checkpoint_messages:meta.compaction.max_checkpoint_messages
      ~trace_id:(Keeper_id.Trace_id.to_string meta.runtime.trace_id)
      ~primary_model_max_tokens:max_context
      ~base_dir
  in
  let loaded_checkpoint_present = Option.is_some ctx_opt in
  (* 3. Build base system prompt from meta *)
  let profile_defaults = Keeper_types_profile.load_keeper_profile_defaults meta.name in
  let keeper_oas_context =
    Keeper_types_profile.keeper_oas_context_of_defaults profile_defaults
  in
  let config_root =
    let inputs = Config_dir_resolver.inputs_from_env () in
    let resolution =
      Config_dir_resolver.resolve_with
        { inputs with env_base_path = Some config.base_path }
    in
    resolution.Config_dir_resolver.config_root.path
  in
  let cascade_config_path = Cascade_runtime.cascade_config_path () in
  let gemini_mcp_disabled = keeper_oas_context.gemini_mcp_disabled in
  let approval_mode_effective = keeper_oas_context.gemini_approval_mode in
  let approval_mode_derived = keeper_oas_context.gemini_approval_mode_derived in
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
         | Some { Goal_store.id; title; horizon } ->
             let horizon_str =
               match horizon with
               | Goal_store.Short -> "short"
               | Goal_store.Mid -> "mid"
               | Goal_store.Long -> "long"
             in
             Some (id, title, horizon_str)
         | None -> None)
      meta.active_goal_ids
  in
  let base_system_prompt =
    Keeper_prompt.build_keeper_system_prompt
      ~goal:meta.goal
      ~short_goal:meta.short_goal
      ~mid_goal:meta.mid_goal
      ~long_goal:meta.long_goal
      ~will:meta.will
      ~needs:meta.needs
      ~desires:meta.desires
      ~instructions:meta.instructions
      ~persona_extended
      ~keeper_name:meta.name
      ~allowed_orgs:(Keeper_tool_policy.git_clone_allowed_orgs ())
      ~denied_repos:(Keeper_tool_policy.git_clone_denied_repos ())
      ~active_goals
      ()
  in
  (* 4. Create or restore working context, re-apply current prompt *)
  let base_ctx =
    match ctx_opt with
    | Some c -> c
    | None ->
      Keeper_exec_context.create ~system_prompt:base_system_prompt ~max_tokens:max_context
  in
  let ctx_work =
    Keeper_exec_context.set_system_prompt base_ctx ~system_prompt:base_system_prompt
  in
  let checkpoint_hygiene =
    Keeper_agent_checkpoint_hygiene.prepare_resume_checkpoint_for_dispatch
      ~meta
      ~now_ts:(Time_compat.now ())
      ~loaded_checkpoint_present
      ~save_checkpoint:(fun compacted_ctx ->
        Keeper_exec_context.save_oas_checkpoint
          ~max_checkpoint_messages:meta.compaction.max_checkpoint_messages
          ~session
          ~agent_name:meta.agent_name
          ~model:(Keeper_exec_context.checkpoint_model_of_meta meta)
          ~ctx:compacted_ctx
          ~generation)
      ctx_work
  in
  let ctx_work = checkpoint_hygiene.context in
  let resume_oas_checkpoint = checkpoint_hygiene.resume_checkpoint in
  let pre_dispatch_compacted = checkpoint_hygiene.compacted in
  (match checkpoint_hygiene.save_error with
   | Some detail ->
       Log.Keeper.error
         "%s: pre-dispatch checkpoint compaction save failed: %s"
         meta.name detail
   | None -> ());
  (if checkpoint_hygiene.applied then
     Log.Keeper.info
       "%s: pre-dispatch compaction %s trigger=%s tokens=%d->%d max_context=%d"
       meta.name
       (if checkpoint_hygiene.meaningful_reduction then "applied" else "attempted")
       (Option.value ~default:checkpoint_hygiene.decision checkpoint_hygiene.trigger)
       checkpoint_hygiene.before_tokens checkpoint_hygiene.after_tokens max_context);
  let start_turn_count =
    match resume_oas_checkpoint with
    | Some cp -> cp.turn_count
    | None -> 0
  in
  { temperature
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
  ; start_turn_count
  ; receipt_started_at
  ; config_root
  ; cascade_config_path
  ; gemini_mcp_disabled
  ; approval_mode_effective
  ; approval_mode_derived
  ; keeper_oas_context
  }
