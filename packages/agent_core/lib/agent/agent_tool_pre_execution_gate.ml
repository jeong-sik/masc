type settlement =
  | Admit
  | Block of string
  | Reject of
      { stage : Hooks.hook_stage
      ; detail : string
      }

type scheduled_settlement =
  | Run_admitted
  | Return_outcome of Agent_tool_execution_types.scheduled_tool_outcome

let blocked_tool_result ~invocation ~tool_name ~input ~content =
  { Agent_tool_execution_types.invocation
  ; tool_name
  ; input
  ; content
  ; outcome =
      Types.Tool_failed
        { failure_kind = Types.Non_retryable_tool_error
        ; error_class = Some Types.Deterministic
        }
  }
;;

let publish_approval
      ?correlation_id
      ?run_id
      ~event_bus
      ~agent_name
      (request : Hooks.tool_approval_request)
      approval
  =
  match event_bus with
  | Some bus ->
    Event_bus.publish
      bus
      (Event_bus.mk_event
         ?correlation_id
         ?run_id
         (Event_bus.ToolApprovalCompleted
            { agent_name
            ; invocation = request.invocation
            ; tool_name = request.tool_name
            ; approval
            }))
  | None -> ()
;;

let settle
      ?tool_approval
      ?correlation_id
      ?run_id
      ~event_bus
      ~agent_name
      ~invocation
      ~tool_name
      ~input
  = function
  | Hooks.Continue -> Admit
  | Hooks.Block reason -> Block reason
  | Hooks.HookFailed { stage; detail } -> Reject { stage; detail }
  | Hooks.ElicitToolApproval prompt ->
    (match tool_approval with
     | None ->
       Reject
         { stage = Hooks.Pre_tool_use
         ; detail =
             "ElicitToolApproval at pre_tool_use requires the configured tool_approval \
              callback; no tool invocation was opened"
         }
     | Some callback ->
       let request = { Hooks.prompt; invocation; tool_name; input } in
       (match callback request with
        | exception exception_ ->
          Llm_provider.Reserved_exn.reraise_if_reserved exception_;
          Reject
            { stage = Hooks.Pre_tool_use
            ; detail =
                "tool_approval callback raised before tool execution: "
                ^ Printexc.to_string exception_
            }
        | approval ->
          publish_approval ?correlation_id ?run_id ~event_bus ~agent_name request approval;
          (match approval with
           | Hooks.Approved -> Admit
           | Hooks.Denied -> Block "Tool execution was denied by the caller"
           | Hooks.Timed_out -> Block "Tool execution approval timed out")))
  | (Hooks.AdjustParams _ | Hooks.ElicitInput _ | Hooks.Nudge _) as decision ->
    Reject
      { stage = Hooks.Pre_tool_use
      ; detail =
          Printf.sprintf
            "illegal decision %s escaped hook validation"
            (Hooks.decision_kind_to_string (Hooks.classify_decision decision))
      }
;;

let settle_existing_block
      durable
      (result : Agent_tool_execution_types.tool_execution_result)
  =
  Execution_agent_scope.settle_unattempted_invocation
    durable
    ~content:result.content
    ~outcome:result.outcome
  |> Result.map (fun () -> result)
;;

let scheduled_settlement ?settle_blocked ~index ~invocation ~tool_name ~input = function
  | Admit -> Run_admitted
  | Block reason ->
    let result = blocked_tool_result ~invocation ~tool_name ~input ~content:reason in
    let result =
      match settle_blocked with
      | None -> result
      | Some settle -> settle result
    in
    Return_outcome
      { index
      ; completed_result = Some result
      ; completion = Agent_tool_execution_types.Continue_after_batch
      ; failure = None
      }
  | Reject { stage; detail } ->
    Return_outcome
      { index
      ; completed_result = None
      ; completion = Agent_tool_execution_types.Continue_after_batch
      ; failure =
          Some
            (Agent_tool_execution_types.Hook_failure
               (Agent_tool_execution_types.Hook_execution_failed
                  { hook_name = "pre_tool_use"; stage; tool_name; invocation; detail }))
      }
;;
