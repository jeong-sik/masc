(** Where the last input-holding command on one Ego connection stands. Answers
    report it as [inputReadiness]; the next input runs either way. *)
type scope = Page_scope | Space_scope
type pending = private {
  generation : string;
  command_id : string;
  page_label : string;
  scope : scope;
}
(** One input-holding command, from just before its native effect. *)
type readiness =
  | Command_settled
  | Release_uncertain of pending
      (** an earlier holding command ended without the SDK declaring its release *)
type status = Ready of readiness | Uncertain of pending
(** [Uncertain]: the latest holding command has no settlement; while it runs
    and after it ended without one. *)
type t
val create : space_id:int -> t
(** One connection's state for the numeric native Space it is bound to. *)
val status : t -> status
val within_command : t -> command_id:string -> (unit -> 'a) -> ('a, string) result
(** Reject overlapping commands on one connection. Cancellation releases only
    the local running marker. *)

val begin_holding : t -> scope:scope -> page_label:string -> (pending, string) result
(** Record the intent inside the original command scope, before the native
    effect. An earlier unconfirmed input is kept as the readiness to restore if
    this one never starts. Space_scope preserves the originating Page identity
    without claiming that later input in a multi-Page workflow stayed on it. *)

val command_settled : t -> generation:string -> Browser_ego_release.proof -> (unit, string) result
(** Settle from the one Release judge, not a script flag, for the pending
    generation only. Native-window evidence additionally requires this
    Pending's command, generation, source Page label and this Space. A settled
    command replaces any earlier uncertainty, because readiness describes the
    latest holding command; {!not_started} instead restores what came before.
    This module does not inspect or attest physical keys. *)

val not_started : t -> generation:string -> (unit, string) result
(** Restore the readiness before this pending generation. *)

val readiness_wire : t -> string
(** The [inputReadiness] answer value: [command_settled] or [release_uncertain]. *)
