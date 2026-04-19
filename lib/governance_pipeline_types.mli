(** Governance pipeline types — risk level, decision, capability class. *)

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

val risk_level_to_string : risk_level -> string

val risk_level_to_int : risk_level -> int

(** [max_risk_level l r] returns whichever side is strictly higher on the
    [Low < Medium < High < Critical] ordering; ties resolve to [l]. *)
val max_risk_level : risk_level -> risk_level -> risk_level

type capability_class =
  | External_input
  | Sensitive_access
  | State_modification
