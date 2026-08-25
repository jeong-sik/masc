open Types
open Result_syntax

type turn_outcome =
  | Complete of Types.api_response
  | ToolsExecuted of Agent_types.checkpoint_stage
  | TerminalToolCompleted of Terminal_tool_receipt.t

let unpack_execution_result = function
  | Ok ({ Agent_tools.completed_results; completion } : Agent_tools.execution_report) ->
    completed_results, completion, None
  | Error
      ({ Agent_tools.completed_results; completion; cause } :
        Agent_tools.execution_failure) -> completed_results, completion, Some cause
;;

let outcome ~response completion checkpoint_stage =
  match completion with
  | Agent_tools.Continue_after_batch -> Ok (ToolsExecuted checkpoint_stage)
  | Agent_tools.Terminal_completed invocation ->
    Ok (TerminalToolCompleted { invocation; response; checkpoint_stage })
  | Agent_tools.Terminal_failed { invocation; effect_disposition; detail } ->
    let tool_use_id = Tool_contract.Invocation.tool_use_id invocation in
    (match effect_disposition with
     | Tool_contract.Proven_post_effect ->
       Error
         (Error.Agent
            (Error.TerminalToolEffectFailed
               { tool_use_id
               ; effect_disposition = Error.proven_post_terminal_effect
               ; detail
               }))
     | Tool_contract.Effect_outcome_unknown ->
       Error
         (Error.Agent
            (Error.TerminalToolEffectFailed
               { tool_use_id; effect_disposition = Error.unknown_terminal_effect; detail }))
     | Tool_contract.Proven_pre_effect ->
       Error
         (Error.Internal
            "pre-effect terminal failure crossed the correction-capable boundary"))
;;

let durability_failure ~invocation ~detail =
  match Tool_contract.Invocation.completion invocation with
  | Tool_contract.Continue_after_success -> Error (Error.Internal detail)
  | Tool_contract.Terminal_after_success disposition ->
    let effect_disposition =
      match disposition with
      | Tool_contract.Proven_post_effect -> Error.proven_post_terminal_effect
      | Tool_contract.Proven_pre_effect | Tool_contract.Effect_outcome_unknown ->
        Error.unknown_terminal_effect
    in
    Error
      (Error.Agent
         (Error.TerminalToolDurabilityFailed { invocation; effect_disposition; detail }))
;;

let resume_topology_error detail =
  Error.Internal
    (Execution_agent_scope.error_to_string
       (Execution_agent_scope.Resume_topology_mismatch detail))
;;

let validate_response_tool_uses ~response ~tool_uses =
  let response_tool_uses =
    List.filter
      (function
        | ToolUse _ -> true
        | Text _
        | Thinking _
        | ReasoningDetails _
        | RedactedThinking _
        | ToolResult _
        | Image _
        | Document _
        | Audio _ -> false)
      response.content
  in
  if response.stop_reason <> StopToolUse
  then Error (resume_topology_error "persisted tool response did not stop for tool use")
  else if response_tool_uses <> tool_uses
  then
    Error
      (resume_topology_error
         "persisted provider response ToolUse blocks differ from restored checkpoint")
  else Ok ()
;;

let recovered_report ~response ~turn ~invocations ~tool_results tool_uses =
  let rec recover_results expected_index acc invocations tool_uses tool_results =
    match invocations, tool_uses, tool_results with
    | ( authority :: invocations
      , ToolUse { id; name; input } :: tool_uses
      , ToolResult { tool_use_id; content; outcome; _ } :: tool_results ) ->
      let* () =
        Execution_agent_scope.validate_invocation_authority
          authority
          ~turn
          ~planned_index:expected_index
          ~tool_use_id:id
          ~tool_name:name
          ~input
        |> Result.map_error (fun error ->
          Error.Internal (Execution_agent_scope.error_to_string error))
      in
      if String.equal tool_use_id id
      then
        recover_results
          (expected_index + 1)
          ({ Agent_tools.invocation = authority.invocation
           ; tool_name = authority.tool_name
           ; input = authority.input
           ; content
           ; outcome
           }
           :: acc)
          invocations
          tool_uses
          tool_results
      else
        Error (resume_topology_error "restored ToolResult identity differs from ToolUse")
    | [], [], [] -> Ok (List.rev acc)
    | _ ->
      Error
        (resume_topology_error
           "persisted invocation count differs from restored topology")
  in
  let tool_uses = Nonempty.to_list tool_uses in
  let* () = validate_response_tool_uses ~response ~tool_uses in
  let* completed_results = recover_results 0 [] invocations tool_uses tool_results in
  let persisted_invocations =
    List.map
      (fun (authority : Execution_agent_scope.invocation_authority) ->
         authority.invocation)
      invocations
  in
  let* completion =
    Agent_tools.recovered_batch_completion ~invocations:persisted_invocations tool_results
  in
  Ok Agent_tools.{ completed_results; completion }
;;

let recovered_outcome ~response ~turn ~invocations ~tool_results tool_uses =
  let* report = recovered_report ~response ~turn ~invocations ~tool_results tool_uses in
  outcome ~response report.completion Agent_types.After_tool_results_appended
;;
