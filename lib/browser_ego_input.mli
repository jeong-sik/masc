(** Input admission, retained intent and human reset assertions. Operator confirmation is
    a distinct authority; it never proves the original SDK gesture released. *)
type scope = Page_scope | Space_scope
type pending = private {
  generation : string;
  command_id : string;
  tab_id : int;
  page_label : string;
  operation : string;
  scope : scope;
}
type readiness = Command_settled | Operator_reset_asserted of { pending:pending; at:float }
type status = Ready of readiness | Uncertain of pending
type t
val create : unit -> t
(** Volatile fixture state. Production Ego workers use [create_persistent]. *)

type persistence = {
  read : unit -> (Yojson.Safe.t option, string) result;
  compare_and_set : expected:Yojson.Safe.t option -> replacement:Yojson.Safe.t -> (unit, string) result;
  active : unit -> bool;
}
val create_persistent : persistence:persistence -> writer:string -> space_id:int -> (t, string) result
(** Claim one writer epoch and restore the same numeric native Space's state.
    Full-record CAS fences replaced writers. Absence preserves the historical
    no-known-MASC-pending baseline; it does not attest native freshness or key
    release. Malformed/unreadable state refuses attachment. [active] must refer
    to the existing worker owner, never an independent operator setting.
    [writer] is a new unique immutable epoch for each attachment; production
    derives it from the owner incarnation and a fresh UUID. *)

val status : t -> status
val busy : t -> bool
val within_command : t -> command_id:string -> (unit -> 'a) -> ('a, string) result
(** Reject overlapping scopes. Cancellation leaves unresolved input pending
    but releases only the local running marker. *)

val admit : t -> (unit, string) result
(** Also refuse a retired/replaced writer or an unreadable retained record,
    including for methods that do not hold input. Reads are not input admission. *)

val begin_holding : t -> scope:scope -> tab_id:int -> page_label:string -> operation:string -> (pending, string) result
(** Persist the complete intent before permitting the native effect. An
    unconfirmed publication keeps local admission blocked; it grants no effect.
    Space_scope preserves the originating Page identity without claiming that
    later input in a multi-Page workflow stayed on that Page. Neither scope
    changes the connection-wide guard or operator reset authority. *)

val command_settled : t -> generation:string -> Browser_ego_release.proof -> (unit, string) result
(** Native-window evidence additionally requires this Pending's command,
    generation, source Page label and retained native Space. Production never
    settles a native window from an unbound volatile fixture state.
    Settle from the one Release judge, not a script flag. Receipt answers retain
    their existing call-site responsibility. Native-window proofs additionally
    carry verified invocation binding checked here before CAS. This module
    does not inspect or attest physical keys. *)

val not_started : t -> generation:string -> (unit, string) result
(** Restore the prior readiness, retaining its operator provenance. *)

val assert_reset : t -> generation:string -> now:float -> (unit, string) result
(** Private authenticated-operator path only. Reject while any command runs,
    or when the generation changed. Repeating the same assertion before new
    input is idempotent; it sends no browser input. *)

val provenance : t -> string
