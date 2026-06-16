type horizon =
  | Short_term
  | Mid_term
  | Long_term

type memory_kind =
  | User_profile
  | Feedback_rule
  | Project_context
  | External_ref

type memory_row = {
  id : string;
  kind : memory_kind;
  horizon : horizon;
  source_trace_id : string;
  text : string;
  embedding : float array option;
  ts_unix : float;
}

type outbox_status =
  | Pending
  | In_progress
  | Succeeded of { pgvector : bool; neo4j : bool }
  | Failed of string

type outbox_event = {
  event_id : string;
  retry_count : int;
  status : outbox_status;
  payload : memory_row;
}

type proposal_action =
  | Proposal_merge of { target_ids : string list; merged_text : string }
  | Proposal_delete of { target_id : string; reason : string }

type consolidation_proposal = {
  proposal_id : string;
  created_at : float;
  action : proposal_action;
  rationale : string;
  approved : bool;
}
