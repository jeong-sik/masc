module Policy = Keeper_tool_approval_policy
module Registry = Keeper_tool_approval_registry

type t =
  { pre_tool_use : Agent_core.Hooks.hook
  ; tool_approval : Agent_core.Hooks.tool_approval_callback
  }

let create ~registry ~events ~clock ~keeper_name ~timeout_sec =
  let pre_tool_use (event : Agent_core.Hooks.hook_event) =
    match event with
    | Agent_core.Hooks.PreToolUse { tool_name; input; _ } -> (
        match Policy.verdict_for ~tool_name ~input with
        | Policy.Run _ -> Agent_core.Hooks.Continue
        | Policy.Ask _ ->
            Agent_core.Hooks.ElicitToolApproval
              { question = Policy.question_for ~tool_name ~input })
    (* This hook is installed at pre_tool_use only, so no other stage reaches
       it. Named rather than left to a catch-all: a stage added later should
       stop the build here and be decided on. *)
    | Agent_core.Hooks.BeforeTurn _
    | Agent_core.Hooks.BeforeTurnParams _
    | Agent_core.Hooks.AfterTurn _
    | Agent_core.Hooks.PostToolUse _
    | Agent_core.Hooks.PostToolUseFailure _
    | Agent_core.Hooks.OnToolError _
    | Agent_core.Hooks.OnError _
    | Agent_core.Hooks.OnStop _ ->
        Agent_core.Hooks.Continue
  in
  let tool_approval (request : Agent_core.Hooks.tool_approval_request) =
    let tool_call_id =
      Agent_core.Tool_contract.Invocation.tool_use_id request.invocation
    in
    Keeper_chat_events.publish events
      (Keeper_chat_events.Tool_approval_requested
         { tool_call_id
         ; tool_call_name = request.tool_name
         ; args = Yojson.Safe.to_string request.input
         ; question = request.prompt.question
         });
    let outcome =
      Registry.await registry ~clock ~keeper_name ~tool_call_id ~timeout_sec
    in
    let decision, label =
      match outcome with
      | Registry.Answered Registry.Approve ->
          (Agent_core.Hooks.Approved, Registry.decision_to_string Registry.Approve)
      | Registry.Answered Registry.Deny ->
          (Agent_core.Hooks.Denied, Registry.decision_to_string Registry.Deny)
      | Registry.Timed_out -> (Agent_core.Hooks.Timed_out, "timed_out")
      (* Two waits claimed one call id, so neither answer can be trusted to be
         about this call. Denying is the conservative reading: the call the
         operator saw is not provably the call about to run. *)
      | Registry.Displaced -> (Agent_core.Hooks.Denied, "displaced")
    in
    (* Sent on every path, including the ones where nobody answered, so a pane
       showing the prompt stops showing it. *)
    Keeper_chat_events.publish events
      (Keeper_chat_events.Tool_approval_settled
         { tool_call_id; outcome = label });
    decision
  in
  { pre_tool_use; tool_approval }
