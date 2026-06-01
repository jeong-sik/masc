type analysis =
  { actionable_signal_kind : Keeper_contract_classifier.actionable_signal
  ; actionable_signal_context : Keeper_contract_classifier.actionable_signal_context
  ; violation_reason : string option
  }

let analyze
      ~world_observation
      ~allowed_tool_names
      ~turn_affordances
      ~progress_keeper_tool_names
      ~no_progress_success_tool_names
      ~claim_context_allowed
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
  ignore turn_affordances;
  let actionable_signal_context =
    Keeper_contract_classifier.make_actionable_signal_context
      ~actionable_signal:actionable_signal_kind
  in
  let violation_reason =
    ignore progress_keeper_tool_names;
    ignore no_progress_success_tool_names;
    ignore claim_context_allowed;
    None
  in
  { actionable_signal_kind; actionable_signal_context; violation_reason }
;;
