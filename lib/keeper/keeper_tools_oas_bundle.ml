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

let terminal_externalization_failure
      state
      ({ message } : Tool_bridge.externalization_error)
  =
  match state with
  | Keeper_tools_oas.Terminal_effect_completed ->
    Some
      { Keeper_tools_oas.failure_class = Tool_result.Runtime_failure
      ; effect_disposition = Tool_result.Proven_post_effect
      ; diagnostic = "tool output artifact storage failed: " ^ message
      }
  | ( Keeper_tools_oas.Terminal_effect_open
    | Keeper_tools_oas.Deferred_tool_result
    | Keeper_tools_oas.External_effect_deferred
    | Keeper_tools_oas.Terminal_effect_failed _ ) ->
    None
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
      let outcome =
        Keeper_gate_replay.replay_approved_effect
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
      Some Keeper_tools_oas.{ approval_id; outcome }
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
  (* Every descriptor-declared model tool is materialized. The turn hook sends
     this exact list to OAS without per-Keeper or per-turn reduction. *)
  let model_visible_descriptors = Keeper_tool_descriptor.model_visible_descriptors () in
  (* The bundle lives for exactly one Agent run. Its typed tool-boundary
     state is request-scoped and observed by the OAS tool-boundary probe only
     after the whole tool batch and checkpoint sink have completed. A generic
     deferred tool transition retains the existing durable-stimulus checkpoint;
     only a typed external-effect defer stops the provider loop until Gate's
     durable resolution wakes a later turn. A terminal completion supersedes a
     defer in the same batch; a proven terminal failure dominates every state
     regardless of callback order. Failure is sticky so its first diagnostic
     remains authoritative. *)
  let terminal_effect_state = Atomic.make Terminal_effect_open in
  let mark_deferred_tool_result () =
    ignore
      (Atomic.compare_and_set
         terminal_effect_state
         Terminal_effect_open
         Deferred_tool_result)
  in
  let mark_external_effect_deferred () =
    (* A generic deferred transition may precede the Gate result in one OAS
       batch. The external effect owns the user-facing terminal projection, so
       it must promote that generic state rather than being hidden by it. *)
    let rec transition () =
      match Atomic.get terminal_effect_state with
      | External_effect_deferred
      | Terminal_effect_completed
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
  let mark_terminal_effect_completed () =
    let rec transition () =
      match Atomic.get terminal_effect_state with
      | Terminal_effect_completed | Terminal_effect_failed _ -> ()
      | ( Terminal_effect_open
        | Deferred_tool_result
        | External_effect_deferred ) as current ->
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
        | Deferred_tool_result
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
         let on_completed, on_failed, on_externalization_error =
           match completion_boundary_of_runtime_handler descriptor.runtime_handler with
           | Terminal_effect ->
             ( Some mark_terminal_effect_completed
             , Some mark_terminal_effect_failed
             , Some mark_completed_terminal_externalization_failed )
           | Continue_after_success -> None, None, None
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
             Tool_bridge.oas_tool_of_masc_with_execution_env
               ~base_path:config.base_path
               ~model_projection:descriptor.model_output_projection
               ?on_externalization_error
               ~externalization_error_recoverable:descriptor.policy.retryable
               ~name:model_name
               ~description:descriptor.description
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
  ; gate_replay_delivery
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

  let terminal_externalization_failure =
    terminal_externalization_failure
  ;;
end
