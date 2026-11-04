(* HIGH-RISK-UNREVIEWED: this is what the records of the authorization log add
   up to. A record that this module accepts and should not is a fact that the
   whole system treats as true. *)

(** The state that the records of [authz.jsonl] add up to (plan B3).

    One field per layer that reads records. {!step} matches every
    {!Authz_record.Kind.t} and hands a record to the module of its layer, so a
    layer that reads a new kind adds one field and one branch, and the compiler
    stops at {!step} when a kind is added. A kind that no layer reads yet is
    refused: masc writes no record of that kind, so a log that holds one was not
    written by masc.

    {!step} is the function that the log is replayed with
    ({!Authz_log.open_at_start}). A record that it refuses stops every later
    start, so a writer of a new kind of record runs {!step} on the record
    before the append. It decides what a record
    means, not whether someone may write it: who may write which kind is
    {!Authz_record.admits}, which the record already passed. A policy that may
    change belongs to the decision that reads this state, not here: making
    {!step} stricter refuses logs that were written before.

    The first record of every log is a [Fresh_bootstrap] mode event (design
    8.4), so any other record before it is refused. {!step} matches every kind
    but a mode event together with the mode, so each kind names what it means
    before the bootstrap, and the workspace of the bootstrap reaches a layer
    only from a branch that has one. *)

type t = private { mode : Authz_mode_state.t }

val empty : t

type refusal =
  | Before_bootstrap of Authz_record.Kind.t
      (** A record of this kind comes before the [Fresh_bootstrap]. *)
  | Mode_event_unreadable of Authz_mode_event.error
  | Mode of Authz_mode_state.refusal
  | Kind_not_read of Authz_record.Kind.t
      (** No layer reads records of this kind yet. *)

val refusal_to_string : refusal -> string
val step : t -> Authz_record.t -> (t, refusal) result
