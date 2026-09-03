(* keeper_run_tools_setup — extracted from keeper_run_tools.ml.
   Contains the full implementation of prepare_agent_setup. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_agent_tool_surface
open Keeper_agent_result
open Keeper_agent_error
open Keeper_agent_prompt_metrics

(* [config/prompts/judge.effect.md] hands the judge this bundle as its
   entire visible evidence, and [keeper_gate_causal_context.mli] declares that
   evidence to be turn-local. The capture did not match. Measured on live
   pending approvals 2026-07-28: [history_messages] was 1,278,158 B of a
   1,300,053 B bundle (98%), and 88.7% of that was three read-only polls
   replayed in full - masc_status x308, masc_board_list x200,
   keeper_tasks_list x380. Every request raised inside a turn therefore
   exceeded the judge model's prompt limit and was quarantined (#26081).

   Recent lead-up is real evidence, so the newest messages are kept within a
   declared budget rather than dropped wholesale. The budget is set against
   measured behaviour of the judge slot (glm-coding.glm-5-turbo): a 400 KB
   prompt was accepted, an 800 KB prompt was refused with
   {"code":"1261","message":"Prompt exceeds max length"}, and 300 KB of
   poorly-tokenising content was refused. 64 KB of history on top of the
   ~41 KB remainder of the bundle stays well below the nearest refusal.

   2026-08-09: that "~41 KB remainder" was [completed_tool_calls], which this
   fix never bounded, and it grew to 791,432 B of an 860,589 B bundle. The
   judge slot refused it with the same code 1261 quoted above and 45 of 52
   hitl_auto_judge runs failed. The budget now lives in
   [Keeper_gate_causal_context] and both axes read it, so the premise this
   comment rests on cannot decay on one axis while the other holds. *)
let gate_history_budget_bytes = Keeper_gate_causal_context.evidence_budget_bytes

let record_lane_attempt_index receipt_lane_attempt_index_ref lane_attempt_index =
  receipt_lane_attempt_index_ref :=
    max !receipt_lane_attempt_index_ref lane_attempt_index
;;

let tool_use_ids_of_message (message : Agent_core.Types.message) =
  List.filter_map
    (fun (block : Agent_core.Types.content_block) ->
       match block with
       | Agent_core.Types.ToolUse { id; _ } -> Some id
       | _ -> None)
    message.content
;;

let tool_result_ids_of_message (message : Agent_core.Types.message) =
  List.filter_map
    (fun (block : Agent_core.Types.content_block) ->
       match block with
       | Agent_core.Types.ToolResult { tool_use_id; _ } -> Some tool_use_id
       | _ -> None)
    message.content
;;

(* Returns the newest messages that fit the budget, plus how many were left
   out. The count is carried into the bundle: a judge that cannot tell it was
   handed a partial view weighs partial evidence as if it were complete, and
   the prompt already asks it to name absent context in its rationale. *)
let gate_history_slice (messages : Agent_core.Types.message list) =
  let sized =
    List.map
      (fun message ->
         let json = Keeper_context_core.message_to_json message in
         message, json, String.length (Yojson.Safe.to_string json))
      messages
  in
  let rec newest_within budget kept = function
    | [] -> kept
    | (message, json, size) :: older ->
      if size > budget then kept else newest_within (budget - size) ((message, json) :: kept) older
  in
  let kept = newest_within gate_history_budget_bytes [] (List.rev sized) in
  (* A tool result whose call fell outside the window reads as evidence of
     something the judge never sees happen. Drop those rather than present a
     dangling half of a pair. *)
  let visible_calls = List.concat_map (fun (message, _) -> tool_use_ids_of_message message) kept in
  let kept =
    List.filter
      (fun (message, _) ->
         tool_result_ids_of_message message
         |> List.for_all (fun id -> List.mem id visible_calls))
      kept
  in
  List.map snd kept, List.length messages - List.length kept
;;

let gate_causal_initial
      ~gate_history
      ~gate_history_omitted
      ~user_message
      ~dynamic_context
  =
  `Assoc
    [ "history_messages", `List gate_history
    ; "history_messages_omitted", `Int gate_history_omitted
    ; "user_message", `String user_message
    ; "dynamic_context", `String dynamic_context
    ]
;;

let expected_model_tool_names
      ?(deferred_names = [])
      ~skill_catalog
      ~identity_names
      ~model_visible_descriptors
      ()
  =
  (* [deferred_names] are the built-ins this surface actually holds behind the
     listing. Empty for the surface that carries every tool as a schema, and
     for every caller that predates the axis.

     "Actually" is the load-bearing word. A tool declaring
     [defer_loading = true] is not enough: a tool this conversation has run is
     placed with its schema again, so a declared tool the Keeper uses is on the
     surface after all. Reading the declaration instead cost 60
     [keeper_model_tool_projection_mismatch] errors in an hour on 2026-08-31,
     all on [keeper_ide_annotate] -- declared deferrable, called once the day
     before, and legitimately present ever since.

     Subtracted rather than the check being widened: a tool leaving the request
     is the thing this whole change does, so an invariant that stopped noticing
     it would stop being an invariant. What it still catches is a tool that
     left for any other reason. *)
  let is_deferred name = List.exists (String.equal name) deferred_names in
  let descriptor_names =
    model_visible_descriptors
    |> List.concat_map Keeper_tool_descriptor.keeper_model_names
  in
  let entries = Keeper_skill_catalog.composition_entries skill_catalog in
  let composition_names =
    List.map Keeper_tool_composition_catalog.tool_name entries
  in
  let instruction_names =
    if Keeper_skill_catalog.instruction_entries skill_catalog <> []
    then [ Keeper_tool_composition_catalog.skill_tool_name ]
    else []
  in
  (* The shared controls are always present because a Skill-declared
     composition may select async execution. *)
  let control_names =
    [ Keeper_tool_composition_catalog.status_tool_name
    ; Keeper_tool_composition_catalog.cancel_tool_name
    ]
  in
  List.sort_uniq
    String.compare
    (List.filter
       (fun name -> not (is_deferred name))
       (descriptor_names @ composition_names @ instruction_names @ control_names)
         (* What the work services this Keeper is attached to offer, as this
            surface names them: the official-client lanes carry the tools
            themselves, the Agent Core lane carries the one listing tool that
            hands them over on request. Named by the caller from the same
            list the bundle was handed, so the projection check keeps meaning
            "the surface is what it was built from" rather than being widened
            into always passing. *)
         @ identity_names)
;;

(* One question, asked from both sides: of the names this surface was built to
   treat specially, which ones did the turn actually place?

   Both callers face the same trap. The Agent Core lane always carries the
   attached-tool listing and may also carry attached schemas its conversation
   used on an earlier turn; and a built-in that declares [defer_loading = true]
   is placed with its schema again once this conversation has run it. So
   neither "attached" nor "declared deferrable" predicts presence, and a check
   built on the declaration expects a tool that is legitimately there.

   Reading the declaration instead of the surface cost 60
   [keeper_model_tool_projection_mismatch] errors in an hour on 2026-08-31, all
   on [keeper_ide_annotate]: declared deferrable, called once the day before,
   and carried ever since.

   An unknown actual name stays outside either answer, so the projection check
   still reports it. *)
let partition_by_presence ~names ~actual_names =
  List.partition (fun name -> List.mem name actual_names) names
;;

(* Present: the listing plus whatever attached schemas were carried in. The
   listing is expected even when it is accidentally absent from the actual
   surface, which is the one thing the check must still catch.

   [listed] is whether the turn placed a listing at all, reported by the bundle
   that placed it. It is not the same question as "is anything attached": since
   built-ins declare their own loading, a Keeper with no attached service still
   gets a listing when one of its built-ins declares [defer_loading = true].
   Deriving it from [attached_names] left code-reviewer -- no attachment, one
   declared built-in -- reporting keeper_tool_search as a tool the projection
   did not expect.

   Deriving it from the actual surface instead would be worse than either: the
   check would expect the listing exactly when the listing is there, which is
   the same as not checking. A listing that went missing is the one thing this
   must still catch. *)
let agent_core_identity_names ~listed ~attached_names ~actual_names =
  if not listed
  then []
  else (
    let present, (_ : string list) =
      partition_by_presence ~names:attached_names ~actual_names
    in
    Keeper_identity_tool_search.tool_name :: present |> List.sort_uniq String.compare)
;;

(* Absent: the declared built-ins this surface really did leave out. *)
let deferred_names_absent_from ~declared_names ~actual_names =
  let (_ : string list), absent =
    partition_by_presence ~names:declared_names ~actual_names
  in
  absent
;;

let prepare_agent_setup
      ~(config : Workspace.config)
      ~(meta : Keeper_meta_contract.keeper_meta)
      ~(profile_defaults : Keeper_types_profile.keeper_profile_defaults)
      ~(publication_recovery :
          Keeper_publication_recovery_availability.turn_context)
      ~(turn_ctx_cell : Keeper_tool_call_log.turn_ctx_cell)
      ~(ctx_work : working_context)
      ~(session : Keeper_types.session_context)
      ~(base_system_prompt : string)
      ~(turn_system_prompt : string)
      ~(user_message : string)
      ~(dynamic_context : string)
      ~(history_messages : Agent_core.Types.message list)
      ~(shared_context : Agent_core.Context.t)
      ~(context_injector : Agent_core.Hooks.context_injector)
      ~(start_turn_count : int)
      ~(keeper_turn_id : int)
      ~(turn_kind : Turn_record.turn_kind)
      ~(runtime_id : string)
      ~(is_retry : bool)
      ~(config_root : string)
      ~(runtime_config_path : string option)
      ~(skill_snapshot : Skill_catalog_snapshot.t)
      ~(skill_names : string list option)
      ~(task_skill_selection :
          (Keeper_task_skill_turn.t, Keeper_task_skill_turn.error) result)
      ~(trajectory_acc : Trajectory.accumulator option)
      ?runtime_manifest_context
      ?runtime_manifest_append
      ?continuation_channel
      ?on_tool_stream_observation
      ?on_tool_result_ready
      ?hitl_resolution
      ?composition_plan_index
      ()
  : (Keeper_run_tools_hooks.agent_setup, Agent_core.Error.t) result
  =
  let ( let* ) = Result.bind in
  let runtime_id_string = runtime_id in
  let active_checkpoint_owner = ref None in
  let active_runtime_id = Atomic.make None in
  let receipt_lane_attempt_index_ref : int ref = ref 0 in
  let tool_result_commit_required () =
    match on_tool_result_ready, !active_checkpoint_owner with
    | None, _ -> false
    | Some _, Some Runtime_execution.Official_client -> false
    | Some _, (Some Runtime_execution.Masc_agent_core | None) -> true
  in
  let on_runtime_attempt
        (attempt : Keeper_turn_driver.runtime_attempt)
    =
    active_checkpoint_owner := Some attempt.checkpoint_owner;
    Atomic.set active_runtime_id (Some attempt.runtime_id);
    record_lane_attempt_index
      receipt_lane_attempt_index_ref
      attempt.lane_attempt_index;
    Option.iter
      (fun observe ->
         observe
           (Keeper_hooks_agent_core.Runtime_attempt_started
              { runtime_id = attempt.runtime_id
              ; lane_attempt_index = attempt.lane_attempt_index
              ; checkpoint_owner = attempt.checkpoint_owner
              }))
      on_tool_stream_observation
  in
  let on_tool_result_ready =
    Option.map
      (fun notify ~tool_call_id ~turn ~planned_index ~execution_id ->
         match !active_checkpoint_owner with
         | Some Runtime_execution.Masc_agent_core ->
           notify ~tool_call_id ~turn ~planned_index ~execution_id
         | Some Runtime_execution.Official_client ->
           (* Official clients execute dynamic tools without an Agent Core
              pre-admission source sidecar. Keep those persisted chat rows
              delivery-only. The owner comes from the exact resolved candidate
              attempt, including heterogeneous lane fallbacks. *)
           ()
         | None ->
           failwith
             "tool result arrived before the resolved runtime attempt owner was observed")
      on_tool_result_ready
  in
  let* task_skill_selection =
    Result.map_error Keeper_task_skill_turn.core_error task_skill_selection
  in
  let ctx_snapshot = ctx_work in
  let gate_history, gate_history_omitted = gate_history_slice history_messages in
  let gate_context =
    Keeper_gate_causal_context.create
      ~turn_id:(Some keeper_turn_id)
      ~initial:
        (gate_causal_initial
           ~gate_history
           ~gate_history_omitted
           ~user_message
           ~dynamic_context)
  in
  let agent_name = meta.name in
  let global_skill_catalog, skill_projection_diagnostics =
    Keeper_skill_catalog.of_snapshot skill_snapshot
  in
  List.iter
    (fun (diagnostic : Keeper_skill_catalog.projection_diagnostic) ->
       Log.Keeper.warn
         "Skill projection diagnostic for keeper=%s identity=%s error=%s"
         meta.name
         (Yojson.Safe.to_string
            (Skill_catalog_snapshot.identity_to_yojson diagnostic.identity))
         (Keeper_skill_catalog.error_to_string diagnostic.error))
    skill_projection_diagnostics;
  List.iter
    (fun (selected : Keeper_task_skill_turn.selected) ->
       Option.iter
         (fun diagnostic ->
            Log.Keeper.warn
              "Task Skill frozen as instruction for keeper=%s reference=%s error=%s"
              meta.name
              (Skill_reference.to_yojson selected.reference |> Yojson.Safe.to_string)
              (Keeper_skill_catalog.error_to_string diagnostic))
         selected.diagnostic)
    task_skill_selection.selected;
  let capability_surface =
    Keeper_capability_surface.create
      ~skill_names
      ~global_skill_catalog
      ~skill_inventory:(Keeper_skill_inventory.of_snapshot skill_snapshot)
      ~task_skills:(Keeper_task_skill_turn.skills task_skill_selection)
  in
  let turn_skill_projection =
    Keeper_capability_surface.skill_projection capability_surface
  in
  let skill_catalog = Keeper_capability_surface.skill_catalog capability_surface in
  List.iter
    (fun unavailable ->
       Log.Keeper.warn
         "Task Skill unavailable for keeper=%s error=%s"
         meta.name
         (Keeper_skill_catalog.turn_unavailable_to_string unavailable))
    turn_skill_projection.unavailable;
  let executable_task_skill_selection =
    Keeper_task_skill_turn.executable_selection
      ~projection:turn_skill_projection
      task_skill_selection
  in
  let* skill_activation_context =
    Keeper_skill_activation_recorder.make
      ~trace_id:meta.runtime.trace_id
      ~runtime_id:(fun () -> Atomic.get active_runtime_id)
      ~turn_ref:
        (Ids.Turn_ref.make
           ~trace_id:(Keeper_id.Trace_id.to_string meta.runtime.trace_id)
           ~absolute_turn:keeper_turn_id)
      ~snapshot_revision:(Skill_catalog_snapshot.snapshot_revision skill_snapshot)
      ~task_selection:executable_task_skill_selection
    |> Result.map_error (fun error ->
         Agent_core.Error.Internal
           (Keeper_skill_activation_recorder.error_to_string error))
  in
  let acc : Keeper_run_tools_hook_accumulator.hook_accumulator =
    { meta
    ; tool_calls = []
    ; current_turn = 0
    ; tool_surface =
        { turn_lane = Keeper_agent_tool_surface.Lane_text_only
        ; config_root
        ; runtime_config_path
        }
    ; requested_tool_names = []
    ; receipt_completion_contract_result =
        Keeper_execution_receipt.Completion_observation_unknown
    ; receipt_actionable_signal = None
    ; prompt_blocks = []
    ; extra_system_context_digest = None
    ; extra_system_context_size = None
    ; assistant_turn_texts = []
    }
  in
  (* The agent this turn will run, made here because the tools are made here
     and one of them widens the callable set while the turn is running. It is
     the AGENT_CORE call site that fills it, at agent creation. *)
  let agent_cell : Agent_core.Agent.t option ref = ref None in
  (* What this Keeper is attached to. A disk read of what was written down
     when it attached, not a call to the provider: a turn that had to reach
     Atlassian before it could start would fail whenever Atlassian was slow,
     for a question whose answer changes about never. *)
  let identity_offering =
    Keeper_identity_tools.for_turn
      ~base_path:config.Workspace.base_path
      ~keeper_name:meta.name
  in
  List.iter
    (fun (name, problem) ->
      Log.Keeper.emit
        Log.Warn
        ~keeper_name:meta.name
        ~category:Log.Tool
        ~details:
          (`Assoc
             [ "error_kind", `String "keeper_identity_tool_unusable"
             ; "tool", `String name
             ; "problem", `String problem
             ])
        "An attached service names a tool this turn cannot offer")
    identity_offering.Keeper_identity_tools.unusable;
  (* RFC-0403: the profile's own selection over what the services offered.
     Absent selection keeps the whole offering, so a keeper that declares
     nothing sends the same bytes it sent before this existed. *)
  let identity_allow =
    Keeper_identity_tool_allow.apply
      ~allow:profile_defaults.Keeper_types_profile.attached_tool_allow
      identity_offering.Keeper_identity_tools.offered
  in
  List.iter
    (fun name ->
      Log.Keeper.emit
        Log.Warn
        ~keeper_name:meta.name
        ~category:Log.Tool
        ~details:
          (`Assoc
             [ "error_kind", `String "keeper_attached_tool_allow_unnamed"
             ; "tool", `String name
             ])
        "The profile allows an attached tool no attached service offers")
    identity_allow.Keeper_identity_tool_allow.unnamed;
  let turn_model_visible_descriptors =
    Keeper_capability_surface.descriptors capability_surface
  in
  let
    { Keeper_tools_agent_core.tools = keeper_tools
    ; agent_core_tools = keeper_agent_core_tools
    ; listing = keeper_listing
    ; cleanup = keeper_tools_cleanup
    ; terminal_effect_state
    ; gate_replay_delivery
    }
    =
    Keeper_tools_agent_core_bundle.make_tool_bundle_for_capability_surface
      ~config
      ~meta
      ~publication_recovery
      ~ctx_snapshot
      ~capability_surface
      ?continuation_channel
      ~gate_context
      ?hitl_resolution
      ~identity_surface:
        { Keeper_tools_agent_core.offered =
            identity_allow.Keeper_identity_tool_allow.kept
        ; agent_cell
        ; history = history_messages
        }
      ?composition_plan_index
      ~skill_activation_context
      ~turn_ctx_cell
      ~checkpoint_owner:(fun () -> !active_checkpoint_owner)
      ()
  in
  let replay_delivery =
    Option.map
      (fun { Keeper_tools_agent_core.approval_id; outcome } ->
         approval_id, outcome)
      gate_replay_delivery
  in
  let* () =
    match replay_delivery with
    | Some
        ( approval_id
        , Keeper_gate_replay.Repair_required
            { operation; stage; detail } ) ->
      (try keeper_tools_cleanup () with
       | Eio.Cancel.Cancelled _ as exn -> raise exn
       | exn ->
         Log.Keeper.error
           "keeper tool cleanup after Gate replay repair failure raised: %s"
           (Printexc.to_string exn));
      Error
        (Keeper_internal_error.core_error_of_masc_internal_error
           (Keeper_internal_error.Gate_replay_repair_required
              { approval_id
              ; operation
              ; stage =
                  (match stage with
                   | Keeper_gate_replay.Resolution_lookup ->
                     Keeper_internal_error.Replay_resolution_lookup
                   | Keeper_gate_replay.Request_decode ->
                     Keeper_internal_error.Replay_request_decode
                   | Keeper_gate_replay.Evidence_storage ->
                     Keeper_internal_error.Replay_evidence_storage
                   | Keeper_gate_replay.Evidence_retrieval ->
                     Keeper_internal_error.Replay_evidence_retrieval
                   | Keeper_gate_replay.Replay_journal ->
                     Keeper_internal_error.Replay_journal
                   | Keeper_gate_replay.Stale_grant_retirement ->
                     Keeper_internal_error.Replay_stale_grant_retirement
                   | Keeper_gate_replay.Invalid_resolution_state ->
                     Keeper_internal_error.Replay_invalid_resolution_state)
              ; detail
              }))
    | Some
        ( _
        , ( Keeper_gate_replay.Not_applicable
          | Keeper_gate_replay.Applied _
          | Keeper_gate_replay.Applied_with_warning _
          | Keeper_gate_replay.Failed _
          | Keeper_gate_replay.Indeterminate _ ) )
    | None ->
      Ok ()
  in
  let model_message =
    Keeper_gate_replay.compose_model_message
      ~base_path:config.base_path
      ~user_message
      ~hitl_resolution
      ~replay_delivery
  in
  let user_message = model_message.Keeper_gate_replay.text in
  let prompt_metrics =
    Keeper_agent_prompt_metrics.build_prompt_metrics
      ~system_prompt:turn_system_prompt
      ~dynamic_context
      ~user_message
  in
  let tools = keeper_tools in
  let agent_core_tools = keeper_agent_core_tools in
  let registered_descriptors = Keeper_tool_descriptor.all_descriptors () in
  let globally_model_visible_descriptors =
    Keeper_tool_descriptor.model_visible_descriptors ()
  in
  let transport_alias_count =
    List.fold_left
      (fun count (descriptor : Keeper_tool_descriptor.t) ->
         match
           Keeper_tool_descriptor.model_schema_errors descriptor
         , descriptor.keeper_model_projection
         with
         | [], Keeper_tool_descriptor.Transport_alias _ -> count + 1
         | _ :: _, _
         | [],
           ( Keeper_tool_descriptor.Preferred_public_name
           | Keeper_tool_descriptor.Internal_name
           | Keeper_tool_descriptor.Operator_only ) -> count)
      0
      registered_descriptors
  in
  let operator_only_count =
    List.fold_left
      (fun count (descriptor : Keeper_tool_descriptor.t) ->
         match
           Keeper_tool_descriptor.model_schema_errors descriptor
         , descriptor.keeper_model_projection
         with
         | [], Keeper_tool_descriptor.Operator_only -> count + 1
         | ([], (Keeper_tool_descriptor.Preferred_public_name
                | Keeper_tool_descriptor.Internal_name
                | Keeper_tool_descriptor.Transport_alias _))
         | (_ :: _, _) -> count)
      0
      registered_descriptors
  in
  let invalid_schema_count =
    List.fold_left
      (fun count (descriptor : Keeper_tool_descriptor.t) ->
         match Keeper_tool_descriptor.model_schema_errors descriptor with
         | [] -> count
         | _ :: _ -> count + 1)
      0
      registered_descriptors
  in
  let unexplained_exclusion_count =
    List.length registered_descriptors
    - List.length globally_model_visible_descriptors
    - transport_alias_count
    - operator_only_count
    - invalid_schema_count
  in
  let all_tool_names =
    List.map (fun (tool : Agent_core.Tool.t) -> tool.schema.name) keeper_tools
  in
  (* The selection, not the offering (RFC-0403). This names what the bundle
     is expected to carry, and the bundle is built from the kept list:
     checking against the whole offering would report every tool the profile
     deliberately left out as a projection defect. *)
  let attached_names =
    List.map
      (fun (offered : Keeper_identity_tools.offered_tool) ->
         offered.Keeper_identity_tools.schema.name)
      identity_allow.Keeper_identity_tool_allow.kept
  in
  (* Two surfaces now, and each is checked against the names it carries. One
     check over one of them would leave the other free to drift: they differ
     only in how the attached tools appear, which is exactly the part being
     changed. *)
  let check_projection ?deferred_names ~surface ~identity_names tools =
    let actual = List.map (fun (tool : Agent_core.Tool.t) -> tool.schema.name) tools in
    let expected =
      expected_model_tool_names
        ?deferred_names
        ~skill_catalog
        ~identity_names
        ~model_visible_descriptors:turn_model_visible_descriptors
        ()
    in
    let deduped = List.sort_uniq String.compare actual in
    if not (expected = deduped && List.length deduped = List.length actual)
    then
      Log.Keeper.emit
        Log.Error
        ~keeper_name:meta.name
        ~category:Log.Tool
        ~details:
          (`Assoc
             [ "error_kind", `String "keeper_model_tool_projection_mismatch"
             ; "surface", `String surface
             ; "expected_names", Json_util.json_string_list expected
             ; "actual_names", Json_util.json_string_list actual
             ])
        "Keeper model tool bundle differs from the descriptor projection"
  in
  check_projection ~surface:"tools" ~identity_names:attached_names keeper_tools;
  let agent_core_actual_names =
    List.map
      (fun (tool : Agent_core.Tool.t) -> tool.schema.name)
      keeper_agent_core_tools
  in
  check_projection
    ~surface:"agent_core_tools"
    ~deferred_names:
      (match keeper_listing with
       | Keeper_tools_agent_core.No_listing -> []
       | Keeper_tools_agent_core.Listing { deferred_builtin_names } ->
         deferred_names_absent_from
           ~declared_names:deferred_builtin_names
           ~actual_names:
             (List.map
                (fun (tool : Agent_core.Tool.t) -> tool.Agent_core.Tool.schema.name)
                keeper_agent_core_tools))
    ~identity_names:
      (agent_core_identity_names
         ~listed:
           (match keeper_listing with
            | Keeper_tools_agent_core.No_listing -> false
            | Keeper_tools_agent_core.Listing _ -> true)
         ~attached_names
         ~actual_names:agent_core_actual_names)
    keeper_agent_core_tools;
  Log.Keeper.routine
    "keeper:%s tool visibility: registered=%d visible=%d transport_alias=%d \
     operator_only=%d invalid_schema=%d unexplained=%d"
    meta.name
    (List.length registered_descriptors)
    (List.length all_tool_names)
    transport_alias_count
    operator_only_count
    invalid_schema_count
    unexplained_exclusion_count;
  let record_tool_assignment ~turn ~tool_list ~lane =
    let (_assignment_id : Tool_assignment_telemetry.assignment_id) =
      Tool_assignment_telemetry.emit_assigned
        ~agent_id:meta.name
        ~profile:"keeper"
        ~tool_list
        ~reason:
          (Printf.sprintf
             "keeper before_turn tool surface turn=%d lane=%s"
             turn
             (Keeper_agent_tool_surface.turn_lane_to_string lane))
        ()
    in
    ()
  in
  let final_agent_core_turn_ordinal_ref : int option ref = ref None in
  let receipt_turn_count_ref : int option ref = ref None in
  let receipt_model_used_ref : string option ref = ref None in
  let receipt_stop_reason_ref : Runtime_agent.stop_reason option ref =
    ref None
  in
  let receipt_runtime_observation_ref
    : Runtime_observation.runtime_observation option ref
    =
    ref None
  in
  let receipt_response_text_present_ref = ref false in
  let compute_tool_surface
        ~turn:_
        ~current_tool_choice
        ()
    : string list * turn_lane
    =
    (* What is actually on the wire this round, not what was on it when the
       tools were built. The attached-service listing widens the callable set
       mid-turn, so from the round after a load the built list is short by
       exactly the tools the model just asked for -- and this is the record an
       operator reads to find out what the model was offered. Before the agent
       exists the built list is the whole truth. *)
    let schema_filter =
      match !agent_cell with
      | Some agent -> Agent_core.Tool_set.names (Agent_core.Agent.tools agent)
      | None -> all_tool_names
    in
    let lane : Keeper_agent_tool_surface.turn_lane =
      if is_retry
      then Lane_retry
      else if schema_filter <> []
      then Lane_tool_optional
      else (
        match current_tool_choice with
        | Some Agent_core.Types.None_ -> Lane_tool_disabled
        | _ -> Lane_text_only)
    in
    (schema_filter, lane)
  in

  let ctx : Keeper_run_tools_hooks.ctx =
    { acc
    ; agent_cell
    ; agent_name
    ; all_tool_names
    ; compute_tool_surface
    ; record_tool_assignment
    ; config
    ; keeper_tools_cleanup
    ; terminal_effect_state
    ; keeper_turn_id
    ; turn_kind
    ; meta
    ; profile_defaults
    ; turn_ctx_cell
    ; final_agent_core_turn_ordinal_ref
    ; receipt_turn_count_ref
    ; receipt_model_used_ref
    ; receipt_stop_reason_ref
    ; receipt_runtime_observation_ref
    ; receipt_lane_attempt_index_ref
    ; receipt_response_text_present_ref
    ; on_runtime_attempt
    ; tool_result_commit_required
    ; on_tool_stream_observation
    ; skill_activation_context
    ; on_tool_result_ready
    ; tools
    ; agent_core_tools
    }
  in
  Keeper_run_tools_hooks.assemble_hooks
    ~ctx ~session ~turn_system_prompt ~user_message ~dynamic_context
    ~history_messages ~prompt_metrics ~shared_context
    ~start_turn_count
    ~runtime_id_string ~is_retry
    ~config_root ~runtime_config_path
    ~trajectory_acc
    ~skill_projection_diagnostics
    ?gate_replay_evidence:model_message.replay_evidence
    ?runtime_manifest_context ?runtime_manifest_append ()
