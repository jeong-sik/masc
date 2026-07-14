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
  (* RFC-0324 B-1: no catalog-fed repository list is injected into the
     prompt any more — the filesystem is the repo truth and the prompt's
     constant <repositories> block instructs self-discovery. *)
  Keeper_prompt.build_keeper_system_prompt
    ~goal:(prompt_profile_default profile_defaults.goal meta.goal)
    ~instructions:
      (prompt_profile_default profile_defaults.instructions meta.instructions)
    ~persona_extended
    ~keeper_name:meta.name
    ~active_goals
    ~home_ground:config.base_path
    ()

let prepare_run_context
      ~(config : Workspace.config)
      ~(meta : keeper_meta)
      ~(profile_defaults : Keeper_types_profile.keeper_profile_defaults)
      ~(base_dir : string)
      ~(max_context : int)
      ~(runtime_id : string)
      ?temperature
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
  (* 0. Resolve inference parameters via Runtime_inference *)
  let fallback_temperature () =
    match temperature with
    | Some value -> value
    | None -> Keeper_config.keeper_unified_temperature ()
  in
  let temperature =
    Runtime_inference.resolve_temperature
      ~runtime_id
      ~fallback:fallback_temperature
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
  (* Preserve the restored context exactly. MASC does not classify, compact,
     truncate, or re-persist it before dispatch; OAS owns provider context
     handling. Checkpoint persistence failure therefore cannot block this
     turn before the provider has observed the input. *)
  let resume_oas_checkpoint =
    if loaded_checkpoint_present
    then Some (Keeper_context_runtime.checkpoint_of_context ctx_work)
    else None
  in
  let pre_dispatch_compacted = false in
  let pre_dispatch_compaction_trigger = None in
  let pre_dispatch_compaction_before_tokens = None in
  let pre_dispatch_compaction_after_tokens = None in
  let pre_dispatch_checkpoint_error = None in
  let start_turn_count =
    match resume_oas_checkpoint with
    | Some cp -> cp.turn_count
    | None -> 0
  in
  { meta
  ; temperature
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
