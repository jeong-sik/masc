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

let skill_catalog_config_error detail =
  Agent_core.Error.Config
    (Agent_core.Error.InvalidConfig { field = "skills"; detail })
;;

let skill_catalog_io_error ~op ~path exn =
  Agent_core.Error.Io
    (Agent_core.Error.FileOpFailed
       { op; path; detail = Printexc.to_string exn })
;;

let skills_dir_of_base_path ~base_path =
  Common.skills_dir_from_base_path ~base_path
;;

(* A directory under skills/ that carries no SKILL.md is not a skill and is
   skipped: in the Agent Skills layout the file is the declaration, and a
   half-installed directory should not take the whole tool surface down. A
   SKILL.md that exists but fails to parse is a config error — the operator
   declared a skill and masc cannot honour it. *)
let load_skill_catalog ~base_path =
  let skills_dir = skills_dir_of_base_path ~base_path in
  match
    try Ok (Fs_compat.exact_path_kind skills_dir) with
    | Eio.Cancel.Cancelled _ as exn -> raise exn
    | exn -> Error (skill_catalog_io_error ~op:"inspect" ~path:skills_dir exn)
  with
  | Error _ as error -> error
  | Ok Fs_compat.Exact_missing -> Ok Keeper_skill_catalog.empty
  | Ok (Fs_compat.Exact_kind Unix.S_DIR) ->
    (match
       try Ok (List.sort String.compare (Fs_compat.read_dir skills_dir)) with
       | Eio.Cancel.Cancelled _ as exn -> raise exn
       | exn ->
         Error (skill_catalog_io_error ~op:"read_dir" ~path:skills_dir exn)
     with
     | Error _ as error -> error
     | Ok entries ->
       let rec collect documents = function
         | [] -> Ok (List.rev documents)
         | entry :: rest ->
           let skill_md =
             Filename.concat (Filename.concat skills_dir entry) "SKILL.md"
           in
           (match
              try Ok (Fs_compat.exact_path_kind skill_md) with
              | Eio.Cancel.Cancelled _ as exn -> raise exn
              | exn ->
                Error (skill_catalog_io_error ~op:"inspect" ~path:skill_md exn)
            with
            | Error _ as error -> error
            | Ok (Fs_compat.Exact_kind Unix.S_REG) ->
              (match
                 try Ok (Fs_compat.load_file skill_md) with
                 | Eio.Cancel.Cancelled _ as exn -> raise exn
                 | exn ->
                   Error (skill_catalog_io_error ~op:"read" ~path:skill_md exn)
               with
               | Error _ as error -> error
               | Ok contents -> collect ((entry, contents) :: documents) rest)
            | Ok
                ( Fs_compat.Exact_missing
                | Fs_compat.Exact_unknown
                | Fs_compat.Exact_kind
                    ( Unix.S_DIR
                    | Unix.S_CHR
                    | Unix.S_BLK
                    | Unix.S_LNK
                    | Unix.S_FIFO
                    | Unix.S_SOCK ) ) -> collect documents rest)
       in
       (match collect [] entries with
        | Error _ as error -> error
        | Ok documents ->
          (match Keeper_skill_catalog.of_documents documents with
           | Ok catalog -> Ok catalog
           | Error error ->
             Error
               (skill_catalog_config_error
                  (Keeper_skill_catalog.error_to_string error)))))
  | Ok
      (Fs_compat.Exact_kind
        ( Unix.S_REG
        | Unix.S_CHR
        | Unix.S_BLK
        | Unix.S_LNK
        | Unix.S_FIFO
        | Unix.S_SOCK )) ->
    Error (skill_catalog_config_error "skills path is not a directory")
  | Ok Fs_compat.Exact_unknown ->
    Error (skill_catalog_config_error "skills path kind is unavailable")
;;

let expected_model_tool_names ~skill_catalog ~model_visible_descriptors =
  let descriptor_names =
    model_visible_descriptors
    |> List.concat_map Keeper_tool_descriptor.keeper_model_names
  in
  let entries = Keeper_skill_catalog.composition_entries skill_catalog in
  let composition_names =
    List.map Keeper_tool_composition_catalog.tool_name entries
  in
  (* The shared async controls join the surface when any skill declares an
     async composition. *)
  let control_names =
    if
      List.exists
        (fun (entry : Keeper_tool_composition_catalog.entry) ->
          entry.execution = Keeper_tool_composition_catalog.Async)
        entries
    then
      [ Keeper_tool_composition_catalog.status_tool_name
      ; Keeper_tool_composition_catalog.cancel_tool_name
      ]
    else []
  in
  List.sort_uniq
    String.compare
    (Keeper_tool_composition_surface.plan_execute_tool_name
     :: (descriptor_names @ composition_names @ control_names))
;;

let prepare_agent_setup
      ~(config : Workspace.config)
      ~(meta : Keeper_meta_contract.keeper_meta)
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
      ~(trajectory_acc : Trajectory.accumulator option)
      ?runtime_manifest_context
      ?runtime_manifest_append
      ?continuation_channel
      ?on_tool_result_ready
      ?hitl_resolution
      ()
  : (Keeper_run_tools_hooks.agent_setup, Agent_core.Error.t) result
  =
  let ( let* ) = Result.bind in
  let runtime_id_string = runtime_id in
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
  let agent_name = meta.agent_name in
  let* skill_catalog = load_skill_catalog ~base_path:config.base_path in
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
  let
    { Keeper_tools_agent_core.tools = keeper_tools
    ; cleanup = keeper_tools_cleanup
    ; terminal_effect_state
    ; gate_replay_delivery
    }
    =
    Keeper_tools_agent_core_bundle.make_tool_bundle
      ~config
      ~meta
      ~publication_recovery
      ~ctx_snapshot
      ?continuation_channel
      ~gate_context
      ?hitl_resolution
      ~skill_catalog
      ~turn_ctx_cell
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
  let registered_descriptors = Keeper_tool_descriptor.all_descriptors () in
  let model_visible_descriptors =
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
    - List.length model_visible_descriptors
    - transport_alias_count
    - operator_only_count
    - invalid_schema_count
  in
  let all_tool_names =
    List.map (fun (tool : Agent_core.Tool.t) -> tool.schema.name) keeper_tools
  in
  let expected_model_names =
    expected_model_tool_names ~skill_catalog ~model_visible_descriptors
  in
  let actual_model_names = List.sort_uniq String.compare all_tool_names in
  let all_model_eligible_tools_visible =
    expected_model_names = actual_model_names
    && List.length actual_model_names = List.length all_tool_names
  in
  if not all_model_eligible_tools_visible
  then
    Log.Keeper.emit
      Log.Error
      ~keeper_name:meta.name
      ~category:Log.Tool
      ~details:
        (`Assoc
           [ "error_kind", `String "keeper_model_tool_projection_mismatch"
           ; "expected_names", Json_util.json_string_list expected_model_names
           ; "actual_names", Json_util.json_string_list all_tool_names
           ])
      "Keeper model tool bundle differs from the descriptor projection";
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
        ~agent_id:meta.agent_name
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
  let receipt_lane_attempt_index_ref : int ref = ref 0 in
  let receipt_response_text_present_ref = ref false in
  let compute_tool_surface
        ~turn:_
        ~current_tool_choice
        ()
    : string list * turn_lane
    =
    let schema_filter = all_tool_names in
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
    ; turn_ctx_cell
    ; final_agent_core_turn_ordinal_ref
    ; receipt_turn_count_ref
    ; receipt_model_used_ref
    ; receipt_stop_reason_ref
    ; receipt_runtime_observation_ref
    ; receipt_lane_attempt_index_ref
    ; receipt_response_text_present_ref
    ; on_tool_result_ready
    ; tools
    }
  in
  Keeper_run_tools_hooks.assemble_hooks
    ~ctx ~session ~turn_system_prompt ~user_message ~dynamic_context
    ~history_messages ~prompt_metrics ~shared_context
    ~start_turn_count
    ~runtime_id_string ~is_retry
    ~config_root ~runtime_config_path
    ~trajectory_acc
    ?gate_replay_evidence:model_message.replay_evidence
    ?runtime_manifest_context ?runtime_manifest_append ()
