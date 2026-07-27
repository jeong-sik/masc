(** Tool bundle assembly for keeper OAS execution.

    [make_tool_bundle] builds the full [tool_bundle] from each descriptor's
    single explicit Keeper-model projection, and [make_tools] is the
    convenience wrapper returning only [.tools].

    Extracted from [Keeper_tools_oas_handler] to keep that module
    focused on per-tool handler construction. *)

open Keeper_tools_oas

type completion_boundary =
  | Continue_after_success
  | Terminal_effect

(* A connected-surface post is the reply deliverable for this Keeper turn.
   Classify it from the closed runtime-handler ADT: no tool-name comparison,
   payload inspection, retry count, or elapsed-time threshold participates. *)
let completion_boundary_of_runtime_handler = function
  | Keeper_tool_descriptor.Tool_surface_post -> Terminal_effect
  | _ -> Continue_after_success
;;

let task_state_hint ~(config : Workspace.config) ~(meta : Keeper_meta_contract.keeper_meta) : string =
  let meta = Keeper_current_task_reconcile.sync_current_task_id_from_backlog ~config meta in
  match meta.current_task_id with
  | None ->
    "No task currently assigned. Use keeper_task_claim or keeper_tasks_list to find one."
  | Some tid ->
    let task_id = Keeper_id.Task_id.to_string tid in
    (match Workspace_backlog.read_backlog_r config with
     | Error _ -> Printf.sprintf "Current task: %s (status unavailable)" task_id
     | Ok backlog ->
       (match List.find_opt (fun (t : Masc_domain.task) -> t.id = task_id) backlog.tasks with
        | None -> Printf.sprintf "Current task: %s (not found in backlog)" task_id
        | Some task ->
          let status = Masc_domain.task_status_to_string task.task_status in
          let hint = Workspace_task_classify.next_actions_hint task.task_status in
          Printf.sprintf "Current task: %s, status=%s%s" task_id status hint))
;;

let make_tool_bundle
      ~(config : Workspace.config)
      ~(meta : Keeper_meta_contract.keeper_meta)
      ~(publication_recovery :
          Keeper_publication_recovery_availability.turn_context)
      ~(ctx_snapshot : Keeper_types.working_context)
      ?search_fn
      ?clock
      ?continuation_channel
      ?gate_context
      ?hitl_resolution
      ()
  : tool_bundle
  =
  (* PR-3b (#11611 part 1): replace eager [Keeper_turn_sandbox_runtime]
     instances with a factory.  in_playground/cwd are unknown at
     turn-start, so the factory defers
     [Keeper_sandbox_runner.effective_sandbox_profile] resolution until
     each tool call site that already knows its [cwd]. *)
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
     replay whose re-derived input no longer matches its approval falls back
     to an ordinary Gate request, and a request without causal context cannot
     be summarized, which stalls the FIFO drain for every later approval
     (#25966). *)
  let () =
    match hitl_resolution, gate_grant with
    | ( Some
          { Keeper_event_queue.approval_id
          ; decision = Keeper_event_queue.Hitl_approved
          ; _
          }
      , Some grant ) ->
      (match
         Keeper_gate_replay.replay_approved_write
           ~config
           ~meta
           ~publication_recovery
           ~turn_sandbox_factory
           ?continuation_channel
           ?gate_context:gate_context_provider
           ~grant
           ~approval_id
           ()
       with
       | Keeper_gate_replay.Not_applicable -> ()
       | Keeper_gate_replay.Applied _ as outcome ->
         Log.Keeper.info
           "gate replay approval=%s %s"
           approval_id
           (Keeper_gate_replay.outcome_to_string outcome)
       | Keeper_gate_replay.Failed _ as outcome ->
         Log.Keeper.error
           "gate replay approval=%s %s"
           approval_id
           (Keeper_gate_replay.outcome_to_string outcome))
    | _ -> ()
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
  (* Every descriptor-declared model tool is materialized. The turn hook sends
     this exact list to OAS without per-Keeper or per-turn reduction. *)
  let model_visible_descriptors = Keeper_tool_descriptor.model_visible_descriptors () in
  (* The bundle lives for exactly one Agent run. Its typed tool-boundary
     state is request-scoped and observed by the OAS tool-boundary probe only
     after the whole tool batch and checkpoint sink have completed. Deferred
     external effects stop the provider loop until their durable resolution
     wakes a later turn. A terminal completion supersedes a defer in the same
     batch; a proven terminal failure dominates every state regardless of
     callback order. Failure is sticky so its first diagnostic remains
     authoritative. *)
  let terminal_effect_state = Atomic.make Terminal_effect_open in
  let mark_external_effect_deferred () =
    ignore
      (Atomic.compare_and_set
         terminal_effect_state
         Terminal_effect_open
         External_effect_deferred)
  in
  let mark_terminal_effect_completed () =
    let rec transition () =
      match Atomic.get terminal_effect_state with
      | Terminal_effect_completed | Terminal_effect_failed _ -> ()
      | (Terminal_effect_open | External_effect_deferred) as current ->
        if
          not
            (Atomic.compare_and_set
               terminal_effect_state
               current
               Terminal_effect_completed)
        then transition ()
    in
    transition ()
  in
  let mark_terminal_effect_failed failure =
    let rec transition () =
      match Atomic.get terminal_effect_state with
      | Terminal_effect_failed _ -> ()
      | ( Terminal_effect_open
        | External_effect_deferred
        | Terminal_effect_completed ) as current ->
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
  (* The handler dispatches with
     [~name:descriptor.internal_name] so all telemetry SSOT remains internal;
     exactly one projected Tool.schema.name is model-visible.
     [descriptor.translate] reshapes the LLM's payload before dispatch;
     [descriptor.input_schema] provides the LLM-facing schema. *)
  let descriptor_tools =
    List.concat_map
      (fun (descriptor : Keeper_tool_descriptor.t) ->
         let internal = descriptor.internal_name in
         let on_completed, on_failed =
           match completion_boundary_of_runtime_handler descriptor.runtime_handler with
           | Terminal_effect ->
             Some mark_terminal_effect_completed, Some mark_terminal_effect_failed
           | Continue_after_success -> None, None
         in
         Keeper_tool_descriptor.keeper_model_names descriptor
         |> List.map (fun model_name ->
             let h =
               Keeper_tools_oas_handler.make_keeper_tool_handler
                 ~name:internal
                 ~input_schema:descriptor.input_schema
                 ~config
                 ~meta
                 ~publication_recovery
                 ~ctx_snapshot
                   ?turn_sandbox_factory
                 ?search_fn
                 ?clock
                 ?continuation_channel
                 ?gate_context:gate_context_provider
                 ?gate_grant
                 ?record_gate_result
                 ?on_completed
                 ~on_deferred:mark_external_effect_deferred
                 ?on_failed
                 ~pre_validate_input:(fun input ->
                   match
                     Keeper_tool_descriptor_resolution.validate_public_input_for_tool_call
                       ~tool_name:model_name
                       ~input
                   with
                 | Some result -> result
                 | None -> Ok input)
                 ~translate_input:descriptor.translate
                 ~validate_translated_input:descriptor.validate_translated_input
                 ()
             in
             let description =
               match descriptor.model_description_projection with
               | Keeper_tool_descriptor.Static_description -> descriptor.description
               | Keeper_tool_descriptor.Current_task_state ->
                 descriptor.description ^ "\n\n" ^ task_state_hint ~config ~meta
             in
             Tool_bridge.oas_tool_of_masc_with_execution_env
               ~name:model_name
               ~description
               ~input_schema:descriptor.input_schema
               (fun execution_env input ->
                 h
                   ?oas_invocation:
                     (Agent_sdk.Tool.Execution_env.invocation execution_env)
                   input)))
      model_visible_descriptors
  in
  { tools = descriptor_tools
  ; cleanup =
      (fun () ->
        Option.iter Keeper_sandbox_factory.cleanup turn_sandbox_factory)
  ; terminal_effect_state = (fun () -> Atomic.get terminal_effect_state)
  }
;;

let make_tools
      ~(config : Workspace.config)
      ~(meta : Keeper_meta_contract.keeper_meta)
      ~(publication_recovery :
          Keeper_publication_recovery_availability.turn_context)
      ~(ctx_snapshot : Keeper_types.working_context)
      ?search_fn
      ?clock
      ()
  : Agent_sdk.Tool.t list
  =
  (make_tool_bundle
     ~config
     ~meta
     ~publication_recovery
     ~ctx_snapshot
     ?search_fn
     ?clock
     ())
    .tools
;;

module For_testing = struct
  let is_terminal_effect_handler handler =
    match completion_boundary_of_runtime_handler handler with
    | Terminal_effect -> true
    | Continue_after_success -> false
  ;;
end
