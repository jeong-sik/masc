(** Local input admission and human reset assertions. Operator confirmation is
    a distinct authority; it never proves the original SDK gesture released. *)
type pending = private {
  generation : string;
  command_id : string;
  tab_id : int;
  page_label : string;
  operation : string;
}
type readiness = Command_settled | Operator_reset_asserted of { pending:pending; at:float }
type status = Ready of readiness | Uncertain of pending
type t
val create : unit -> t
val status : t -> status
val busy : t -> bool
val within_command : t -> command_id:string -> (unit -> 'a) -> ('a, string) result
(** Reject overlapping scopes. Cancellation leaves unresolved input pending
    but releases only the local running marker. *)
val admit : t -> (unit, string) result
val begin_holding : t -> tab_id:int -> page_label:string -> operation:string -> (unit, string) result
val command_settled : t -> Browser_ego_release.proof -> unit
(** Settle the pending input. A proof comes only from [Browser_ego_release.judge]
    over answers that [Browser_ego_release.answer_of_json] read, so a flag a
    script sets cannot settle it. The types cannot show that the caller read the
    SDK's answer for this pending input: the proof is not tied to one input, and
    [answer_of_json] reads whatever JSON it is given. This module does not
    inspect physical keys. *)
val not_started : t -> unit
(** Restore the prior readiness, retaining its operator provenance. *)
val assert_reset : t -> generation:string -> now:float -> (unit, string) result
(** Private authenticated-operator path only. Reject while any command runs,
    or when the generation changed. Repeating the same assertion before new
    input is idempotent; it sends no browser input. *)
val provenance : t -> string
