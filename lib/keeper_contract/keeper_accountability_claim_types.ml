(** Claim kind + status variants for keeper accountability records.

    Two small variants used throughout [Keeper_accountability]:
    [claim_kind] tags whether an accountability claim is a forward
    task commitment or a backward completion claim;
    [claim_status] tracks the lifecycle of resolution (pending,
    supported by evidence, unsupported, expired, or partial).

    Plus the 4-helper string bijection bundle. Pure types + total
    [to_string] + parse-don't-validate [of_string] (unknown -> None).

    Verbatim extract from the head of [Keeper_accountability]; the
    parent retains transparent variant aliases so existing
    exhaustive matches and external [Keeper_accountability.Pending]
    / [.Task_commitment] etc. constructor references continue to
    resolve. *)

type claim_kind =
  | Task_commitment
  | Completion_claim

type claim_status =
  | Pending
  | Supported
  | Unsupported
  | Expired
  | Partial

let claim_kind_to_string = function
  | Task_commitment -> "task_commitment"
  | Completion_claim -> "completion_claim"
;;

let claim_kind_of_string = function
  | "task_commitment" -> Some Task_commitment
  | "completion_claim" -> Some Completion_claim
  | _ -> None
;;

let claim_status_to_string = function
  | Pending -> "pending"
  | Supported -> "supported"
  | Unsupported -> "unsupported"
  | Expired -> "expired"
  | Partial -> "partial"
;;

let claim_status_of_string = function
  | "pending" -> Some Pending
  | "supported" -> Some Supported
  | "unsupported" -> Some Unsupported
  | "expired" -> Some Expired
  | "partial" -> Some Partial
  | _ -> None
;;
