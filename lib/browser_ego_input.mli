(** Local input admission and human reset assertions. Operator confirmation is
    a distinct authority; it never proves the original SDK gesture released. *)
type pending = private {
  generation : string;
  command_id : string;
  tab_id : int;
  page_label : string;
  operation : string;
}
type readiness = Command_settled | Operator_reset_asserted of { pending:pending; at:float } | Dialog_interrupted of pending
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
val command_settled : t -> unit
(** Consume the existing producer's settlement indication. This module does
    not strengthen that producer's SDK evidence or inspect physical keys. *)
val dialog_interrupted : t -> unit
(** The SDK itself reported that a JavaScript dialog cut the pending input
    short. The input is not claimed released. The reply was not lost and the
    dialog is the page's to answer, so admission continues and receipts carry
    [inputReadiness] until a later holding input settles. A pending input whose
    outcome is unknown stays pending. *)
val not_started : t -> unit
(** Restore the prior readiness, retaining its operator provenance. *)
val assert_reset : t -> generation:string -> now:float -> (unit, string) result
(** Private authenticated-operator path only. Reject while any command runs,
    or when the generation changed. Repeating the same assertion before new
    input is idempotent; it sends no browser input. *)
val provenance : t -> string
