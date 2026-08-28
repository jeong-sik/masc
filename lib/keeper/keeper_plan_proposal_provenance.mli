(** Exact retained-producer verification for stored Assembler proposals. *)

type contradiction =
  | Wrong_lane of Exact_lane_run_registry.lane
  | Run_not_completed
  | Run_cancelled
  | Run_failed of
      { code : string
      ; detail : string
      }
  | Output_not_object
  | Output_missing_proposal_id
  | Output_invalid_proposal_id of Yojson.Safe.t
  | Output_proposal_id_mismatch of
      { observed : Keeper_plan_proposal.Proposal_id.t
      ; expected : Keeper_plan_proposal.Proposal_id.t
      }

type verification =
  | Retained_match
  | Retained_unconfirmed
  | Not_retained
  | Retained_contradiction of contradiction

val verify :
  registry:Exact_lane_run_registry.t ->
  assembler_run_id:Keeper_plan_proposal_execution_request.Assembler_run_id.t ->
  proposal_id:Keeper_plan_proposal.Proposal_id.t ->
  verification

val status_to_string : verification -> string
val to_yojson : verification -> Yojson.Safe.t

val attach_to_result :
  assembler_run_id:Keeper_plan_proposal_execution_request.Assembler_run_id.t ->
  proposal_id:Keeper_plan_proposal.Proposal_id.t ->
  verification ->
  Tool_result.result ->
  Tool_result.result
(** Add the canonical producer identity to every result disposition. Existing
    metadata is retained, while any conflicting reserved identity fields are
    replaced so the JSON object contains one authoritative value per field. *)
