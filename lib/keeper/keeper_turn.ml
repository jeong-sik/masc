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

type dispatch =
  | Turn_settled of tool_result
  | Turn_failed of
      { result : tool_result
      ; failure : Keeper_request_failure.t
      }

(* The turn answers with a tool result the caller already knows how to carry,
   and — when it failed — with the typed cause beside it. Two constructors
   rather than an optional field: a failed turn always has a cause, and the
   server should not have to invent one for a case the types allow but no
   producer builds. Encoding the cause into [Tool_result.data] and decoding it
   in the server would be a JSON round trip inside one process, and [`Ran]
   drops [data] anyway (RFC-0454 §2.2, last bullet). *)
let dispatch_ok result = Turn_settled result

let dispatch_failed ~class_ ?tool_name cause =
  let failure = { Keeper_request_failure.cause } in
  Turn_failed
    { result =
        tool_result_error ?tool_name ~class_ (Keeper_request_failure.summary failure)
    ; failure
    }
;;

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
      ~(workspace_memory : Workspace_memory_publication.observation)
      ~(lane_updates : (Yojson.Safe.t,string) result)
      ~(approval_authority_text : string)
      ~(recent_direct_conversation_text : string)
      ~(worktree_text : string)
      ~(telemetry_feedback_text : string)
      ~(turn_instructions_text : string)
  : string
  =
  ([ direct_turn_task_context ~current_task ~held_task_skills ~task_skill_surfaces ]
   @ Option.to_list
       (Keeper_unified_prompt.format_workspace_memory_observation workspace_memory)
   @ Option.to_list (Lane_addon_subscription.render lane_updates)
   @ [ approval_authority_text
  ; recent_direct_conversation_text
  ; worktree_text
  ; telemetry_feedback_text
  ; turn_instructions_text
  ])
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

let resolve_turn_runtime_id (meta : keeper_meta) =
  let runtime_id = String.trim (Keeper_meta_contract.runtime_id_of_meta meta) in
  if runtime_id = "" then
    Error (Printf.sprintf "invalid runtime_id for keeper %s: empty" meta.name)
  else
    Ok runtime_id

let resolve_direct_turn_runtime_id ~meta ~resume_lane ~gate_resume =
  match Option.bind gate_resume Keeper_direct_gate_continuation.official_client with
  | Some checkpoint -> Ok checkpoint.runtime_id
  | None -> match resume_lane with
    | None -> resolve_turn_runtime_id meta
    | Some lane -> Ok lane.Keeper_turn_driver.next_runtime_id

module For_testing = struct
  let resolve_direct_turn_runtime_id = resolve_direct_turn_runtime_id
  let direct_owner_conversation_context = direct_owner_conversation_context
  let direct_turn_dynamic_context = direct_turn_dynamic_context
  let surface_context_to_instructions = surface_context_to_instructions
end

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
  (* The payload said "runtime_failure" while the call beside it set
     Dependency_unavailable, so anything reading the payload got the opposite
     answer from anything reading the result. One value now feeds both. *)
  let class_ = Tool_result.Dependency_unavailable in
  let resource =
    match failure with
    | Keeper_publication_recovery_scope.Registry_entry_not_found _ ->
      Keeper_request_failure.Registry_entry_missing
    | Keeper_publication_recovery_scope.Registry_entry_unhealthy _ ->
      Keeper_request_failure.Registry_entry_unhealthy
  in
  Turn_failed
    { result =
        tool_result_error_data
          ~class_
          ~tool_name:(invocation_tool_name surface)
          (`Assoc
             [ "error", `String "keeper_turn_resources_unavailable"
             ; ( "failure_class"
               , `String (Tool_result.tool_failure_class_to_string class_) )
             ; "detail", `String detail
             ])
    ; failure =
        { Keeper_request_failure.cause =
            Keeper_request_failure.Turn_resources_unavailable { resource; detail }
        }
    }
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
    let settlement : Keeper_agent_run.turn_settlement = f () in
    (match settlement.result with
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
    settlement
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
      ~operation_id
      ~(input_speaker : Keeper_input_speaker.t)
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
  : dispatch
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
  (* One admitted operation owns the observation state across all provider
     attempts, including official clients that return no AGENT_CORE checkpoint. *)
  let repetition_execution =
    Keeper_repetition_scope.Execution.direct_operation operation_id
  in
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
    | Error detail ->
      dispatch_failed
        ~class_:Tool_result.Workflow_rejection
        (Keeper_request_failure.Keeper_meta_unresolved { keeper = name; detail })
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
         let { Keeper_request_failure.cause } =
           Keeper_request_failure.of_core_error err
         in
         dispatch_failed ~class_:Tool_result.Runtime_failure cause
       | Ok (profile_defaults, meta) ->
            let base_dir =
              let root = session_base_dir ctx.config in
              match channel_session_key with
              | Some key when direct_reply ->
                let d = Filename.concat (Filename.concat root "channels") key in
                let (_ : string) = Keeper_fs.ensure_dir d in
                d
              | _ -> root
            in
      let session_id = Keeper_id.Trace_id.to_string meta.runtime.trace_id in
      let session_dir = Filename.concat base_dir session_id in
      (match (match Keeper_direct_gate_continuation.load
          ~config:ctx.config ~meta ~operation_id ~session_dir with
        | Error _ as error -> error
        | Ok (Some admission) -> Ok (Some (Keeper_agent_run.Gate_continuation admission))
        | Ok None ->
          (match Keeper_direct_checkpoint_continuation.load
              ~base_path:ctx.config.base_path ~keeper_name:meta.name ~operation_id ~session_dir ~session_id with
           | Error _ as error -> error
           | Ok (Some admission) -> Ok (Some (Keeper_agent_run.Checkpoint_continuation admission))
           | Ok None -> Keeper_direct_runtime_continuation.load
               ~base_path:ctx.config.base_path ~keeper_name:meta.name ~operation_id
               ~session_dir ~session_id
               |> Result.map (Option.map (fun admission -> Keeper_agent_run.Runtime_continuation admission)))) with
       | Error detail ->
         dispatch_failed
           ~class_:Tool_result.Runtime_failure
           (Keeper_request_failure.Turn_continuation_unpersisted
              { stage = Keeper_request_failure.Continuation_load; detail })
       | Ok direct_resume ->
      let deferred_lane = ref None in
      let produced_checkpoint = ref None in
      let gate_ids = ref [] in
      let runtime_resume = match direct_resume with
        | Some (Keeper_agent_run.Runtime_continuation admission) -> Some admission
        | Some (Keeper_agent_run.Checkpoint_continuation _ | Keeper_agent_run.Gate_continuation _) | None -> None in
      let gate_resume = match direct_resume with
        | Some (Keeper_agent_run.Gate_continuation admission) -> Some admission
        | Some (Keeper_agent_run.Checkpoint_continuation _ | Keeper_agent_run.Runtime_continuation _) | None -> None in
      let resume_lane = match runtime_resume, gate_resume with
        | Some admission, _ -> Some (Keeper_direct_runtime_continuation.lane admission)
        | None, Some admission -> Keeper_direct_gate_continuation.runtime_lane admission
        | None, None -> None in
      (* RFC vision-delegation §2.3 site 1 (fresh input). For a keeper whose
         runtime cannot take an image on its own,
         evict each image to the artifact store + an eager analyze_image reading
         BEFORE it enters the turn, so inline pixels never reach the main
         history and RFC-0265 never recomputes required=['image'] from them.
         A Url/File_id reference passes through (#33682): the degrade floor
         strips it from a text-only runtime's dispatch view while the
         reference itself stays requestable. A runtime that
         takes the image itself keeps it — seeing the pixels beats a reading. *)
      let official_checkpoint_resume = Option.bind direct_resume (function
        | Keeper_agent_run.Checkpoint_continuation admission -> Keeper_direct_checkpoint_continuation.official_client admission
        | Keeper_agent_run.Runtime_continuation _ | Keeper_agent_run.Gate_continuation _ -> None) in
      let official_task_reference = Option.bind direct_resume (function
        | Keeper_agent_run.Checkpoint_continuation admission ->
          Option.map (fun original_turn -> Keeper_official_task_reference.create
            ~operation_id ~message ~original_turn)
            (Keeper_direct_checkpoint_continuation.official_client_original_turn admission)
        | Keeper_agent_run.Gate_continuation admission ->
          Option.map (fun original_turn -> Keeper_official_task_reference.create
            ~operation_id ~message ~original_turn)
            (Keeper_direct_gate_continuation.official_client admission)
        | Keeper_agent_run.Runtime_continuation _ -> None) in
      let user_blocks =
        if Option.is_some official_checkpoint_resume then None
        else if Option.is_some direct_resume then user_blocks else
        Option.map
          (Keeper_vision_ingest.evict_blocks
             ~base_path:ctx.config.base_path
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
      let selected_runtime = match official_checkpoint_resume with
        | Some checkpoint -> Ok checkpoint.Keeper_semantic_execution.runtime_id
        | None -> resolve_direct_turn_runtime_id ~meta ~resume_lane ~gate_resume in
      match selected_runtime with
      | Error detail ->
        Progress.stop_tracking turn_task_id;
        dispatch_failed
          ~class_:Tool_result.Runtime_failure
          (Keeper_request_failure.Runtime_selection_failed { detail })
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
	           let { Keeper_request_failure.cause } =
	             Keeper_request_failure.of_core_error error
	           in
	           dispatch_failed ~class_:Tool_result.Runtime_failure cause
	         | Ok initial_execution ->
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
                  ~tool_deny:profile_defaults.tool_deny
                  ~sandbox_profile:meta.sandbox_profile
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
            let lane_updates = Domain_pool_ref.submit_io_or_inline (fun () ->
              Lane_addon_subscription.observe ~config:ctx.config ~keeper_name:meta.name) in
            let workspace_memory = Domain_pool_ref.submit_io_or_inline (fun () ->
              Workspace_memory_publication.observe ~base_path:ctx.config.base_path) in
            (match workspace_memory with
             | Workspace_memory_publication.Unavailable detail ->
               Log.Keeper.warn "workspace memory discovery unavailable keeper=%s: %s" meta.name detail
             | Missing | Available _ -> ());
            let build_turn_prompt ~base_system_prompt:_ ~messages:_
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
                  ~workspace_memory
                  ~lane_updates
                  ~approval_authority_text:
                    (Keeper_unified_prompt.format_approval_authority_observation
                       world_observation.approval_authority)
                  ~recent_direct_conversation_text
                  ~worktree_text
                  ~telemetry_feedback_text
                  ~turn_instructions_text
              in
              (* The system prompt is the base prompt [Keeper_run_context]
                 built, shared with autonomous turns. Channel-specific input
                 stays in [dynamic_context] and the persisted user message. *)
              { dynamic_context; dynamic_context_for_tools = None }
            in
            Progress.Tracker.step turn_tracker
              ~message:(Printf.sprintf "Executing Agent.run for %s" name) ();
            (* RFC-0225 §3.3: per-run carrier for the chat lane. *)
	            let turn_ctx_cell = Keeper_tool_call_log.create_turn_ctx_cell () in
	            let settlement, latency_ms =
	              Inference_utils.timed (fun () ->
                      let consume = match direct_resume with
                        | None | Some (Keeper_agent_run.Gate_continuation _) -> Ok ()
                        | Some (Keeper_agent_run.Checkpoint_continuation admission) ->
                          Keeper_direct_checkpoint_continuation.consume
                            ~base_path:ctx.config.base_path ~keeper_name:meta.name ~operation_id admission
                        | Some (Keeper_agent_run.Runtime_continuation admission) -> Keeper_direct_runtime_continuation.consume
                            ~base_path:ctx.config.base_path ~keeper_name:meta.name
                            ~operation_id admission in
                      match consume with
                      | Error detail ->
                        Keeper_agent_run.not_dispatched (Agent_core.Error.Internal detail)
                      | Ok () ->
                  run_direct_turn_with_fsm
                    ~keeper_name:meta.name
                    ~turn_id:keeper_turn_id
                    (fun () ->
                      Keeper_agent_run.run_turn
                                      ?direct_resume
                                      ?official_task_reference
                                      ?hitl_resolution:(Option.map Keeper_direct_gate_continuation.resolution gate_resume)
                                      ~on_gate_deferred:(fun approval_id -> gate_ids := approval_id :: !gate_ids)
                                      ?on_gate_evidence_admitted:(Option.map (fun admission checkpoint ->
                                        Keeper_direct_gate_continuation.discharge ~config:ctx.config
                                          ~keeper_name:meta.name ~operation_id ~user_message:message
                                          ~checkpoint admission)
                                        (Option.bind gate_resume (fun admission ->
                                          Option.map (fun _ -> admission) (Keeper_direct_gate_continuation.checkpoint admission))))
                                      ?deferred_runtime_lane:resume_lane
                                      ~runtime_retry_deferral:
                                        { Keeper_turn_driver.continuation =
                                            Keeper_turn_driver.Resume_operation_checkpoint
                                              { operation_id }
                                        ; on_deferred = (fun lane -> deferred_lane := Some lane)
                                        }
                                      ~on_produced_checkpoint:(fun ~runtime_id ~attempt checkpoint ->
                                        let captured =
                                          Keeper_checkpoint_store.exact_snapshot_of_value
                                            ~expected_session_id:meta.runtime.trace_id checkpoint
                                          |> Result.map_error (fun _ -> "producer checkpoint capture failed") in
                                        produced_checkpoint := Some (runtime_id,attempt,captured))
			                                ~config:ctx.config
			                                ~meta
			                                ~publication_recovery
			                                ~profile_defaults
			                                ~turn_ctx_cell
		                                ~base_dir
		                                ~max_context:initial_execution.max_context
		                                ~build_turn_prompt
		                                ~user_message:(match official_checkpoint_resume with
                                      | Some _ -> Keeper_direct_checkpoint_continuation.official_resume_message ~operation_id
                                      | None -> message)
		                                ~input_speaker:(match official_checkpoint_resume with
                                      | Some _ ->
                                        Keeper_input_speaker.Host_prompt
                                          Keeper_input_speaker.Official_client_resume
                                      | None -> input_speaker)
		                                ~turn_kind:Turn_record.Direct
                                ~repetition_execution
		                                ~skill_snapshot
			                                ~task_skill_selection
			                                ?user_blocks
			                                ~runtime_id:initial_execution.runtime_id
			                                ~world_observation
		                                ?on_event
		                                ?on_tool_stream_observation
		                                ?on_tool_result_ready
		                                ?approval_gate
		                                ~trajectory_acc
                                ?event_bus
                                ?continuation_channel
                                ()))
		            in
                let run_result = settlement.Keeper_agent_run.result in
                let run_result = match gate_resume with
                  | None -> run_result
                  | Some admission ->
                    Keeper_direct_gate_continuation.finish_run ~config:ctx.config
                      ~keeper_name:meta.name ~operation_id admission run_result in
                (* A Gate whose original session is full cannot continue
                   anywhere: suspending it again would resume into the same
                   refusal. The operation fails with that typed cause, and the
                   session record lets the next ordinary turn start fresh. *)
                let gate_session_full = match gate_resume, run_result with
                  | Some admission, Error _ ->
                    Keeper_direct_gate_continuation.session_full ~config:ctx.config
                      ~keeper_name:meta.name admission
                  | Some _, Ok _ | None, (Ok _ | Error _) -> Ok None in
                match gate_session_full with
                | Error detail ->
                  Progress.stop_tracking turn_task_id;
                  dispatch_failed
                    ~class_:Tool_result.Runtime_failure
                    (Keeper_request_failure.Turn_continuation_unpersisted
                       { stage = Keeper_request_failure.Gate_suspend; detail })
                | Ok (Some cause) ->
                  let summary = Keeper_request_failure.summary { Keeper_request_failure.cause } in
                  Log.Keeper.warn "direct Gate continuation ended: %s" summary;
                  (try
                     let _ = Trajectory.finalize trajectory_acc
                       (Trajectory.Failed summary) in
                     ()
                   with Eio.Cancel.Cancelled _ as e -> raise e | exn -> log_keeper_exn
                     ~label:"trajectory finalize (gate session full)" exn);
                  restart_keepalive_after_message_turn ctx meta;
                  Progress.stop_tracking turn_task_id;
                  dispatch_failed ~class_:Tool_result.Runtime_failure cause
                | Ok None ->
                let source = match run_result with
                  | Ok {Keeper_agent_run.checkpoint=Some checkpoint; _} ->
                    Ok (Keeper_direct_gate_continuation.Returned_agent_core checkpoint)
                  | Ok {Keeper_agent_run.checkpoint=None; official_client_settlement=Some settled_session; _} ->
                    (match Keeper_repetition_scope.Execution.snapshot repetition_execution with
                     | Ok frame -> Ok (Keeper_direct_gate_continuation.Returned_official_client {settled_session;frame})
                     | Error error -> Error (Keeper_repetition_snapshot.error_to_string error))
                  | Ok {Keeper_agent_run.checkpoint=None; official_client_settlement=None; _} ->
                    Error "official-client producer omitted its settled continuation receipt"
                  | Error _ ->
                    (match !produced_checkpoint with
                     | Some (_runtime_id,_attempt,Ok snapshot) -> Ok (Keeper_direct_gate_continuation.Captured_agent_core snapshot)
                     | Some (_runtime_id,_attempt,Error detail) -> Error detail
                     | None -> Error "failed Gate producer has no attempt-owned checkpoint receipt") in
                let gate_wait = Keeper_direct_gate_continuation.suspend
                      ~source
                      ?runtime_lane:!deferred_lane
                      ~config:ctx.config ~keeper_name:meta.name ~operation_id
                      ~session_dir ~session_id ~approval_ids:!gate_ids () in
                match gate_wait with
                | Error detail ->
                  dispatch_failed
                    ~class_:Tool_result.Runtime_failure
                    (Keeper_request_failure.Turn_continuation_unpersisted
                       { stage = Keeper_request_failure.Gate_suspend; detail })
                | Ok true ->
                  let () = match Keeper_direct_gate_continuation.reconcile ~config:ctx.config ~meta with
                    | Ok () -> ()
                    | Error detail -> Log.Keeper.warn "direct Gate reconciliation: %s" detail in
                  restart_keepalive_after_message_turn ctx meta;
                  Progress.stop_tracking turn_task_id;
                  dispatch_ok
                  @@ Tool_result.make_deferred ~tool_name:"masc_keeper_msg"
                    ~start_time:(Time_compat.now ())
                    ~data:(`Assoc ["reply", `String "";
                      Keeper_turn_outcome.wire_key, `String (Keeper_turn_outcome.to_label Keeper_turn_outcome.Continuation_checkpoint);
                      Keeper_turn_outcome.turn_ref_wire_key, Ids.Turn_ref.to_yojson turn_ref;
                      "tool_call_evidence", `List []]) ()
                | Ok false ->
		            match run_result with
            | Error _ when Option.is_some !deferred_lane ->
              let deferred = match !deferred_lane with
                | None -> Error "direct runtime continuation was not captured"
                | Some lane -> Keeper_direct_runtime_continuation.defer
                    ~base_path:ctx.config.base_path ~keeper_name:meta.name ~operation_id
                    ~session_dir ~session_id lane in
              Progress.stop_tracking turn_task_id;
              (match deferred with
               | Error detail ->
                 dispatch_failed
                   ~class_:Tool_result.Runtime_failure
                   (Keeper_request_failure.Turn_continuation_unpersisted
                      { stage = Keeper_request_failure.Runtime_continuation_defer; detail })
               | Ok () ->
                 dispatch_ok
                 @@ Tool_result.make_deferred ~tool_name:"masc_keeper_msg"
                   ~start_time:(Time_compat.now ())
                   ~data:(`Assoc [
                     "reply", `String "";
                     Keeper_turn_outcome.wire_key,
                       `String (Keeper_turn_outcome.to_label Keeper_turn_outcome.Continuation_checkpoint);
                     Keeper_turn_outcome.turn_ref_wire_key, Ids.Turn_ref.to_yojson turn_ref;
                     "tool_call_evidence", `List []]) ())
            | Error err ->
              let e_str = Agent_core.Error.to_string err in
              let { Keeper_request_failure.cause } =
                Keeper_request_failure.of_core_error err
              in
              (try
                 let _ = Trajectory.finalize trajectory_acc
                   (Trajectory.Failed e_str) in
                 ()
               with Eio.Cancel.Cancelled _ as e -> raise e | exn -> log_keeper_exn
                 ~label:"trajectory finalize (agent_run error)" exn);
              restart_keepalive_after_message_turn ctx meta;
              Progress.stop_tracking turn_task_id;
              dispatch_failed ~class_:Tool_result.Runtime_failure cause
            | Ok result ->
              (try
                 let _ = Trajectory.finalize trajectory_acc
                   Trajectory.Completed in
                 ()
               with Eio.Cancel.Cancelled _ as e -> raise e | exn -> log_keeper_exn
                 ~label:"trajectory finalize (agent_run ok)" exn);
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
                    (* The turn's own verdict, as the receipt recorded it. This
                       used to be [result.runtime_id <> initial_execution.runtime_id]
                       -- the lane walk moving, which [runtime_fallback_applied]
                       already reports -- and it read true on 16 of 33 measured
                       turns that ran one candidate and failed over to none
                       (#37376). *)
                    ~degraded_retry_applied:settlement.Keeper_agent_run.degraded_retry_applied
                    ~degraded_retry_deferred:settlement.Keeper_agent_run.degraded_retry_deferred
                    ~keeper_turn_id
                    execution_outcome
                with
                | Keeper_unified_turn_success.Completed updated_meta -> updated_meta
              in
              let checkpoint_yield = Keeper_turn_outcome.equal result.turn_outcome
                  Keeper_turn_outcome.Continuation_checkpoint in
              let retained = if checkpoint_yield then
                  match result.checkpoint with
                  | Some checkpoint -> Keeper_direct_checkpoint_continuation.defer
                      ~base_path:ctx.config.base_path ~keeper_name:meta.name ~operation_id
                      ~session_dir ~session_id ~checkpoint
                  | None ->
                    (match result.official_client_settlement with
                     | None -> Error "cooperative turn omitted its producer-owned continuation authority"
                     | Some settled_session ->
                       (match Keeper_repetition_scope.Execution.snapshot repetition_execution with
                        | Error error -> Error (Keeper_repetition_snapshot.error_to_string error)
                        | Ok frame -> Keeper_direct_checkpoint_continuation.defer_official
                            ~base_path:ctx.config.base_path ~keeper_name:meta.name ~operation_id
                            ~settled_session ~frame))
                else Ok () in
              (match retained with
               | Error detail ->
                 dispatch_failed
                   ~class_:Tool_result.Runtime_failure
                   (Keeper_request_failure.Turn_continuation_unpersisted
                      { stage = Keeper_request_failure.Checkpoint_retain; detail })
               | Ok () ->
              restart_keepalive_after_message_turn ctx updated_meta;
              Progress.Tracker.complete turn_tracker
                ~message:(Printf.sprintf "Turn completed: %d tool calls" (Keeper_agent_result.tool_call_count result)) ();
              let reply_json =
                let surface_model_used = Keeper_agent_run.runtime_lane_label in
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
                  ( "usage"
                  , Option.fold
                      ~none:`Null
                      ~some:Keeper_usage_resolution.to_json
                      updated_meta.runtime.last_usage_resolution );
                  (* RFC-0233 §7: the turn's join key, minted once from the
                     pre-turn snapshot above. The server persists it on the
                     chat row via append_turn ?turn_ref. *)
                  ( Keeper_turn_outcome.turn_ref_wire_key,
                    Ids.Turn_ref.to_yojson turn_ref );
                ] @ terminal_effect_fields)
              in
              dispatch_ok
                (if checkpoint_yield then
                   Tool_result.make_deferred ~tool_name:"masc_keeper_msg"
                     ~start_time:(Time_compat.now ()) ~data:reply_json ()
                 else tool_result_ok_data reply_json))

)))))

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
      ~operation_id
      ~input_speaker
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
  : dispatch
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
    | exn -> (* cancel-guard-ok: the body is Eio.Cancel.protect, so the ambient cancellation cannot fire inside it. *)
      log_keeper_exn ~label:"mark_turn_finished in chat turn cleanup" exn
  in
  match
    run_keeper_invocation_turn_admitted_inner
      ~operation_id
      ~input_speaker
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
      ~operation_id
      ~admission_token:_
      ~input_speaker
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
    ~operation_id
    ~input_speaker
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
