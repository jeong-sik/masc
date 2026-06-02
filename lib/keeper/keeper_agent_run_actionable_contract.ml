type analysis =
  { actionable_signal_kind : Keeper_contract_classifier.actionable_signal
  ; actionable_signal_context : Keeper_contract_classifier.actionable_signal_context
  ; violation_reason : string option
  }

(* A stay_silent call carries a typed no-work proof when its tool_call_detail
   records a [No_progress] typed_outcome. The handler emits this only for a
   recognized [no_work_reason] (Keeper_tool_in_process_runtime.handle_stay_silent),
   and the PostToolUse hook threads it onto the detail. This is the typed escape
   from the stay_silent constraint-trap: bare silence still has no proof. *)
let stay_silent_no_work_proof_present
      (tool_calls : Keeper_agent_result.tool_call_detail list)
  : bool
  =
  List.exists
    (fun (detail : Keeper_agent_result.tool_call_detail) ->
       Keeper_tool_progress.is_stay_silent_tool_name detail.tool_name
       &&
       match detail.typed_outcome with
       | Some (Keeper_tool_outcome.No_progress _) -> true
       | Some (Keeper_tool_outcome.Progress | Keeper_tool_outcome.Error _) | None ->
         false)
    tool_calls
;;

let analyze
      ~world_observation
      ~allowed_tool_names
      ~turn_affordances
      ~progress_keeper_tool_names
      ~no_progress_success_tool_names
      ~claim_context_allowed
      ~tool_calls
  =
  let actionable_signal_kind : Keeper_contract_classifier.actionable_signal =
    match world_observation with
    | None -> Keeper_contract_classifier.No_actionable_signal
    | Some observation ->
      observation
      |> Keeper_contract_classifier.of_keeper_world_observation
      |> Keeper_contract_classifier.classify_actionable_signal_for_tools
           ~allowed_tool_names
  in
  let tool_gate_required =
    Keeper_agent_tool_surface.turn_affordances_require_tool_gate_with_allowed
      ~claim_context_allowed
      ~allowed_tool_names
      turn_affordances
  in
  let actionable_signal_context =
    Keeper_contract_classifier.make_actionable_signal_context
      ~tool_gate_required
      ~actionable_signal:actionable_signal_kind
  in
  let violation_reason =
    if
      Keeper_contract_classifier.is_actionable_signal_context
        actionable_signal_context
      && progress_keeper_tool_names = []
      && no_progress_success_tool_names <> []
    then
      Some
        (Printf.sprintf
           "actionable keeper context (%s) was present, but the model only \
            used idempotent setup tools that made no execution progress: %s"
           (Keeper_contract_classifier.actionable_signal_context_label
              actionable_signal_context)
           (String.concat ", " no_progress_success_tool_names))
    else
      Keeper_tool_progress.actionable_tool_contract_violation_reason
        ~stay_silent_has_no_work_proof:
          (stay_silent_no_work_proof_present tool_calls)
        ~claim_context_allowed
        ~actionable_signal_context
        ~tool_names:progress_keeper_tool_names
        ()
  in
  { actionable_signal_kind; actionable_signal_context; violation_reason }
;;
