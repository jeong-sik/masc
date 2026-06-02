type risk_level =
  | Low
  | Medium
  | High
  | Critical

type governance_decision = {
  tool_name : string;
  risk : risk_level;
  action : [ `Allow | `Require_confirm of string | `Deny of string ];
  trace_id : string;
}

let risk_level_to_string = function
  | Low -> "low"
  | Medium -> "medium"
  | High -> "high"
  | Critical -> "critical"

let risk_level_to_int = function
  | Low -> 0
  | Medium -> 1
  | High -> 2
  | Critical -> 3

let max_risk_level left right =
  if risk_level_to_int left >= risk_level_to_int right then left else right

type capability_class =
  | External_input
  | Sensitive_access
  | State_modification
