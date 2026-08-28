(** Exact model-facing request for executing one stored proposal. *)

type error =
  | Request_not_object
  | Duplicate_field of string
  | Unknown_field of string
  | Missing_field of string
  | Invalid_proposal_id of string
  | Approval_tools_not_array
  | Empty_approval_tools
  | Approval_tool_not_string of { index : int }
  | Empty_approval_tool of { index : int }

type t

val of_yojson : Yojson.Safe.t -> (t, error) result
val proposal_id : t -> Keeper_plan_proposal.Proposal_id.t
val approval_tools : t -> string list
val error_to_yojson : error -> Yojson.Safe.t
