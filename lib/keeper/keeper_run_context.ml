(* keeper_run_context — Steps 0–4 of run_turn: inference params, session dir,
   checkpoint load, base prompt, working context, checkpoint hygiene.

   Extracted from keeper_agent_run.ml. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile

(* What the turn knows, when it starts, about the history saved for its trace. *)
type saved_history =
  | Saved_history_loaded
  | Saved_history_absent
  | Saved_history_superseded

(** Resolved inference and session context needed before prompt construction. *)
type run_context =
  { meta : keeper_meta
  ; task_context : Keeper_turn_task_context.t
  ; temperature : float
  ; context_injector : Agent_core.Hooks.context_injector
  ; shared_context : Agent_core.Context.t
  ; session_dir : string
  ; session : Keeper_types.session_context
  ; saved_history : saved_history
  ; system : Keeper_turn_system.t
  ; workspace_root : string
  ; ctx_work : working_context
  ; resume_agent_core_checkpoint : Agent_core.Checkpoint.t option
  ; start_turn_count : int
  ; receipt_started_at : string
  ; config_root : string
  ; runtime_config_path : string option
  }

(* Why a turn could not be prepared. All three failed before anything was
   dispatched; the caller turns each into the same not-dispatched
   settlement. *)
type base_prompt_error =
  | Workspace_unavailable of string
  | Constitution_unreadable of World_constitution_store.read_error

let base_prompt_error_to_string = function
  | Workspace_unavailable detail -> detail
  | Constitution_unreadable error -> World_constitution_store.read_error_to_string error

type prepare_error =
  | Checkpoint_unread of Keeper_checkpoint_store.checkpoint_load_error
  | Base_prompt_unavailable of base_prompt_error
  | Prompt_unrenderable of string
  | Turn_system_unreadable of string

type recorded_system =
  { runtime_id : string
  ; text : string
  }

let build_base_system_prompt
      ~(config : Workspace.config)
      ~(profile_defaults : Keeper_types_profile.keeper_profile_defaults)
      ~(meta : keeper_meta)
  =
  let open Result.Syntax in
  let* workspace_root =
    Keeper_workspace_namespace.resolve ~config ~meta ~profile_defaults
    |> Result.map_error (fun detail -> Workspace_unavailable detail)
  in
  let* prompt =
    Keeper_unified_prompt.build_system_prompt
      ~workspace_root ~meta ~config ~profile_defaults ()
    |> Result.map_error (fun error -> Constitution_unreadable error)
  in
  Ok (workspace_root, prompt)

(* Who composes the turn's first request, and for Agent Core where its range
   opens against the last request on that runtime (RFC-0491 §3.2). The
   runtime is the head of the walk a fresh turn takes, as the turn driver
   orders it; the range is the one the driver composes over [history] before
   the turn's input is appended, read the way the forecast reads it. *)
let first_request_lane ~config ~(meta : keeper_meta) ~runtime_id history =
  (* NDT-OK: one wall-clock read at the boundary, compared with stored expiries. *)
  let now = Unix.gettimeofday () in
  let walk =
    Keeper_turn_driver.Fresh_walk_by
      (Runtime_candidate_backpressure.keeper_recorder ~keeper_name:meta.name)
  in
  match Keeper_turn_driver.assignment_walk_order ~now ~walk runtime_id with
  | Error (Keeper_turn_driver.Assignment_missing | Keeper_turn_driver.Catalog_unavailable _)
  | Ok { Keeper_turn_driver.order = []; _ } -> Keeper_turn_system.Without_basis
  | Ok { Keeper_turn_driver.order = head :: _; _ } ->
    (match Keeper_carried_front.composer_of_runtime (Runtime.get_runtime_by_id head) with
     | Keeper_carried_front.Hands_over_its_own_list | Keeper_carried_front.Not_materialized ->
       Keeper_turn_system.Without_basis
     | Keeper_carried_front.Composes_from_the_history ->
       let keeper_name = meta.name in
       let trace_id = Keeper_id.Trace_id.to_string meta.runtime.trace_id in
       let reads = Keeper_next_request_forecast.read_range ~config ~keeper_name ~trace_id history in
       let { Keeper_next_request_forecast.carried; ledger_front } =
         Keeper_next_request_forecast.first_request ~keeper_name ~trace_id ~runtime_id:head reads
       in
       Keeper_turn_system.Agent_core
         { runtime_id = head
         ; front =
             Keeper_turn_system.front
               ~digest_at:reads.Keeper_next_request_forecast.digest_at
               ~first_atom:carried.Keeper_next_request_forecast.first_atom
               ~previous:ledger_front
         })

(* The System this turn sends: the same namespace and articles
   {!build_base_system_prompt} reads, rendered as {!Keeper_turn_system.issue}
   decides, or a native continuation's recorded bytes as
   {!Keeper_turn_system.resend} gives them. [held] is what the loaded
   checkpoint's session context recorded. *)
let issue_system ~config ~profile_defaults ~(meta : keeper_meta) ~runtime_id ~held
      ?recorded_system history =
  let open Result.Syntax in
  let* workspace_root =
    Keeper_workspace_namespace.resolve ~config ~meta ~profile_defaults
    |> Result.map_error (fun detail -> Workspace_unavailable detail)
  in
  let base_path = config.Workspace.base_path in
  let* resolve_subject =
    Keeper_constitution_roster.read ~config
    |> Result.map_error (fun error -> Constitution_unreadable error)
  in
  let* projection =
    World_constitution_store.load_held ~base_path ~resolve_subject
    |> Result.map_error (fun error -> Constitution_unreadable error)
  in
  let current = projection.World_constitution_store.articles in
  let at = projection.World_constitution_store.at in
  let articles_at = World_constitution_store.load_articles_at ~base_path ~resolve_subject in
  let* system, held =
    (match recorded_system with
     | Some { runtime_id; text } ->
       Keeper_turn_system.resend ~held ~runtime_id ~current ~articles_at text
     | None ->
       Keeper_turn_system.issue ~held
         ~lane:(first_request_lane ~config ~meta ~runtime_id history)
         ~render:(Keeper_unified_prompt.render_system_prompt ~workspace_root ~meta ~profile_defaults)
         ~current ~at ~articles_at
       |> Result.map (fun (system, held) -> system, Some held))
    |> Result.map_error (fun error -> Constitution_unreadable error)
  in
  let system = Keeper_turn_system.with_withheld projection.withheld_ids system in
  Ok (workspace_root, system, held)

let prepare_run_context
      ~(config : Workspace.config)
      ~(meta : keeper_meta)
      ~(profile_defaults : Keeper_types_profile.keeper_profile_defaults)
      ~(base_dir : string)
      ~(runtime_id : string)
      ?temperature
      ?shared_context
      ?checkpoint
      ?recorded_system
      ()
  =
  let open Result.Syntax in
  let receipt_started_at = Masc_domain.now_iso () in
  let meta, observed_task = Keeper_current_task_reconcile.sync_current_task_id_with_observation ~config meta in
  let task_context = Keeper_turn_task_context.capture ~config observed_task in
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
    | None -> Agent_core.Context.create ()
  in
  (* 1. Ensure session directory tree exists *)
  let session_dir =
    Filename.concat base_dir (Keeper_id.Trace_id.to_string meta.runtime.trace_id)
  in
  let (_ : string) = Keeper_fs.ensure_dir session_dir in
  (* 2. Load checkpoint *)
  let session, checkpoint_load =
    match checkpoint with
    | Some checkpoint ->
      ( Keeper_context_runtime.create_session
          ~session_id:(Keeper_id.Trace_id.to_string meta.runtime.trace_id)
          ~base_dir
      , Keeper_context_runtime.Checkpoint_loaded
          (Keeper_context_runtime.context_of_agent_core_checkpoint checkpoint) )
    | None ->
      Keeper_context_runtime.load_context_from_checkpoint_classified
        ~keeper_name:meta.name
        ~trace_id:(Keeper_id.Trace_id.to_string meta.runtime.trace_id)
        ~base_dir
  in
  let* ctx_opt, saved_history =
    match checkpoint_load with
    | Keeper_context_runtime.Checkpoint_loaded loaded -> Ok (Some loaded, Saved_history_loaded)
    | Keeper_context_runtime.Checkpoint_absent -> Ok (None, Saved_history_absent)
    | Keeper_context_runtime.Checkpoint_unread (Keeper_checkpoint_store.Superseded_version _) ->
      Ok (None, Saved_history_superseded)
    | Keeper_context_runtime.Checkpoint_unread
        (( Keeper_checkpoint_store.Not_found
         | Keeper_checkpoint_store.Store_error _
         | Keeper_checkpoint_store.Parse_error _
         | Keeper_checkpoint_store.Newer_version _
         | Keeper_checkpoint_store.Io_error _
         | Keeper_checkpoint_store.Read_failed _
         | Keeper_checkpoint_store.Agent_core_error _
         | Keeper_checkpoint_store.Objects_invalid _ ) as error) ->
      Error (Checkpoint_unread error)
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
  let* held =
    match ctx_opt with
    | None -> Ok None
    | Some loaded ->
      Keeper_turn_system.read (Keeper_context_core.agent_core_context_of_context loaded)
      |> Result.map_error (fun detail -> Turn_system_unreadable detail)
  in
  let* workspace_root, system, held =
    (* Prompt rendering raises [Invalid_argument] when a slot is missing or
       fails to render; that is a typed refusal here, not a crashed cycle. *)
    (try
       issue_system ~config ~profile_defaults ~meta ~runtime_id ~held ?recorded_system
         (Option.fold ~none:[] ~some:Keeper_context_runtime.messages_of_context ctx_opt)
       |> Result.map_error (fun error -> Base_prompt_unavailable error)
     with Invalid_argument detail -> Error (Prompt_unrenderable detail))
  in
  (* The context the turn's checkpoints persist names the System this turn
     issued, so the next turn and a native continuation of this one read it
     back with the history it was sent with. *)
  Option.iter (Keeper_turn_system.write shared_context) held;
  (* 4. Create or restore working context, re-apply current prompt *)
  let base_ctx =
    match ctx_opt with
    | Some c -> c
    | None ->
      Keeper_context_runtime.create ~eio:true ~system_prompt:system.Keeper_turn_system.text
  in
  let ctx_work =
    Keeper_context_runtime.set_system_prompt base_ctx ~system_prompt:system.Keeper_turn_system.text
  in
  (* Preserve the restored context exactly. Nothing is re-persisted before
     dispatch; a failed read has already returned without creating a context
     that could overwrite the saved history. *)
  let resume_agent_core_checkpoint =
    if loaded_checkpoint_present
    then Some (Keeper_context_runtime.checkpoint_of_context ctx_work)
    else None
  in
  let start_turn_count =
    match resume_agent_core_checkpoint with
    | Some cp -> cp.turn_count
    | None -> 0
  in
  Ok { meta
  ; task_context
  ; temperature
  ; context_injector
  ; shared_context
  ; session_dir
  ; session
  ; saved_history
  ; system
  ; workspace_root
  ; ctx_work
  ; resume_agent_core_checkpoint
  ; start_turn_count
  ; receipt_started_at
  ; config_root
  ; runtime_config_path
  }

let loaded_checkpoint_present (ctx : run_context) =
  match ctx.saved_history with
  | Saved_history_loaded -> true
  | Saved_history_absent | Saved_history_superseded -> false
;;
