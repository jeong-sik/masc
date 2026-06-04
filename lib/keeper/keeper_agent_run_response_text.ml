(** Response text and [STATE] snapshot finalization for keeper agent runs. *)

type finalized = {
  state_snapshot : Keeper_memory_policy.keeper_state_snapshot;
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

let state_snapshot ~keeper_name ~goal ~actual_keeper_tool_names
      ~stop_reason ~raw_response_text
  =
  match Keeper_memory_policy.parse_state_snapshot_from_reply raw_response_text with
  | Some snapshot -> snapshot
  | None ->
    let stop_reason_str = stop_reason_label stop_reason in
    let synth =
      Keeper_memory_policy.synthesize_state_from_run_result
        ~goal
        ~tools_used:actual_keeper_tool_names
        ~stop_reason:stop_reason_str
        ~response_text:raw_response_text
    in
    Log.Keeper.info
      "keeper:%s [STATE] missing, synthesized from %d tools (stop=%s)"
      keeper_name
      (List.length actual_keeper_tool_names)
      stop_reason_str;
    synth
;;

let response_text ~state_snapshot ~raw_response_text =
  match
    Keeper_text_processing.state_snapshot_reply_fallback (Some state_snapshot)
  with
  | Some fallback ->
    Keeper_text_processing.user_visible_reply_text ~fallback raw_response_text
  | None -> Keeper_text_processing.user_visible_reply_text raw_response_text
;;

let finalize ~keeper_name ~goal ~actual_keeper_tool_names
      ~stop_reason ~raw_response_text
  =
  let state_snapshot =
    state_snapshot
      ~keeper_name
      ~goal
      ~actual_keeper_tool_names
      ~stop_reason
      ~raw_response_text
  in
  let response_text = response_text ~state_snapshot ~raw_response_text in
  { state_snapshot; response_text }
;;
