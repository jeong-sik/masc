(** Governance V2 types *)


let ( let* ) = Result.bind

type risk_class =
  | Low
  | High

type brief_stance =
  | Support
  | Oppose
  | Neutral

type case_status =
  | Pending_ruling
  | Ready_auto_execute
  | Needs_human_gate
  | Executed
  | Blocked
  | Closed

type order_status =
  | Queued_auto
  | Needs_human_gate_order
  | Auto_executed
  | Done
  | Denied
  | Blocked_order

type action_request = {
  action_type : string;
  target_type : string option;
  target_id : string option;
  payload : Yojson.Safe.t option;
}

type petition = {
  id : string;
  case_id : string;
  title : string;
  normalized_key : string;
  origin : string;
  subject_type : string;
  risk_class : risk_class;
  requested_action : action_request option;
  source_refs : string list;
  created_by : string;
  created_at : float;
}

type case_brief = {
  id : string;
  author : string;
  stance : brief_stance;
  summary : string;
  evidence_refs : string list;
  created_at : float;
}

type case_record = {
  id : string;
  petition_ids : string list;
  title : string;
  normalized_key : string;
  origin : string;
  subject_type : string;
  risk_class : risk_class;
  status : case_status;
  created_at : float;
  updated_at : float;
  requested_action : action_request option;
  source_refs : string list;
  briefs : case_brief list;
}

type ruling = {
  id : string;
  case_id : string;
  status : string;
  summary : string;
  confidence : float;
  provenance : string;
  generated_at : float;
  expires_at : float option;
  keeper_name : string;
  model_used : string option;
  risk_class : risk_class;
  evidence_refs : string list;
  recommended_action : action_request option;
  auto_execution_state : string;
}

type execution_order = {
  id : string;
  case_id : string;
  status : order_status;
  risk_class : risk_class;
  action_request : action_request option;
  created_at : float;
  updated_at : float;
  execution_ref : string option;
  result_summary : string option;
  actor : string option;
}

type petition_submit_result = {
  petition : petition;
  case_ : case_record;
  merged : bool;
}

type case_bundle = {
  case_ : case_record;
  petitions : petition list;
  ruling : ruling option;
  execution_order : execution_order option;
}

