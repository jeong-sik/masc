let record_require_tool_use_violation ~keeper_name ~has_current_task ~contract_status =
  Keeper_tool_disclosure.record_require_tool_use_violation
    ~keeper_name
    ~has_current_task
    ~contract_status:
      (Keeper_execution_receipt.tool_contract_result_to_string contract_status)
;;

let signal_label actionable_signal_kind =
  Keeper_contract_classifier.actionable_signal_label actionable_signal_kind
;;

let inc_contract_violation ~keeper_name ~kind ~signal =
  Prometheus.inc_counter
    Keeper_metrics.metric_keeper_contract_violations
    ~labels:[ "keeper_name", keeper_name; "kind", kind; "signal", signal ]
    ()
;;

let record_passive
      ~keeper_name
      ~has_current_task
      ~contract_status
      ~actionable_signal_kind
      ~turns
      ~actual_keeper_tool_names
      ~reason
  =
  record_require_tool_use_violation
    ~keeper_name
    ~has_current_task
    ~contract_status;
  let signal_label = signal_label actionable_signal_kind in
  Log.Keeper.error
    "keeper:%s required tool contract violated (turn=%d, tools=%d, signal=%s). \
     Rejecting no-op/passive actionable turn. Reason: %s"
    keeper_name
    turns
    (List.length actual_keeper_tool_names)
    signal_label
    reason;
  inc_contract_violation ~keeper_name ~kind:"passive" ~signal:signal_label
;;

let completion_contract_to_string = function
  | Keeper_tool_disclosure.Allow_text_or_tool -> "Allow_text_or_tool"
  | Keeper_tool_disclosure.Require_tool_use -> "Require_tool_use"
;;

let record_text_only
      ~keeper_name
      ~has_current_task
      ~contract_status
      ~effective_completion_contract
      ~actionable_signal_kind
      ~turns
      ~actual_keeper_tool_names
      ~reason
  =
  record_require_tool_use_violation
    ~keeper_name
    ~has_current_task
    ~contract_status;
  let contract_str = completion_contract_to_string effective_completion_contract in
  let signal_label = signal_label actionable_signal_kind in
  Log.Keeper.error
    "keeper:%s required tool contract violated (turn=%d, tools=%d, contract=%s, \
     signal=%s). Rejecting text-only response. Reason: %s"
    keeper_name
    turns
    (List.length actual_keeper_tool_names)
    contract_str
    signal_label
    reason;
  inc_contract_violation ~keeper_name ~kind:"text_only" ~signal:signal_label
;;
