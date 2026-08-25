module Policy = Keeper_tool_approval_policy
module Registry = Keeper_tool_approval_registry
module Mode = Keeper_tool_approval_mode

type t =
  { pre_tool_use : Agent_core.Hooks.hook
  ; tool_approval : Agent_core.Hooks.tool_approval_callback
  }

let create ~registry ~publish ~clock ~keeper_name ~timeout_sec =
  let pre_tool_use (event : Agent_core.Hooks.hook_event) =
    match event with
    | Agent_core.Hooks.PreToolUse { tool_name; input; _ } -> (
        (* Consulted per call, not captured at gate construction: the stance
           is an operator's live control, and a gate built at boot would pin
           the stance the keeper booted with. *)
        match Mode.resolve (Mode.shared ()) ~keeper_name with
        | Mode.Yolo -> Agent_core.Hooks.Continue
        | Mode.Auto -> (
            let verdict =
              match
                Keeper_tool_approval_folded.verdict_for_folded ~tool_name ~input
              with
              | Some folded -> folded
              | None -> Policy.verdict_for ~tool_name ~input
            in
            match verdict with
            | Policy.Run _ -> Agent_core.Hooks.Continue
            | Policy.Ask _ ->
                Agent_core.Hooks.ElicitToolApproval
                  { question = Policy.question_for ~tool_name ~input }))
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
    publish
      (Keeper_chat_events.Tool_approval_requested
         { tool_call_id
         ; tool_call_name = request.tool_name
         ; args = Yojson.Safe.to_string request.input
         ; question = request.prompt.question
         });
    let outcome =
      Registry.await registry ~clock ~keeper_name ~tool_call_id
        ~tool_name:request.tool_name
        ~args:(Yojson.Safe.to_string request.input)
        ~question:request.prompt.question ~timeout_sec
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
    publish
      (Keeper_chat_events.Tool_approval_settled
         { tool_call_id; outcome = label });
    decision
  in
  { pre_tool_use; tool_approval }
