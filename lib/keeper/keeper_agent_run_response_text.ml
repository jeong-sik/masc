(** Response text and [STATE] snapshot finalization for keeper agent runs. *)

type finalized = {
  state_snapshot : Keeper_memory_policy.keeper_state_snapshot;
  state_snapshot_source : string;
  response_text : string;
}

let stop_reason_label = function
  | Runtime_agent.Completed -> "completed"
  | Runtime_agent.TurnBudgetExhausted _ -> "budget_exhausted"
  | Runtime_agent.MutationBoundaryReached { tool_name; _ } ->
    (match tool_name with
     | Some tool -> Printf.sprintf "mutation_boundary(%s)" tool
     | None -> "mutation_boundary")
;;

let state_snapshot ~reported_state_snapshot ~keeper_name ~goal ~actual_keeper_tool_names
      ~stop_reason ~raw_response_text
      ()
  =
  match reported_state_snapshot with
  | Some snapshot -> (snapshot, "model_structured_state_tool")
  | None ->
    (match
       Keeper_memory_policy.parse_structured_state_snapshot_from_reply
         raw_response_text
     with
     | Some snapshot -> (snapshot, "model_structured_state")
     | None ->
       (match Keeper_memory_policy.parse_state_snapshot_from_reply raw_response_text with
        | Some snapshot -> (snapshot, "model_state_block")
        | None ->
          let stop_reason_str = stop_reason_label stop_reason in
          let synth =
            Keeper_memory_policy.synthesize_state_from_run_result
              ~goal
              ~tools_used:actual_keeper_tool_names
              ~stop_reason:stop_reason_str
              ~response_text:raw_response_text
          in
          Log.Keeper.info ~keeper_name:keeper_name
            "state metadata missing, synthesized from %d tools (stop=%s)"
            (List.length actual_keeper_tool_names)
            stop_reason_str;
          (synth, "synthesized")))
;;

let response_text ~state_snapshot ~state_snapshot_source ~raw_response_text =
  let fallback =
    match
      Keeper_text_processing.state_snapshot_reply_fallback (Some state_snapshot)
    with
    | Some _ as fallback -> fallback
    | None when String.equal state_snapshot_source "model_structured_state" ->
      Some "State updated."
    | None -> None
  in
  if String.equal state_snapshot_source "model_structured_state" then
    Keeper_text_processing.user_visible_reply_text ?fallback ""
  else
    match fallback with
    | Some fallback ->
      Keeper_text_processing.user_visible_reply_text ~fallback raw_response_text
    | None -> Keeper_text_processing.user_visible_reply_text raw_response_text
;;

let finalize ~reported_state_snapshot ~keeper_name ~goal ~actual_keeper_tool_names
      ~stop_reason ~raw_response_text
      ()
  =
  let state_snapshot, state_snapshot_source =
    state_snapshot
      ~reported_state_snapshot
      ~keeper_name
      ~goal
      ~actual_keeper_tool_names
      ~stop_reason
      ~raw_response_text
      ()
  in
  let response_text =
    response_text ~state_snapshot ~state_snapshot_source ~raw_response_text
  in
  { state_snapshot; state_snapshot_source; response_text }
;;
