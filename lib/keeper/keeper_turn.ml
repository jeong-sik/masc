(** Keeper_turn -- keeper lifecycle and message-turn handlers.

    Orchestrates keeper turns by building domain-specific system prompt
    configuration and delegating to {!Keeper_agent_run.run_turn} which
    owns the full AGENT_CORE-backed context lifecycle (checkpoint, prompt state,
    Agent.run).

    Sub-modules:
    - Keeper_turn_up: start/reconfigure
    - Keeper_turn_setup: ensure_keeper_exists
    - Keeper_turn_lifecycle: shutdown *)

open Tool_args
open Keeper_types
open Keeper_meta_contract
open Keeper_meta_store
open Keeper_types_profile
open Keeper_memory
open Keeper_alerting
open Keeper_keepalive
open Keeper_execution
open Keeper_turn_setup
open Otel_spans

type tool_result = Keeper_types_profile.tool_result

let handle_keeper_up = Keeper_turn_up.handle_keeper_up
let handle_keeper_down = Keeper_turn_lifecycle.handle_keeper_down

let restart_keepalive_after_message_turn ctx meta =
  match start_keepalive ctx meta with
  | Keepalive_started _ | Keepalive_already_registered _ -> ()
  | outcome ->
    Log.Keeper.error
      "keeper message turn did not restore keepalive name=%s outcome=%s"
      meta.name
      (start_keepalive_outcome_to_string outcome)
;;

let direct_turn_observation ~(config : Workspace.config) (meta : keeper_meta) :
    Keeper_world_observation.world_observation =
  Keeper_world_observation.observe_direct_keeper_msg
    ~config
    ~meta

let direct_turn_task_context
      ~(current_task : Keeper_world_observation_inputs.current_task_observation)
      ~(held_task_skills : Keeper_world_observation_inputs.held_task_skills list)
      ~(task_skill_surfaces : (string * Keeper_skill_catalog.exact_surface list) list)
  : string
  =
  let current =
    let skill_surfaces =
      match current_task with
      | Keeper_world_observation_inputs.Current_task task
      | Recovered_current_task { task; _ } -> List.assoc_opt task.id task_skill_surfaces
      | No_current_task | Current_task_missing _ | Current_task_unavailable _ -> None
    in
    match Keeper_unified_prompt.format_current_task_observation ?skill_surfaces current_task with
    | Some rendered -> rendered
    | None -> ""
  in
  let held =
    match Keeper_unified_prompt.format_held_task_skills ~skill_surfaces_by_task:task_skill_surfaces held_task_skills with
    | Some rendered -> rendered
    | None -> ""
  in
  current ^ held

let direct_turn_dynamic_context
      ~(current_task : Keeper_world_observation_inputs.current_task_observation)
      ~(held_task_skills : Keeper_world_observation_inputs.held_task_skills list)
      ~(task_skill_surfaces : (string * Keeper_skill_catalog.exact_surface list) list)
      ~(approval_authority_text : string)
      ~(recent_direct_conversation_text : string)
      ~(worktree_text : string)
      ~(telemetry_feedback_text : string)
      ~(turn_instructions_text : string)
  : string
  =
  [ direct_turn_task_context ~current_task ~held_task_skills ~task_skill_surfaces
  ; approval_authority_text
  ; recent_direct_conversation_text
  ; worktree_text
  ; telemetry_feedback_text
  ; turn_instructions_text
  ]
  |> List.filter (fun text -> String.trim text <> "")
  |> String.concat "\n\n"

let direct_owner_conversation_context
      ~(config : Workspace.config)
      ~(meta : keeper_meta)
      ~(direct_reply : bool)
      ~(channel_session_key : string option)
      ~(channel : string)
  : string
  =
  if (not direct_reply) || Option.is_some channel_session_key || String.trim channel <> ""
  then ""
  else
    Keeper_world_observation_message_scope.collect_recent_direct_conversation
      ~limit:8 ~config ~meta ()
    |> Keeper_world_observation_message_scope.render_recent_direct_conversation_context

(* Flatten newlines/tabs to spaces and trim, so a co-view value never breaks
   the line-oriented instruction block. *)
let normalized_surface_context_value value =
  value
  |> String.to_seq
  |> Seq.map (function '\n' | '\r' | '\t' -> ' ' | ch -> ch)
  |> String.of_seq
  |> String.trim

let surface_context_field_value = function
  | `String s -> normalized_surface_context_value s
  | json -> Yojson.Safe.to_string json

(* Accept fields as BOTH the dashboard wire shape [`List of {k,v} objects] and a
   plain [`Assoc] map. The earlier keeper_turn copy matched only `Assoc and
   silently dropped the dashboard's list shape on the MCP tool path. *)
let surface_context_fields fields_json =
  let lines =
    match fields_json with
    | `List items ->
        List.filter_map
          (function
            | `Assoc fields -> (
                match
                  (List.assoc_opt "k" fields, List.assoc_opt "v" fields)
                with
                | Some (`String k), Some v ->
                    let k = normalized_surface_context_value k in
                    if k = "" then None
                    else
                      Some
                        (Printf.sprintf "  - %s: %s" k
                           (surface_context_field_value v))
                | _ -> None)
            | _ -> None)
          items
    | `Assoc pairs ->
        List.filter_map
          (fun (k, v) ->
            let k = normalized_surface_context_value k in
            if k = "" then None
            else
              Some
                (Printf.sprintf "  - %s: %s" k (surface_context_field_value v)))
          pairs
    | _ -> []
  in
  if lines = [] then None else Some (String.concat "\n" lines)

(* Single SSOT formatter for dashboard co-view context
   ({label,route,scene,fields}). Shared by the HTTP copilot route
   ([Server_routes_http_keeper_stream]) and the masc_keeper_msg MCP tool path,
   so the two surfaces cannot drift. *)
let surface_context_to_instructions (ctx : Yojson.Safe.t) : string option =
  match ctx with
  | `Assoc fields ->
      let get_string key =
        match List.assoc_opt key fields with
        | Some (`String s) ->
            let s = normalized_surface_context_value s in
            if s = "" then None else Some s
        | _ -> None
      in
      let fields_block =
        match List.assoc_opt "fields" fields with
        | Some fields_json -> surface_context_fields fields_json
        | None -> None
      in
      let lines =
        List.filter_map
          (fun (name, value_opt) ->
            Option.map (fun v -> Printf.sprintf "%s: %s" name v) value_opt)
          [
            ("Surface label", get_string "label");
            ("Route", get_string "route");
            ("Scene", get_string "scene");
          ]
      in
      let lines =
        match fields_block with
        | Some block -> lines @ [ "Fields:"; block ]
        | None -> lines
      in
      if lines = [] then None
      else Some (String.concat "\n" ("[Co-view context]" :: lines))
  | json ->
      Some
        (Printf.sprintf "[Co-view context]\n%s"
           (Yojson.Safe.pretty_to_string json))

module For_testing = struct
  let direct_owner_conversation_context = direct_owner_conversation_context
  let direct_turn_dynamic_context = direct_turn_dynamic_context
  let surface_context_to_instructions = surface_context_to_instructions
  let direct_no_progress_retry_reason =
    Keeper_turn_runtime_budget.direct_no_progress_retry_reason
  let direct_no_progress_retry_decision =
    Keeper_turn_runtime_budget.direct_no_progress_retry_decision
  let run_direct_no_progress_retry_loop =
    Keeper_turn_runtime_budget.run_direct_no_progress_retry_loop
end

let resolve_turn_runtime_id (meta : keeper_meta) =
  let runtime_id = String.trim (Keeper_meta_contract.runtime_id_of_meta meta) in
  if runtime_id = "" then
    Error (Printf.sprintf "invalid runtime_id for keeper %s: empty" meta.name)
  else
    Ok runtime_id

type invocation_surface =
  | Direct_message
  | Keeper_delegate

let invocation_tool_name = function
  | Direct_message -> "masc_keeper_msg"
  | Keeper_delegate -> "masc_keeper_delegate"
;;

let invocation_turn_type = function
  | Direct_message -> "direct"
  | Keeper_delegate -> "delegate"
;;

let turn_resources_error ~surface failure =
  let detail =
    Keeper_publication_recovery_scope.failure_to_string failure
  in
  tool_result_error_data ~class_:Tool_result.Dependency_unavailable
    ~tool_name:(invocation_tool_name surface)
    (`Assoc
       [ "error", `String "keeper_turn_resources_unavailable"
       ; "failure_class", `String "runtime_failure"
       ; "detail", `String detail
       ])
;;

let require_registered_keeper ~base_path ~name ~action =
  if Keeper_registry.is_registered ~base_path name
  then Ok ()
  else
    Error
      (Printf.sprintf
         "keeper %s is not registered in this server process; retry shortly or start it before %s"
         name
         action)
;;

let preflight_keeper_invocation ctx request =
  let name = Keeper_invocation_contract.target_name request in
  match ensure_keeper_exists ~ctx ~name with
  | Error e -> Error e
  | Ok meta ->
    Result.bind
      (require_registered_keeper
         ~base_path:ctx.config.base_path
         ~name
         ~action:"delegating work")
      (fun () ->
         resolve_turn_runtime_id meta
         |> Result.map (fun _ -> request))
;;

(* The message path resolves the keeper one call earlier and carries the
   effective meta here, so this preflight validates without a second disk
   read (RFC-0371 B6). The delegate path below still reads: it has no
   resolution step of its own. *)
let preflight_keeper_msg_resolved ~base_path ~(meta : keeper_meta) message =
  Result.bind
    (require_registered_keeper
       ~base_path
       ~name:meta.name
       ~action:"sending a message")
    (fun () -> resolve_turn_runtime_id meta |> Result.map (fun _ -> message))
;;

let preflight_keeper_delegate ctx request =
  preflight_keeper_invocation ctx request
;;

(* -- Direct-message turn FSM wrapper ---------------------------------------- *)

(** Run a direct [masc_keeper_msg] turn with the same typed FSM transitions
    emitted by the autonomous [Keeper_unified_turn.run_keeper_cycle] path.

    Direct turns historically called [Keeper_agent_run.run_turn] directly,
    which left them invisible to [Keeper_turn_fsm] telemetry and violated
    the SSOT contract audited in
    [docs/audit/2026-06-13-masc-fsm-drift-audit.md] (finding #3).  This
    wrapper emits the canonical start sequence
    [Idle -> Phase_gating -> Runtime_routing -> Awaiting_provider -> Streaming]
    before invoking [f], then records [Failed] or [Cancelled] from the error
    boundary. Successful terminal transitions are owned by the shared
    [Keeper_unified_turn_success] pipeline.

    The wrapper is intentionally thin: it does not duplicate metrics,
    receipt, or meta writes — those remain in
    [run_keeper_invocation_turn_admitted].  It only restores FSM observability so
    direct and autonomous turns share the same state-machine read model. *)
let run_direct_turn_with_fsm ~(keeper_name : string) ~(turn_id : int) f =
  Keeper_turn_fsm.emit_transition
    ~keeper_name
    ~turn_id
    ~prev:Keeper_turn_fsm.Idle
    Keeper_turn_fsm.Phase_gating;
  Keeper_turn_fsm.emit_transition
    ~keeper_name
    ~turn_id
    ~prev:Keeper_turn_fsm.Phase_gating
    Keeper_turn_fsm.Runtime_routing;
  Keeper_turn_fsm.emit_transition
    ~keeper_name
    ~turn_id
    ~prev:Keeper_turn_fsm.Runtime_routing
    Keeper_turn_fsm.Awaiting_provider;
  Keeper_turn_fsm.emit_transition
    ~keeper_name
    ~turn_id
    ~prev:Keeper_turn_fsm.Awaiting_provider
    Keeper_turn_fsm.Streaming;
  try
    let result = f () in
    (match result with
     | Ok _ -> ()
     | Error err ->
       let reason =
         Keeper_turn_fsm.Failure_provider_error
           { kind = Agent_core.Error.(category err |> category_label)
           ; detail = Agent_core.Error.to_string err
           }
       in
       Keeper_turn_fsm.emit_transition
         ~keeper_name
         ~turn_id
         ~prev:Keeper_turn_fsm.Streaming
         (Keeper_turn_fsm.Failed reason));
    result
  with
  | Eio.Cancel.Cancelled _ as e ->
    (* Cooperative cancellation must be preserved and reflected as a
       terminal [Cancelled] state, not swallowed as a successful completion.
       See [KeeperTurnFSM.tla] [HonorStopSignal] and the audit finding #5. *)
    Keeper_turn_fsm.emit_transition
      ~keeper_name
      ~turn_id
      ~prev:Keeper_turn_fsm.Streaming
      (Keeper_turn_fsm.Cancelled Keeper_turn_fsm.Cancelled_supervisor_stop);
    raise e
  | exn ->
    Keeper_turn_fsm.emit_transition
      ~keeper_name
      ~turn_id
      ~prev:Keeper_turn_fsm.Streaming
      (Keeper_turn_fsm.Failed
         (Keeper_turn_fsm.Failure_unexpected_exception
            { exn = Printexc.to_string exn; backtrace = None }));
    raise exn

(* -- handle_keeper_msg: orchestrator ---------------------------------------- *)

(* Body of [handle_keeper_msg], runnable only while holding the keeper's
   Keeper Owner child. Covers [Keeper_agent_run.run_turn]
   AND the post-turn meta/lifecycle writes — both must stay inside the child
   or a concurrent turn can clobber the checkpoint and regress
   [total_turns] (2026-06-10 RCA, RFC-0225 §1).

   Precondition: the caller runs in the Keeper Owner child. Public direct-message
   and typed-delegate entrypoints construct a valid invocation request before
   reaching this function. *)
let run_keeper_invocation_turn_admitted_inner
      ?on_text_delta
      ?on_event
      ?on_tool_stream_observation
      ?on_tool_result_ready
      ?approval_gate
      ?event_bus
      ?continuation_channel
      ~surface
      ~request
      ?direct_message
      ctx
  : tool_result
  =
  with_span
    ~name:"keeper_turn"
    ~attrs:[
      "keeper.name", `String (Keeper_invocation_contract.target_name request);
      "masc.turn_type", `String (invocation_turn_type surface);
    ]
    (fun _trace_id ->
  let on_event =
    match on_event with
    | Some cb -> Some cb
    | None ->
        (match on_text_delta with
         | None -> None
         | Some cb -> Some (fun (evt : Agent_core.Types.sse_event) ->
             match evt with
             | Agent_core.Types.ContentBlockDelta { delta = TextDelta text; _ } -> cb text
             | _ -> ()))
  in
  let name = Keeper_invocation_contract.target_name request in
  let message = Keeper_invocation_contract.prompt request in
  let turn_instructions, direct_reply, channel_session_key, channel, user_blocks =
    match direct_message with
    | None -> None, false, None, "", None
    | Some direct_message ->
      let turn_instructions =
        match
          Keeper_invocation_contract.direct_message_turn_instructions direct_message
        with
        | Some _ as instructions -> instructions
        | None ->
          Option.bind
            (Keeper_invocation_contract.direct_message_surface_context direct_message)
            surface_context_to_instructions
      in
      ( turn_instructions
      , Keeper_invocation_contract.direct_message_direct_reply direct_message
      , Keeper_invocation_contract.direct_message_channel_session_key direct_message
      , Keeper_invocation_contract.direct_message_channel direct_message
      , Keeper_invocation_contract.direct_message_user_agent_core_blocks direct_message )
  in
    match ensure_keeper_exists
      ~ctx ~name
    with
    (* The named keeper does not exist. That is the caller naming something
       absent, not this turn falling over. *)
    | Error e -> tool_result_error ~class_:Tool_result.Workflow_rejection e
    | Ok meta0 ->
      (match
         Keeper_publication_recovery_scope.resolve_turn_resources
           ~provider:ctx.publication_recovery_provider
           ~base_path:ctx.config.base_path
           ~keeper_name:meta0.name
       with
       | Error failure -> turn_resources_error ~surface failure
       | Ok { entry; publication_recovery } ->
      (match
         Keeper_unified_turn_pre_dispatch.turn_profile_and_meta
           ~base_path:ctx.config.base_path
           ~entry_meta:entry.meta
       with
       | Error err ->
         tool_result_error
           ~class_:Tool_result.Runtime_failure
           (Agent_core.Error.to_string err)
       | Ok (profile_defaults, meta) ->
      (* RFC vision-delegation §2.3 site 1 (fresh input). For a keeper whose
         runtime cannot take an image on its own,
         evict each image to the artifact store + an eager analyze_image reading
         BEFORE it enters the turn, so the main history stays text-only and
         RFC-0265 never recomputes required=['image'] from it. A runtime that
         takes the image itself keeps it — seeing the pixels beats a reading. *)
      let user_blocks =
        Option.map
          (Keeper_vision_ingest.evict_blocks
             ~mode:Keeper_vision_ingest.Eager
             ~delegate:
               (Keeper_vision_ingest.delegates_media
                  ~runtime_id:(Keeper_meta_contract.runtime_id_of_meta meta))
             ~keeper_name:meta.name)
          user_blocks
      in
      let turn_task_id = Printf.sprintf "keeper_turn_%s_%d"
        name (int_of_float (Time_compat.now () *. 1000.0)) in
      let keeper_turn_id = meta.runtime.usage.total_turns + 1 in
      (* RFC-0233 §7: mint the turn's join key ONCE from the exact admitted meta —
         the same (trace_id, total_turns + 1) snapshot the Turn_record writer
         stamps (keeper_agent_run.ml:250-251 receives this very meta via the
         run_turn call below). Threaded into reply_json; never re-derived at
         the reply seam from updated_meta, whose trace_id is post-lifecycle and
         is rotated on handoff turns (keeper_rollover) — re-derivation would
         yield a different join key than the Turn_record for the same turn
         (RFC §7.2 mint-once, thread down). *)
      let turn_ref =
        Ids.Turn_ref.make
          ~trace_id:(Keeper_id.Trace_id.to_string meta.runtime.trace_id)
          ~absolute_turn:keeper_turn_id
      in
      let turn_tracker = Progress.start_tracking ~task_id:turn_task_id ~total_steps:5 () in
      Progress.Tracker.step turn_tracker ~message:"Preparing keeper turn configuration" ();
      match resolve_turn_runtime_id meta with
      | Error e ->
        Progress.stop_tracking turn_task_id;
        tool_result_error ~class_:Tool_result.Runtime_failure ("" ^ e)
      | Ok turn_runtime_id ->
      (* start_keepalive is deferred AFTER run_turn completes.
         Starting it here causes the heartbeat fiber to immediately grab LLM
         slots, starving the synchronous run_turn call (Issue #2610). *)
      (* auto execution session interception removed in #2908 *)
      (* === Harness: trajectory accumulator + eval gate config === *)
      let masc_root = Workspace.masc_root_dir ctx.config in
      let trajectory_acc =
        Trajectory.create_accumulator
          ~masc_root
          ~keeper_name:meta.name
          ~trace_id:(Keeper_id.Trace_id.to_string meta.runtime.trace_id)
          ()
      in
      Progress.Tracker.step turn_tracker ~message:"Building turn prompt" ();
      (match
         Keeper_unified_turn_pre_dispatch.build_runtime_execution
           ~meta
           ~runtime_id:turn_runtime_id
       with
	         | Error error ->
	           Progress.stop_tracking turn_task_id;
	           tool_result_error ~class_:Tool_result.Runtime_failure (Agent_core.Error.to_string error)
	         | Ok initial_execution ->
            let base_dir =
              let root = session_base_dir ctx.config in
              match channel_session_key with
              | Some key when direct_reply ->
                let d = Filename.concat (Filename.concat root "channels") key in
                let (_ : string) = Keeper_fs.ensure_dir d in
                d
              | _ -> root
            in
            let live_worktree_change = None in
            (* The direct-message lane used to construct its prompt before it
               read the held task. It still observed the task state later for
               receipt classification, but the model that answered the owner
               could not see its own in-progress work or handoff. Keep this
               as fresh per-turn context, exactly like the unified wake lane;
               it is deliberately not written to conversation history. *)
            let current_task =
              Keeper_world_observation_inputs.read_current_task
                ~config:ctx.config
                ~meta
            in
            let held_task_skills =
              Keeper_world_observation_inputs.read_held_task_skills
                ~config:ctx.config
                ~meta
            in
            let skill_snapshot =
              Keeper_agent_run.capture_skill_snapshot
                ~base_path:ctx.config.base_path
            in
            let task_skill_selection =
              Keeper_task_skill_turn.resolve_observations
                ~snapshot:skill_snapshot ~current_task ~held_task_skills
            in
            let task_skill_surfaces =
              match task_skill_selection with
              | Error _ -> []
              | Ok selection ->
                Keeper_task_skill_turn.exact_task_surfaces
                  ~snapshot:skill_snapshot
                  ~skill_names:profile_defaults.skill_names
                  ~selection
                  ~current_task
                  ~held_task_skills
            in
            (* Direct owner turns need the same fresh Gate authority as
               autonomous turns. Build it before the prompt callback so the
               model-facing projection and the receipt classifier share one
               observation snapshot. *)
            let world_observation =
              direct_turn_observation ~config:ctx.config meta
            in
            let build_turn_prompt ~base_system_prompt ~messages:_
                : Keeper_agent_run.turn_prompt =
              (* === SOFT CONTEXT (injected via extra_system_context) === *)
              (* Durable memory arrives from Memory OS facts recall
                 (keeper_run_tools_hooks.render_if_enabled, default-ON); the
                 legacy memory-bank "Long-term memory:" block is gone
                 (RFC keeper-memory-consolidation Stage 4). *)
              let recent_direct_conversation_text =
                direct_owner_conversation_context
                  ~config:ctx.config ~meta ~direct_reply ~channel_session_key
                  ~channel
              in
              (* 2. Worktree changes *)
              let worktree_text =
                match live_worktree_change with
                | Some summary when String.trim summary <> "" -> summary
                | _ -> ""
              in
              (* 3. Turn instructions *)
              let turn_instructions_text =
                match turn_instructions with
                | None -> ""
                | Some ti ->
                  "--- Turn-specific instructions ---\n" ^ ti
              in
              let telemetry_feedback_text =
                match meta.telemetry_feedback_enabled with
                | Some true ->
                  let window_hours =
                    match meta.telemetry_feedback_window_hours with
                    | Some n when n > 0 -> min n 168
                    | _ -> 24
                  in
                  let window_minutes = window_hours * 60 in
                  (* compute reads JSONL via Eio (Fs_compat.fold_jsonl_lines),
                     a cancellation point, so a bare catch-all here would
                     swallow [Eio.Cancel.Cancelled] and let a cancelled turn
                     keep building its prompt. Route through the RFC-0106 SSOT
                     combinator, which re-raises Cancelled and recovers others
                     (matches the trajectory-finalize handlers below). *)
                  Cancel_safe.protect
                    ~on_exn:(fun exn ->
                      Log.Keeper.warn
                        "%s: telemetry feedback render failed: %s"
                        meta.name (Printexc.to_string exn);
                      "")
                    (fun () ->
                      Model_inference_metrics.compute
                        ~base_path:ctx.config.base_path
                        ~window_minutes
                      |> Model_inference_metrics.render_keeper_prompt_feedback)
                | Some false | None -> ""
              in
              let dynamic_context =
                direct_turn_dynamic_context
                  ~current_task
                  ~held_task_skills
                  ~task_skill_surfaces
                  ~approval_authority_text:
                    (Keeper_unified_prompt.format_approval_authority_observation
                       world_observation.approval_authority)
                  ~recent_direct_conversation_text
                  ~worktree_text
                  ~telemetry_feedback_text
                  ~turn_instructions_text
              in
              (* === HARD CONSTRAINTS (stay in system_prompt) === *)
              (* The model-facing stable contract is shared with autonomous
                 turns. [base_system_prompt] is the checkpoint bootstrap
                 prompt assembled by [Keeper_run_context]; using it here was
                 the last production split between direct and autonomous
                 Keeper behavior. Channel-specific input remains below in
                 [dynamic_context] and the persisted user message. *)
              { system_prompt = base_system_prompt; dynamic_context }
            in
            Progress.Tracker.step turn_tracker
              ~message:(Printf.sprintf "Executing Agent.run for %s" name) ();
            (* RFC-0225 §3.3: per-run carrier for the chat lane. *)
	            let turn_ctx_cell = Keeper_tool_call_log.create_turn_ctx_cell () in
	            let run_result, latency_ms =
	              Inference_utils.timed (fun () ->
	                  match Eio_context.get_clock () with
	                  | Error msg -> Error (Agent_core.Error.Internal msg)
	                  | Ok clock ->
	                  let { Keeper_unified_turn_retry_setup.current_turn_phase_elapsed_ms
	                      ; _
	                      }
	                    =
	                    Keeper_unified_turn_retry_setup.build
	                      ~now:(fun () -> Eio.Time.now clock)
	                  in
	                  let publish_direct_cascade_resolution
	                      ~runtime_id
	                      ~decision
	                      ~reason
	                      ~next_runtime
	                      ~attempt
	                      err =
	                    Keeper_unified_turn_cascade_resolution.publish_cascade_resolution
	                      ~keeper_name:meta.name
	                      ~runtime_id
	                      ~decision
	                      ~reason
	                      ~next_runtime
	                      ~attempt
	                      ~error_kind:
	                        (Some Agent_core.Error.(category err |> category_label))
	                      ~error_message:(Some (Agent_core.Error.to_string err))
	                  in
	                  let setup_direct_retry_runtime runtime_id =
	                    Keeper_unified_turn_pre_dispatch.build_runtime_execution
	                      ~meta
	                      ~runtime_id
	                  in

		                  run_direct_turn_with_fsm
		                    ~keeper_name:meta.name
		                    ~turn_id:keeper_turn_id
		                    (fun () ->
	                       Keeper_turn_runtime_budget.run_direct_no_progress_retry_loop
	                         ~keeper_name:meta.name
	                         ~base_runtime:initial_execution.runtime_id
	                         ~initial_execution
	                         ~current_turn_phase_elapsed_ms
		                         ~now_s:(fun () -> Eio.Time.now clock)
		                         ~setup_retry_runtime:setup_direct_retry_runtime
		                         ~publish_cascade_resolution:
		                           publish_direct_cascade_resolution
		                         ~emit_runtime_selected:
		                           (fun ~runtime_id ~fallback_reason ->
		                              Keeper_metrics.emit_runtime_selected
		                                ~keeper_name:meta.name
		                                ~runtime_id
		                                ~fallback_reason)
		                         ~emit_runtime_rotation:
		                           (fun ~from_runtime ~to_runtime ~reason ->
		                              Keeper_metrics.emit_runtime_rotation
		                                ~keeper_name:meta.name
		                                ~from_runtime
		                                ~to_runtime
		                                ~reason)
		                         ~record_retry_setup_failure:
		                           (fun ~from_runtime ~retry ~rotation_attempt
		                                ~fail_open_err ->
		                              let reason =
		                                Keeper_error_classify
		                                .degraded_retry_reason_to_string
		                                  retry.fallback_reason
		                              in
		                              Log.Keeper.warn
		                                "%s: direct keeper_msg no-progress response \
		                                 from runtime=%s suggested retry to %s \
		                                 (reason=%s), but retry setup failed: %s"
		                                meta.name
		                                from_runtime
		                                retry.next_runtime
		                                reason
		                                (short_preview
		                                   (Agent_core.Error.to_string
		                                      fail_open_err));
		                              Keeper_turn_helpers.record_pre_dispatch_terminal_observation
		                                ~config:ctx.config
		                                ~meta
		                                ~runtime_id:retry.next_runtime
		                                ~outcome:`Error
		                                ~terminal_reason_code:
		                                  (Printf.sprintf
		                                     "direct_retry_setup_%s"
		                                     (Keeper_agent_error
		                                      .terminal_reason_code_of_core_error
		                                        fail_open_err))
		                                ~activity_kind:
		                                  "direct_no_progress_retry_setup"
		                                ~trajectory_outcome:
		                                  (Trajectory.Failed
		                                     (Agent_core.Error.to_string
		                                        fail_open_err))
		                                ~error_kind:
		                                  (Agent_core.Error.(
		                                     category fail_open_err |> category_label)
		                                   |> Keeper_execution_receipt.error_kind_of_string)
		                                ~error_message:
		                                  (Agent_core.Error.to_string fail_open_err)
		                                ~degraded_retry_applied:true
		                                ~degraded_retry_runtime:retry.next_runtime
		                                ~fallback_reason:retry.fallback_reason
		                                ~runtime_rotation_attempts:
		                                  [ rotation_attempt ]
		                                ~keeper_turn_id
		                                ())
		                         ~before_retry:
		                           Keeper_turn_runtime_budget
		                           .yield_before_direct_no_progress_retry
		                         ~run_once:
		                           (fun ~runtime_id ~max_context ~is_retry
		                                ~degraded_retry_runtime ~fallback_reason
		                                ~runtime_rotation_attempts ->
			                              Keeper_agent_run.run_turn
			                                ~config:ctx.config
			                                ~meta
			                                ~publication_recovery
			                                ~profile_defaults
			                                ~turn_ctx_cell
		                                ~base_dir
		                                ~max_context
		                                ~build_turn_prompt
		                                ~user_message:message
		                                ~turn_kind:Turn_record.Direct
		                                ~skill_snapshot
			                                ~task_skill_selection
			                                ?user_blocks
			                                ~runtime_id
			                                ~world_observation
		                                ?on_event
		                                ?on_tool_stream_observation
		                                ?on_tool_result_ready
		                                ?approval_gate
		                                ~trajectory_acc
		                                ?degraded_retry_runtime
		                                ?fallback_reason
                                ~runtime_rotation_attempts
                                ~is_retry
                                ?event_bus
                                ?continuation_channel
                                ())
		                         ()))
		            in
		            match run_result with
            | Error err ->
              let e_str = Agent_core.Error.to_string err in
              let user_message = Keeper_agent_error.user_message_of_core_error err in
              (try
                 let _ = Trajectory.finalize trajectory_acc
                   (Trajectory.Failed e_str) in
                 ()
               with Eio.Cancel.Cancelled _ as e -> raise e | exn -> log_keeper_exn
                 ~label:"trajectory finalize (agent_run error)" exn);
              restart_keepalive_after_message_turn ctx meta;
              Progress.stop_tracking turn_task_id;
              tool_result_error ~class_:Tool_result.Runtime_failure user_message
            | Ok (result, _) ->
              (try
                 let _ = Trajectory.finalize trajectory_acc
                   Trajectory.Completed in
                 ()
               with Eio.Cancel.Cancelled _ as e -> raise e | exn -> log_keeper_exn
                 ~label:"trajectory finalize (agent_run ok)" exn);
              let degraded_retry_applied =
                not (String.equal result.runtime_id initial_execution.runtime_id)
              in
              let degraded_retry_runtime =
                if degraded_retry_applied then Some result.runtime_id else None
              in
              let execution_outcome =
                Keeper_execution_outcome.create
                  ~lane:Keeper_execution_outcome.Direct
                  result
              in
              let updated_meta =
                match
                  Keeper_unified_turn_success.handle
                    ~config:ctx.config
                    ~meta
                    ~turn_ctx_cell
                    ~observation:world_observation
                    ~latency_ms
                    ~degraded_retry_applied
                    ~degraded_retry_runtime
                    ~fallback_reason:None
                    ~keeper_turn_id
                    execution_outcome
                with
                | Keeper_unified_turn_success.Completed updated_meta -> updated_meta
              in
              restart_keepalive_after_message_turn ctx updated_meta;
              Progress.Tracker.complete turn_tracker
                ~message:(Printf.sprintf "Turn completed: %d tool calls" (Keeper_agent_result.tool_call_count result)) ();
              let reply_json =
                let surface_model_used = Keeper_agent_run.runtime_lane_label in
                let u = result.usage in
                let cost_field = match u.cost_usd with
                  | Some c -> `Float c
                  | None -> `Null
                in
                let cache_miss_input_tokens =
                  Keeper_hooks_agent_core.cache_miss_input_tokens
                    ~input_tokens:u.input_tokens
                    ~cache_creation_input_tokens:u.cache_creation_input_tokens
                    ~cache_read_input_tokens:u.cache_read_input_tokens
                in
                let tool_call_evidence =
                  result.tool_calls
                  |> List.filter_map (fun detail ->
                         match detail.Keeper_agent_run.route_evidence with
                         | Some _ ->
                             Some
                               (Keeper_agent_run.tool_call_detail_to_json
                                  detail)
                         | None -> None)
                in
                let terminal_effect_fields =
                  match result.terminal_effect_receipt with
                  | Some (Keeper_tool_execution.Surface_post_completed target) ->
                    [ ( Keeper_surface_post.delivery_target_wire_key
                      , Keeper_surface_post.delivery_target_to_yojson
                          (Keeper_surface_post.delivery_target_of_post_target
                             target) )
                    ]
                  | Some
                      (Keeper_tool_execution.Memory_write_completed { revision }) ->
                    [ Keeper_tool_execution.memory_revision_wire_key
                    , `Int revision
                    ]
                  | None -> []
                in
                `Assoc ([
                  ("reply", `String result.response_text);
                  ( Keeper_turn_outcome.wire_key,
                    `String
                      (Keeper_turn_outcome.to_label
                         result.turn_outcome) );
                  ("model", `String surface_model_used);
                  ("turns", `Int result.turn_count);
                  ( "tool_call_evidence",
                    `List tool_call_evidence );
                  ("usage", `Assoc [
                    ("input_tokens", `Int u.input_tokens);
                    ("output_tokens", `Int u.output_tokens);
                    ("cache_creation_input_tokens", `Int u.cache_creation_input_tokens);
                    ("cache_read_input_tokens", `Int u.cache_read_input_tokens);
                    ("cache_miss_input_tokens", `Int cache_miss_input_tokens);
                    ("cost_usd", cost_field);
                  ]);
                  (* RFC-0233 §7: the turn's join key, minted once from the
                     pre-turn snapshot above. The server persists it on the
                     chat row via append_turn ?turn_ref. *)
                  ( Keeper_turn_outcome.turn_ref_wire_key,
                    Ids.Turn_ref.to_yojson turn_ref );
                ] @ terminal_effect_fields)
              in
              tool_result_ok_data reply_json

))))

(* Turn-observation boundary for the chat lane.

   [mark_turn_started] is the only installer of [current_turn_observation],
   and the composite observer's live-turn projection reads [None] without it.
   Before this wrapper a keeper answering an operator message therefore
   reported no live turn for its whole duration, and the operator queue panel
   rendered "live turn 상세 투영은 아직 없습니다" while the turn was running
   tools. The autonomous lane has carried the same pair since #7122
   ([Keeper_unified_turn.run_keeper_cycle]); this gives the chat lane that
   lifecycle instead of adding a second projection beside it.

   Placed on the admitted body, which is reached only by the Owner operation
   child after its durable Queued-to-Running claim.

   [mark_turn_finished] is idempotent and runs on both the normal and the
   exceptional exit. Its own failure must not replace the turn's result or
   mask an in-flight cancellation, so it is swallowed and logged the way the
   autonomous lane's turn cleanup does. *)
let run_keeper_invocation_turn_admitted
      ?on_text_delta
      ?on_event
      ?on_tool_stream_observation
      ?on_tool_result_ready
      ?approval_gate
      ?event_bus
      ?continuation_channel
      ~surface
      ~request
      ?direct_message
      ctx
  : tool_result
  =
  let base_path = ctx.config.base_path in
  let name = Keeper_invocation_contract.target_name request in
  Keeper_registry.mark_turn_started
    ~base_path
    ~wake:Keeper_registry.Chat_request
    name;
  (* [mark_turn_started] above has no counterpart unless this runs. Since
     #15932 put the turn body inside [turn_sw], a cancelled turn cancels this
     too, and [mark_turn_finished] is a registry file write: an Eio call made
     under a cancelled context raises before writing. Skipping it leaves
     [current_turn_observation] set, so the keeper reads as mid-turn after its
     turn ended, and [last_completed_turn] never freezes.

     The write takes the keeper key lock, which raises [Flock_timeout] rather
     than waiting forever, so [protect] cannot park the caller.

     [Cancelled] is logged like any other failure. Swallowing it silently is
     what let the same shape lose sandbox containers unnoticed (#30590). *)
  let finish () =
    try
      Eio.Cancel.protect (fun () ->
        Keeper_registry.mark_turn_finished ~base_path name)
    with
    | exn ->
      log_keeper_exn ~label:"mark_turn_finished in chat turn cleanup" exn
  in
  match
    run_keeper_invocation_turn_admitted_inner
      ?on_text_delta
      ?on_event
      ?on_tool_stream_observation
      ?on_tool_result_ready
      ?approval_gate
      ?event_bus
      ?continuation_channel
      ~surface
      ~request
      ?direct_message
      ctx
  with
  | result ->
    finish ();
    result
  | exception exn ->
    finish ();
    raise exn
;;

let handle_keeper_msg_admitted
      ~admission_token:_
      ?on_text_delta
      ?on_event
      ?on_tool_stream_observation
      ?on_tool_result_ready
      ?approval_gate
      ?event_bus
      ?continuation_channel
      ctx
      direct_message
  =
  let request =
    Keeper_invocation_contract.direct_message_request direct_message
  in
  run_keeper_invocation_turn_admitted
    ?on_text_delta
    ?on_event
    ?on_tool_stream_observation
    ?on_tool_result_ready
    ?approval_gate
    ?event_bus
    ?continuation_channel
    ~surface:Direct_message
    ~request
    ~direct_message
    ctx
;;
