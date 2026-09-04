module Policy = Keeper_tool_approval_policy
module Registry = Keeper_tool_approval_registry
module Late = Keeper_late_approval
module Mode = Keeper_tool_approval_mode

type t =
  { pre_tool_use : Agent_core.Hooks.hook
  ; tool_approval : Agent_core.Hooks.tool_approval_callback
  ; composition_plan_index : Keeper_tool_composition_plan_index.t
  }

let create ~registry ~late_approvals ~publish ~redact_text ~clock ~keeper_name ~timeout_sec =
  let composition_plan_index = Keeper_tool_composition_plan_index.create () in
  let pre_tool_use (event : Agent_core.Hooks.hook_event) =
    match event with
    | Agent_core.Hooks.PreToolUse { tool_name; input; _ } -> (
        (* Consulted per call, not captured at gate construction: the stance
           is an operator's live control, and a gate built at boot would pin
           the stance the keeper booted with. *)
        match Mode.resolve (Mode.shared ()) ~keeper_name with
        | Mode.Yolo -> Agent_core.Hooks.Continue
        | Mode.Auto -> (
            match
              Policy.verdict_for
                ~composition_plan_index:(Some composition_plan_index)
                ~tool_name ~input
            with
            | Policy.Run _ -> Agent_core.Hooks.Continue
            | Policy.Ask { because } ->
                Agent_core.Hooks.ElicitToolApproval
                  { question = Policy.question_for ~tool_name ~input
                  ; because
                  }))
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
    (* The arguments as sent, so the operator can judge the call -- but
       redacted first: every other text on this bus was redacted by the
       stream bridge before publish, and the journal keeps what the bus
       carries, so a raw secret here would be a raw secret at rest. *)
    publish
      (Keeper_chat_events.Tool_approval_requested
         { tool_call_id
         ; tool_call_name = request.tool_name
         ; args = redact_text (Yojson.Safe.to_string request.input)
         ; question = redact_text request.prompt.question
         ; because = redact_text request.prompt.because
         });
    let decision, label =
      (* A remembered late answer settles this call before anyone is asked:
         it is the answer to this exact call (same keeper, tool, and
         canonical-args fingerprint), given after the first wait timed out.
         One use consumes it, so the call after this one is asked about as
         usual. *)
      match
        (* The registry's wait runs on this same clock, so ages in the store
           are measured against the same clock family. *)
        Late.take late_approvals ~now:(Eio.Time.now clock) ~keeper_name
          ~tool_name:request.tool_name ~args:request.input ()
      with
      | Some remembered ->
          ( (match remembered with
             | Registry.Approve -> Agent_core.Hooks.Approved
             | Registry.Deny -> Agent_core.Hooks.Denied)
          , (* Set apart from a live answer on the stream, so a reader can
               tell "the operator just answered" from "the operator already
               answered this call". *)
            "remembered_" ^ Registry.decision_to_string remembered )
      | None -> (
          let outcome =
            Registry.await registry ~clock ~keeper_name ~tool_call_id
              ~tool_name:request.tool_name
              ~args:(Yojson.Safe.to_string request.input)
              ~question:request.prompt.question ~because:request.prompt.because
              ~timeout_sec
          in
          match outcome with
          | Registry.Answered Registry.Approve ->
              (Agent_core.Hooks.Approved, Registry.decision_to_string Registry.Approve)
          | Registry.Answered Registry.Deny ->
              (Agent_core.Hooks.Denied, Registry.decision_to_string Registry.Deny)
          | Registry.Timed_out ->
              (* Timing out blocks this call, not the turn: Agent Core turns
                 [Hooks.Timed_out] into a blocked tool result carrying
                 "Tool execution approval timed out" and reports
                 [Continue_after_batch], so the Keeper reads that result and
                 carries on. The ask's description is kept so an operator's
                 late answer is not discarded: it settles the identical call
                 once, whenever that call comes back. *)
              Late.note_timed_out late_approvals ~now:(Eio.Time.now clock)
                ~keeper_name ~tool_call_id
                ~tool_name:request.tool_name ~args:request.input ();
              (Agent_core.Hooks.Timed_out, "timed_out")
          (* Two waits claimed one call id, so neither answer can be trusted to be
             about this call. Denying is the conservative reading: the call the
             operator saw is not provably the call about to run. *)
          | Registry.Displaced -> (Agent_core.Hooks.Denied, "displaced"))
    in
    (* Sent on every path, including the ones where nobody answered, so a pane
       showing the prompt stops showing it. *)
    publish
      (Keeper_chat_events.Tool_approval_settled
         { tool_call_id; outcome = label });
    decision
  in
  { pre_tool_use; tool_approval; composition_plan_index }
