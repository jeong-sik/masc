(* HIGH-RISK-UNREVIEWED: this is what the records of the authorization log add
   up to. A record that this module accepts and should not is a fact that the
   whole system treats as true. *)

(** The state that the records of [authz.jsonl] add up to (plan B3).

    One field per layer that reads records. {!apply} matches every
    {!Authz_record.Kind.t} and hands a record to the module of its layer, so a
    layer that reads a new kind adds one field and one branch, and the compiler
    stops at {!apply} when a kind is added. A kind that no layer reads yet is
    refused: masc writes no record of that kind, so a log that holds one was not
    written by masc.

    {!step} is the function that the log is replayed with
    ({!Authz_log.open_at_start}). A record that it refuses stops every later
    start, so a writer runs {!apply} on the record before the append. It
    decides what a record means, not whether someone may write it: who may write which kind is
    {!Authz_record.admits}, which the record already passed. A policy that may
    change belongs to the decision that reads this state, not here: making
    {!apply} stricter refuses logs that were written before.

    {!apply} also says what the external store records before the record is
    appended (design 8.2): a mode event is an intent, and so will be every event
    that raises a scoped epoch or replaces a credential. The writer zone
    ({!Authz_zone}) writes that intent, the record and its answer, in this
    order.

    The first record of every log is a [Fresh_bootstrap] mode event (design
    8.4), so any other record before it is refused. {!apply} matches every kind
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

(** What one record does to the state. [high_water] is the change that the
    external store takes as [Intent_pending] before the record is appended, and
    [None] for a record that is appended without an intent. *)
type applied =
  { state : t
  ; high_water : Authz_external_store.Change.t option
  }

val apply : t -> Authz_record.t -> (applied, refusal) result

(** {!apply} without the change: the fold function of the replay. *)
val step : t -> Authz_record.t -> (t, refusal) result
