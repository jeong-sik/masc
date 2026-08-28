(** Exact model-facing request for executing one stored proposal. *)

type error =
  | Request_not_object
  | Duplicate_field of string
  | Unknown_field of string
  | Missing_field of string
  | Empty_assembler_run_id
  | Invalid_proposal_id of string
  | Approval_tools_not_array
  | Empty_approval_tools
  | Approval_tool_not_string of { index : int }
  | Empty_approval_tool of { index : int }

type t

module Assembler_run_id : sig
  type t = private string

  val of_string : string -> (t, error) result
  val to_string : t -> string
end

val of_yojson : Yojson.Safe.t -> (t, error) result
val assembler_run_id : t -> Assembler_run_id.t
val proposal_id : t -> Keeper_plan_proposal.Proposal_id.t
val approval_tools : t -> string list
val error_to_yojson : error -> Yojson.Safe.t
