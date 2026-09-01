(** Tool bundle assembly for keeper AGENT_CORE execution.

    [make_tool_bundle] builds the full [tool_bundle] from each descriptor's
    single explicit Keeper-model projection, and [make_tools] is the
    convenience wrapper returning only [.tools].

    Extracted from [Keeper_tools_agent_core_handler] to keep that module
    focused on per-tool handler construction. *)

open Keeper_tools_agent_core

let terminal_externalization_failure
      state
      ({ message; _ } : Tool_bridge.externalization_error)
  =
  match state with
  | Keeper_tools_agent_core.Terminal_effect_completed _ ->
    Some
      { Keeper_tools_agent_core.failure_class = Tool_result.Runtime_failure
      ; effect_disposition = Tool_result.Proven_post_effect
      ; diagnostic = "tool output artifact storage failed: " ^ message
      }
  | ( Keeper_tools_agent_core.Terminal_effect_open
    | Keeper_tools_agent_core.Deferred_tool_result
    | Keeper_tools_agent_core.External_effect_deferred
    | Keeper_tools_agent_core.Terminal_effect_failed _ ) ->
    None
;;

let initial_terminal_effect_state = function
  | Some
      { Keeper_tools_agent_core.outcome =
          ( Keeper_gate_replay.Applied _
          | Keeper_gate_replay.Applied_with_warning _ )
      ; terminal_effect_receipt = Some receipt
      ; _
      } ->
    Keeper_tools_agent_core.Terminal_effect_completed receipt
  | Some _ | None -> Keeper_tools_agent_core.Terminal_effect_open
;;

let make_tool_bundle_for_descriptors_with_policy
      ~(config : Workspace.config)
      ~(meta : Keeper_meta_contract.keeper_meta)
      ~(publication_recovery :
          Keeper_publication_recovery_availability.turn_context)
      ~(ctx_snapshot : Keeper_types.working_context)
      ?clock
      ?continuation_channel
      ?gate_context
      ?hitl_resolution
      ?(skill_catalog = Keeper_skill_catalog.empty)
      ?(identity_surface : Keeper_tools_agent_core.attached_surface option)
      ?composition_plan_index
      ?skill_activation_context
      ?(allow_unrecorded_skill_surface = false)
      ?turn_ctx_cell
      ?capability_surface
      ~(descriptors : Keeper_tool_descriptor.t list)
      ()
  : tool_bundle
  =
  let descriptors =
    List.map
      (fun (descriptor : Keeper_tool_descriptor.t) ->
         match Keeper_tool_descriptor.find_id descriptor.id with
         | Some canonical -> canonical
         | None ->
           invalid_arg
             (Printf.sprintf
                "Keeper tool bundle received unknown descriptor id %S"
                descriptor.id))
      descriptors
  in
  let skill_surface_present =
    Keeper_skill_catalog.skills skill_catalog <> []
  in
  (match skill_surface_present, skill_activation_context with
   | true, None when not allow_unrecorded_skill_surface ->
     invalid_arg
       "Skill-bearing Keeper bundle requires a frozen activation context"
   | true, None
   | true, Some _ | false, Some _ | false, None -> ());
  (* PR-3b (#11611 part 1): replace eager [Keeper_turn_sandbox_runtime]
     instances with a factory. in_playground and the runtime cache key need
     the call site's [cwd], which is unknown at turn start, so the factory
     defers creating the runtime until a call site supplies it.

     The profile itself is not deferred in any meaningful sense:
     [Keeper_sandbox_runner.effective_sandbox_profile] takes only [~meta] and
     projects [meta.sandbox_profile], so every call in this turn gets the same
     answer from the [meta] captured here. *)
  let turn_sandbox_factory = Some (Keeper_sandbox_factory.create ~config ~meta ()) in
  let gate_grant =
    Option.bind hitl_resolution Keeper_gate.cycle_grant_of_resolution
  in
  let gate_context_provider =
    Option.map
      (fun context () -> Keeper_gate_causal_context.snapshot context)
      gate_context
  in
  (* RFC-0356: the approval owns its effect. Spend the one-shot grant on the
     payload the Gate approved instead of waiting for the model to re-emit a
     byte-identical call, which it cannot do for large write payloads
     (#25947). Consumption is the durable grant, so a second bundle build in
     the same cycle replays nothing.

     Replay carries the same causal context the model-issued path carries: a
     replay whose re-derived input no longer matches its approval follows the
     producer's ordinary Gate behavior instead of inventing another replay
     constraint. *)
  let gate_replay_delivery =
    match hitl_resolution, gate_grant with
    | ( Some
          { Keeper_event_queue.approval_id
          ; decision = Keeper_event_queue.Hitl_approved
          ; _
          }
      , Some grant ) ->
      let replay_execution =
        Keeper_gate_replay.replay_approved_effect_with_receipt
           ~config
           ~meta
           ~publication_recovery
           ~turn_sandbox_factory
           ?continuation_channel
           ?gate_context:gate_context_provider
           ~grant
           ~approval_id
           ()
      in
      let outcome = replay_execution.Keeper_gate_replay.outcome in
      (match outcome with
       | Keeper_gate_replay.Not_applicable -> ()
       | Keeper_gate_replay.Applied _ as outcome ->
         Log.Keeper.info
           "gate replay approval=%s %s"
           approval_id
           (Keeper_gate_replay.outcome_to_string outcome)
       | Keeper_gate_replay.Applied_with_warning _ as outcome ->
         Log.Keeper.error
           "gate replay approval=%s %s"
           approval_id
           (Keeper_gate_replay.outcome_to_string outcome)
       | Keeper_gate_replay.Failed _ as outcome ->
         Log.Keeper.error
           "gate replay approval=%s %s"
           approval_id
           (Keeper_gate_replay.outcome_to_string outcome)
       | Keeper_gate_replay.Indeterminate _ as outcome ->
         Log.Keeper.error
           "gate replay approval=%s %s"
           approval_id
           (Keeper_gate_replay.outcome_to_string outcome)
       | Keeper_gate_replay.Repair_required _ as outcome ->
         Log.Keeper.error
           "gate replay approval=%s %s"
           approval_id
           (Keeper_gate_replay.outcome_to_string outcome));
      Some
        Keeper_tools_agent_core.
          { approval_id
          ; outcome
          ; terminal_effect_receipt = replay_execution.terminal_effect_receipt
          }
    | _ -> None
  in
  let record_gate_result =
    Option.map
      (fun context ~operation ~input result ->
         Keeper_gate_causal_context.record_tool_result
           context
           ~operation
           ~input
           result)
      gate_context
  in
  (* Every descriptor authorized by this caller is materialized through the
     canonical Keeper handler. A Keeper turn supplies its frozen Tool Group
     surface; bounded internal roles supply their own closed typed subset. *)
  (* The bundle lives for exactly one Agent run. Its typed tool-boundary
     state is request-scoped and observed by the AGENT_CORE tool-boundary probe only
     after the whole tool batch and checkpoint sink have completed. A generic
     deferred tool transition retains the existing durable-stimulus checkpoint;
     only a typed external-effect defer stops the provider loop until Gate's
     durable resolution wakes a later turn. An already-applied connector replay
     seeds this same state from its producer-owned receipt, so finalization does
     not mistake the post-effect continuation for another visible reply. A
     terminal completion supersedes a defer in the same batch; a proven terminal
     failure dominates every state regardless of callback order. Failure is
     sticky so its first diagnostic remains authoritative. *)
  let terminal_effect_state =
    Atomic.make (initial_terminal_effect_state gate_replay_delivery)
  in
  let mark_deferred_tool_result () =
    ignore
      (Atomic.compare_and_set
         terminal_effect_state
         Terminal_effect_open
         Deferred_tool_result)
  in
  let mark_external_effect_deferred () =
    (* A generic deferred transition may precede the Gate result in one AGENT_CORE
       batch. The external effect owns the user-facing terminal projection, so
       it must promote that generic state rather than being hidden by it. *)
    let rec transition () =
      match Atomic.get terminal_effect_state with
      | External_effect_deferred
      | Terminal_effect_completed _
      | Terminal_effect_failed _ ->
        ()
      | (Terminal_effect_open | Deferred_tool_result) as current ->
        if
          not
            (Atomic.compare_and_set
               terminal_effect_state
               current
               External_effect_deferred)
        then transition ()
    in
    transition ()
  in
  let mark_terminal_effect_completed receipt =
    let rec transition () =
      match Atomic.get terminal_effect_state with
      | Terminal_effect_completed _ | Terminal_effect_failed _ -> ()
      | ( Terminal_effect_open
        | Deferred_tool_result
        | External_effect_deferred ) as current ->
        if
          not
            (Atomic.compare_and_set
               terminal_effect_state
               current
               (Terminal_effect_completed receipt))
        then transition ()
    in
    transition ()
  in
  let mark_terminal_effect_failed failure =
    let rec transition () =
      match Atomic.get terminal_effect_state with
      | Terminal_effect_failed _ -> ()
      | ( Terminal_effect_open
        | Deferred_tool_result
        | External_effect_deferred
        | Terminal_effect_completed _ ) as current ->
        if
          not
            (Atomic.compare_and_set
               terminal_effect_state
               current
               (Terminal_effect_failed failure))
        then transition ()
    in
    transition ()
  in
  let mark_completed_terminal_externalization_failed
      error
    =
    terminal_externalization_failure
      (Atomic.get terminal_effect_state)
      error
    |> Option.iter mark_terminal_effect_failed
  in
  (* The handler dispatches with
     [~name:descriptor.internal_name] so all telemetry SSOT remains internal;
     exactly one projected Tool.schema.name is model-visible.
     the descriptor-owned typed translation reshapes the LLM's payload before dispatch;
     [descriptor.input_schema] provides the LLM-facing schema. *)
  let descriptor_tools =
    List.concat_map
      (fun (descriptor : Keeper_tool_descriptor.t) ->
         let internal = descriptor.internal_name in
         let agent_core_descriptor =
           match descriptor.execution with
           | Keeper_tool_descriptor.Ordinary Keeper_tool_descriptor.Serial ->
             Some
               (Agent_core.Tool.ordinary_descriptor Agent_core.Tool_contract.Serial)
           | Keeper_tool_descriptor.Ordinary Keeper_tool_descriptor.Concurrent ->
             Some
               (Agent_core.Tool.ordinary_descriptor
                  Agent_core.Tool_contract.Concurrent)
           | Keeper_tool_descriptor.Direct_terminal
           | Keeper_tool_descriptor.Terminal ->
             Some
               (Agent_core.Tool.terminal_descriptor
                  Agent_core.Tool_contract.Effect_outcome_unknown)
         in
         let on_completed, on_failed, on_externalization_error =
           match descriptor.execution with
           | Keeper_tool_descriptor.Direct_terminal
           | Keeper_tool_descriptor.Terminal ->
             ( Some
                 (function
                   | Some receipt -> mark_terminal_effect_completed receipt
                   | None ->
                     mark_terminal_effect_failed
                       { failure_class = Tool_result.Runtime_failure
                       ; effect_disposition = Tool_result.Effect_outcome_unknown
                       ; diagnostic =
                           "terminal tool completed without a typed effect receipt"
                       })
             , Some mark_terminal_effect_failed
             , Some mark_completed_terminal_externalization_failed )
           | Keeper_tool_descriptor.Ordinary
               (Keeper_tool_descriptor.Serial | Keeper_tool_descriptor.Concurrent) ->
             let on_failed =
               match descriptor.runtime_handler with
               (* A spawn that started leaves a process running with no
                  handle in the caller's hands if the call then fails, which
                  is the same shape of loss Execute has. *)
               | Keeper_tool_descriptor.Tool_execute
               | Keeper_tool_descriptor.Tool_keeper_spawn_dispatch
               (* A failed webmcp call may have already executed the page's
                  tool — the bridge cannot prove otherwise — which is the
                  same effect-outcome-unknown shape Execute has. *)
               | Keeper_tool_descriptor.Tool_keeper_webmcp_dispatch ->
                 Some mark_terminal_effect_failed
               (* A code query starts a language server, but the pool owns it
                  and the turn ends it either way, so a failed call leaves the
                  caller holding nothing. It answers with the readers. *)
               | ( Keeper_tool_descriptor.Tool_keeper_code_query_dispatch
                 | Keeper_tool_descriptor.Tool_search_files
                 | Keeper_tool_descriptor.Tool_read_file
                 | Keeper_tool_descriptor.Tool_edit_file
                 | Keeper_tool_descriptor.Tool_write_file
                 | Keeper_tool_descriptor.Tool_time_now
                 | Keeper_tool_descriptor.Tool_tools_list
                 | Keeper_tool_descriptor.Tool_capability_search
                 | Keeper_tool_descriptor.Tool_context_status
                 | Keeper_tool_descriptor.Tool_artifact_read
                 | Keeper_tool_descriptor.Tool_memory_search
                 | Keeper_tool_descriptor.Tool_memory_retract
                 | Keeper_tool_descriptor.Tool_memory_write
                 | Keeper_tool_descriptor.Tool_library_search
                 | Keeper_tool_descriptor.Tool_library_read
                 | Keeper_tool_descriptor.Tool_surface_read
                 | Keeper_tool_descriptor.Tool_surface_post
                 | Keeper_tool_descriptor.Tool_person_note_set
                 | Keeper_tool_descriptor.Tool_ide_annotate
                 | Keeper_tool_descriptor.Tool_voice_dispatch
                 | Keeper_tool_descriptor.Tool_task_dispatch
                 | Keeper_tool_descriptor.Tool_board_dispatch
                 | Keeper_tool_descriptor.Tool_masc_task_dispatch
                 | Keeper_tool_descriptor.Tool_masc_plan_dispatch
                 | Keeper_tool_descriptor.Tool_masc_run_dispatch
                 | Keeper_tool_descriptor.Tool_masc_agent_dispatch
                 | Keeper_tool_descriptor.Tool_masc_workspace_dispatch
                 | Keeper_tool_descriptor.Tool_masc_misc_dispatch
                 | Keeper_tool_descriptor.Tool_web_search
                 | Keeper_tool_descriptor.Tool_web_fetch
                 | Keeper_tool_descriptor.Tool_masc_control_dispatch
                 | Keeper_tool_descriptor.Tool_masc_agent_timeline_dispatch
                 | Keeper_tool_descriptor.Tool_masc_schedule_dispatch
                 | Keeper_tool_descriptor.Tool_masc_keeper_dispatch
                 | Keeper_tool_descriptor.Tool_masc_fusion_dispatch
                 | Keeper_tool_descriptor.Tool_masc_fusion_status
                 | Keeper_tool_descriptor.Tool_masc_library_dispatch
                 | Keeper_tool_descriptor.Tool_masc_local_runtime_dispatch
                 | Keeper_tool_descriptor.Tool_analyze_image ) ->
                 None
             in
             None, on_failed, None
         in
         Keeper_tool_descriptor.keeper_model_names descriptor
         |> List.map (fun model_name ->
             let h =
               match capability_surface with
               | Some capability_surface ->
                 Keeper_tools_agent_core_handler.make_keeper_tool_handler
                   ~capability_surface
                   ~name:internal
                   ~descriptor
                   ~model_name
                   ~input_schema:descriptor.input_schema
                   ~config
                   ~meta
                   ~publication_recovery
                   ~ctx_snapshot
                   ?turn_sandbox_factory
                   ?clock
                   ?continuation_channel
                   ?gate_context:gate_context_provider
                   ?gate_grant
                   ?record_gate_result
                   ?on_completed
                   ~on_deferred:mark_deferred_tool_result
                   ~on_external_effect_deferred:mark_external_effect_deferred
                   ?on_failed
                   ()
               | None ->
                 Keeper_tools_agent_core_handler.make_keeper_tool_handler_from_meta
                   ~name:internal
                   ~input_schema:descriptor.input_schema
                   ~config
                   ~meta
                   ~publication_recovery
                   ~ctx_snapshot
                   ?turn_sandbox_factory
                   ?clock
                   ?continuation_channel
                   ?gate_context:gate_context_provider
                   ?gate_grant
                   ?record_gate_result
                   ?on_completed
                   ~on_deferred:mark_deferred_tool_result
                   ~on_external_effect_deferred:mark_external_effect_deferred
                   ?on_failed
                   ~prepare_input:(fun input ->
                     Keeper_tool_descriptor_resolution.prepare_model_input_for_descriptor
                       ~tool_name:model_name
                       descriptor
                       ~input)
                   ()
             in
             Tool_bridge.agent_core_tool_of_masc_with_execution_env
               ?descriptor:agent_core_descriptor
               ~base_path:config.base_path
               ~model_projection:descriptor.model_output_projection
               ?on_externalization_error
               ~name:model_name
               ~description:descriptor.description
               ~input_schema:descriptor.input_schema
               (fun execution_env input ->
                 h
                   ?agent_core_invocation:
                     (Agent_core.Tool.Execution_env.invocation execution_env)
                   input)))
      descriptors
  in
  let composition_tools =
    let instruction_skills =
      Keeper_skill_catalog.skills skill_catalog
      |> List.filter_map (fun (skill : Keeper_skill_catalog.skill) ->
           match skill.reference, skill.surface with
           | Some reference, Keeper_skill_catalog.Instruction ->
             let resource_location =
               match skill.provenance with
               | Some
                   { source_root = Some source_root
                   ; resource_read_max_bytes = Some resource_read_max_bytes
                   ; directory
                   ; _
                   } ->
                 Some
                   Keeper_tool_composition_surface.
                     { source_root; directory; resource_read_max_bytes }
               | Some { source_root = None; _ }
               | Some { resource_read_max_bytes = None; _ }
               | None ->
                 None
             in
             Some
               (Keeper_tool_composition_surface.instruction_skill
                  ?resource_location
                  ~reference
                  ~description:skill.description
                  ~body:skill.body
                  ())
           | None, _ | Some _, Keeper_skill_catalog.Composition _ ->
             None)
    in
    let composition_skills =
      Keeper_skill_catalog.skills skill_catalog
      |> List.filter_map (fun (skill : Keeper_skill_catalog.skill) ->
           match skill.reference, skill.surface with
           | Some reference, Keeper_skill_catalog.Composition entry ->
             Some Keeper_tool_composition_surface.{ reference; entry }
           | None, _ | Some _, Keeper_skill_catalog.Instruction ->
             None)
    in
    let record_instruction_activation =
      Option.map
        (fun context ~invocation ~content reference ->
           Keeper_skill_activation_recorder.record_instruction
             ~config
             context
             ~invocation
             ~content
             reference)
        skill_activation_context
    in
    let record_composition_activation =
      Option.map
        (fun context ~invocation ~tool_name ~reference ->
           Keeper_skill_activation_recorder.record_composition
             ~config
             context
             ~invocation
             ~tool_name
             reference)
        skill_activation_context
    in
    let make_composition_tools =
      match capability_surface with
      | Some capability_surface ->
        Keeper_tool_composition_surface.make_tools ~capability_surface
      | None ->
        Keeper_tool_composition_surface.Compatibility.make_tools ~descriptors
    in
    make_composition_tools
        ~instruction_skills
        ~skill_compositions:composition_skills
        ?composition_plan_index
        ~config
        ~meta
        ~publication_recovery
        ~ctx_snapshot
        ?record_instruction_activation
        ?record_composition_activation
        ?turn_sandbox_factory
        ?turn_ctx_cell
        ?clock
        ?continuation_channel
        ?gate_context:gate_context_provider
        ?gate_grant
        ?record_gate_result
        ~on_completed:(function
          | Some receipt -> mark_terminal_effect_completed receipt
          | None ->
            mark_terminal_effect_failed
              { failure_class = Tool_result.Runtime_failure
              ; effect_disposition = Tool_result.Effect_outcome_unknown
              ; diagnostic =
                  "terminal composition completed without a typed target receipt"
              })
        ~on_deferred:mark_deferred_tool_result
        ~on_external_effect_deferred:mark_external_effect_deferred
        ~on_failed:mark_terminal_effect_failed
        ~on_externalization_error:mark_completed_terminal_externalization_failed
        ()
  in
  (* Identity tools are external effects by definition; they join the turn
     only behind the durable Gate. A row whose provider said "read only"
     runs as before, everything else defers to the approvals queue. The
     cycle's one-shot grant threads through so an approved exact call can be
     spent in the woken cycle.

     They reach the model through the listing rather than directly: an
     attached service offers more tools than a request can carry, and the
     Gate wrapper is the same either way. *)
  let gate_wrapped offered =
    Keeper_identity_gate.agent_tool
      ~config
      ~meta
      ?continuation_channel
      ?gate_context:gate_context_provider
      ?gate_grant
      offered
  in
  (* Attached tools, as schemas. What the lanes that cannot widen a running
     turn are given: they pin their tool set at process spawn or thread start,
     and that set is part of a resumable session's identity, so a listing
     would name tools they can never make callable. *)
  let identity_agent_tools =
    List.map
      gate_wrapped
      (match identity_surface with
       | None -> []
       | Some surface -> surface.Keeper_tools_agent_core.offered)
  in
  (* What the model is shown by name instead of by schema.

     Two sources, one answer. An attached tool is held back by default: a
     Keeper is handed its services' entire lists, 145 tools and 142,257 bytes
     on the Keeper the RFC measured. A built-in is held back when its own
     [config/tools/<name>.toml] declares [defer_loading = true] -- of 89
     built-ins on one Keeper, 33 went a whole day uncalled, 21,601 bytes
     charged to every request of every turn.

     The listing does not record which source a tool came from, and the model
     is not told. Holding a tool back is a property of the tool. *)
  let deferred_builtin_tools, always_loaded_builtin_tools =
    (* Both families, because both are declared the same way. Splitting only
       the descriptors would leave a [defer_loading = true] in a composition
       tool's file that nothing honours and nothing reports -- a declaration
       is either read wherever it can be written or it is a trap. *)
    List.partition
      (fun (tool : Agent_core.Tool.t) ->
         match
           Tool_loading_declarations.loading_of_tool tool.Agent_core.Tool.schema.name
         with
         | Tool_definition_toml.Deferrable -> true
         | Tool_definition_toml.Always_loaded -> false)
      (descriptor_tools @ composition_tools)
  in
  let deferred_of tool =
    { Keeper_identity_tool_search.tool
    ; summary =
        Keeper_identity_tool_search.summary_of
          tool.Agent_core.Tool.schema.description
    }
  in
  let identity_listing =
    match identity_surface with
    | None ->
      (match deferred_builtin_tools with
       | [] -> None
       | _ :: _ ->
         Keeper_identity_tool_search.make
           ~keeper_name:meta.Keeper_meta_contract.name
           { Keeper_identity_tool_search.deferred =
               List.map deferred_of deferred_builtin_tools
           ; agent_cell = ref None
           ; history = []
           })
    | Some surface ->
      Keeper_identity_tool_search.make
        ~keeper_name:meta.Keeper_meta_contract.name
        { Keeper_identity_tool_search.deferred =
            List.map
              (fun offered -> deferred_of (gate_wrapped offered))
              surface.Keeper_tools_agent_core.offered
            @ List.map deferred_of deferred_builtin_tools
        ; agent_cell = surface.Keeper_tools_agent_core.agent_cell
        ; history = surface.Keeper_tools_agent_core.history
        }
  in
  (* The lanes that cannot widen a turn get every tool as a schema: holding
     one back there would name a tool nothing can load. *)
  let always_loaded = always_loaded_builtin_tools in
  { tools = descriptor_tools @ composition_tools @ identity_agent_tools
  ; agent_core_tools =
      always_loaded
      @ (match identity_listing with
         | None -> []
         | Some listing ->
           (* The listing, plus the attached tools this conversation has
              run. A load reaches the agent of the turn that made it and no
              further, so without the second part the model asks again every
              turn: one Keeper asked for [github_issue_read] on five
              consecutive turns. Placing them here rather than widening after
              the agent exists means the first request of the turn already
              carries them, so no round trip is spent re-asking. *)
           listing.Keeper_identity_tool_search.tool
           :: listing.Keeper_identity_tool_search.already_used)
  ; listing =
      (match identity_listing with
       | None -> Keeper_tools_agent_core.No_listing
       | Some listing ->
         (* What is missing from the surface, not what declared itself. A tool
            this conversation has run is placed with its schema again, so a
            declared tool can be present after all -- and reporting the
            declaration would have the projection check expect it gone. *)
         let carried =
           List.map
             (fun (tool : Agent_core.Tool.t) -> tool.Agent_core.Tool.schema.name)
             listing.Keeper_identity_tool_search.already_used
         in
         Keeper_tools_agent_core.Listing
           { deferred_builtin_names =
               List.filter_map
                 (fun (tool : Agent_core.Tool.t) ->
                    let name = tool.Agent_core.Tool.schema.name in
                    if List.exists (String.equal name) carried then None else Some name)
                 deferred_builtin_tools
           })
  ; cleanup =
      (fun () ->
        (* Turn end on both the ordinary and the raised path -- this thunk is
           what [run_with_setup_cleanup] guarantees -- which is the only point
           where "the listing found nothing usable" is still answerable.
           Before the sandbox release rather than after: this reads two lists
           and writes a log line, and releasing a runtime can raise, which
           would take the reading with it. *)
        Option.iter
          (fun (listing : Keeper_identity_tool_search.placement) ->
             let (_ : Keeper_identity_tool_search.turn_discovery) =
               listing.Keeper_identity_tool_search.observe_turn ()
             in
             ())
          identity_listing;
        Option.iter Keeper_sandbox_factory.cleanup turn_sandbox_factory)
  ; terminal_effect_state = (fun () -> Atomic.get terminal_effect_state)
  ; gate_replay_delivery
  }
;;

let make_tool_bundle_for_capability_surface
      ~config
      ~meta
      ~publication_recovery
      ~ctx_snapshot
      ?clock
      ?continuation_channel
      ?gate_context
      ?hitl_resolution
      ?identity_surface
      ?composition_plan_index
      ?skill_activation_context
      ?turn_ctx_cell
      ~capability_surface
      ()
  =
  make_tool_bundle_for_descriptors_with_policy
    ~config
    ~meta
    ~publication_recovery
    ~ctx_snapshot
    ?clock
    ?continuation_channel
    ?gate_context
    ?hitl_resolution
    ~skill_catalog:(Keeper_capability_surface.skill_catalog capability_surface)
    ?identity_surface
    ?composition_plan_index
    ?skill_activation_context
    ~allow_unrecorded_skill_surface:false
    ?turn_ctx_cell
    ~descriptors:(Keeper_capability_surface.descriptors capability_surface)
    ~capability_surface
    ()
;;

let make_tool_bundle_with_policy
      ~(config : Workspace.config)
      ~(meta : Keeper_meta_contract.keeper_meta)
      ~(publication_recovery :
          Keeper_publication_recovery_availability.turn_context)
      ~(ctx_snapshot : Keeper_types.working_context)
      ?clock
      ?continuation_channel
      ?gate_context
      ?hitl_resolution
      ?skill_catalog
      ?identity_surface
      ?composition_plan_index
      ?skill_activation_context
      ?(allow_unrecorded_skill_surface = false)
      ?turn_ctx_cell
      ()
  =
  let descriptors = Keeper_tool_descriptor.model_visible_descriptors () in
  make_tool_bundle_for_descriptors_with_policy
    ~config
    ~meta
    ~publication_recovery
    ~ctx_snapshot
    ?clock
    ?continuation_channel
    ?gate_context
    ?hitl_resolution
    ?skill_catalog
    ?identity_surface
    ?composition_plan_index
    ?skill_activation_context
    ~allow_unrecorded_skill_surface
    ?turn_ctx_cell
    ~descriptors
    ()
;;

module For_testing = struct
  let make_tool_bundle
        ~config
        ~meta
        ~publication_recovery
        ~ctx_snapshot
        ?clock
        ?continuation_channel
        ?gate_context
        ?hitl_resolution
        ?skill_catalog
        ?turn_ctx_cell
        ()
    =
    make_tool_bundle_with_policy
      ~config
      ~meta
      ~publication_recovery
      ~ctx_snapshot
      ?clock
      ?continuation_channel
      ?gate_context
      ?hitl_resolution
      ?skill_catalog
      ~allow_unrecorded_skill_surface:true
      ?turn_ctx_cell
      ()
  ;;

  let make_tools
        ~config
        ~meta
        ~publication_recovery
        ~ctx_snapshot
        ?clock
        ?skill_catalog
        ?turn_ctx_cell
        ()
    =
    (make_tool_bundle
       ~config
       ~meta
       ~publication_recovery
       ~ctx_snapshot
       ?clock
       ?skill_catalog
       ?turn_ctx_cell
       ())
      .tools
  ;;

  let make_tools_for_descriptors
        ~config
        ~meta
        ~publication_recovery
        ~ctx_snapshot
        ~descriptors
        ?skill_catalog
        ()
    =
    (make_tool_bundle_for_descriptors_with_policy
       ~config
       ~meta
       ~publication_recovery
       ~ctx_snapshot
       ~descriptors
       ?skill_catalog
       ~allow_unrecorded_skill_surface:true
       ())
      .tools
  ;;

  let initial_terminal_effect_state = initial_terminal_effect_state

  let terminal_externalization_failure =
    terminal_externalization_failure
  ;;
end
