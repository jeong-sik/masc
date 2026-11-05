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
    order. A record that changes no epoch, the issue of an invitation for one,
    has no intent, and the zone appends it alone.

    The first record of every log is a [Fresh_bootstrap] mode event (design
    8.4), so any other record before it is refused. {!apply} matches every kind
    but a mode event together with the mode, so each kind names what it means
    before the bootstrap, and the workspace of the bootstrap reaches a layer
    only from a branch that has one. *)

type t = private
  { mode : Authz_mode_state.t
  ; invites : Authz_invite_state.t  (** Plan B3c-1. *)
  ; principals : Authz_principal_state.t  (** Plan B3c-2. *)
  ; revocation_pending : Authz_records.Subject.t list
        (** The subjects of reductions whose intent the external store gave up
            (design 8.3). No record adds one: the writer zone does, from the
            store ({!hold_revocations}). *)
  ; latest_at_ms : int option
        (** The latest [at_ms] of the records read. [None] before the first. *)
  }

val empty : t

(** Blocks the subjects of reductions that the store gave up: an
    [Aborted_intent] whose change {!Authz_external_store.Change.is_reduction}.
    Design 8.3 blocks such a subject at the gate, without a record, until a
    record that names the aborted intent closes it. No layer writes that record
    yet, so a subject stays blocked. A revoked invitation that is blocked cannot
    be spent, which is what its revocation was for. *)
val hold_revocations : t -> Authz_records.Subject.t list -> t

type refusal =
  | Before_bootstrap of Authz_record.Kind.t
      (** A record of this kind comes before the [Fresh_bootstrap]. *)
  | Mode_event_unreadable of Authz_mode_event.error
  | Mode of Authz_mode_state.refusal
  | Invite_unreadable of Authz_invite_event.error
  | Invite of Authz_invite_state.refusal
  | Admission_unreadable of Authz_admission_event.error
  | Admission of Authz_principal_state.refusal
  | Revocation_pending of Authz_records.Subject.t
      (** The record spends what a revocation that the store gave up was about,
          or its author is a principal whose revocation the store gave up
          (design 8.3). *)
  | Admin_assignment_unreadable of Authz_admin_event.error
  | Admin_assignment of Authz_principal_state.revocation_refusal
  | Principal_unreadable of Authz_principal_event.error
  | Principal_event of Authz_principal_state.principal_refusal
  | Author_inactive of Authz_types.User_id.t
      (** The author is a disabled or deleted principal (design 4.1). *)
  | Accounts_off of Authz_record.Kind.t
      (** The mode is [Off], and a record of this kind is not written while the
          accounts are off (design 10.5). *)
  | Kind_not_read of Authz_record.Kind.t
      (** No layer reads records of this kind yet. *)
  | Admission_behind_log of
      { at_ms : int
      ; latest_at_ms : int
      }
      (** The admission is at [at_ms], before a record already read: the clock
          that wrote it went back. An admission is judged against the expiry
          of its invitation with its own time, so this time cannot go back.
          Every other kind is judged with no time, and is read whatever its
          time is: a clock that ran ahead and came back holds no revocation,
          disable, or [off] until it catches up. *)

val refusal_to_string : refusal -> string

(** What one record does to the state. [high_water] is the change that the
    external store takes as [Intent_pending] before the record is appended. A
    mode event has one. The issue of an invitation has none, because it raises
    no scoped epoch (design 8.1 and 8.2): the zone appends it with no intent and
    no answer in the store. Its revocation has one, a [Revoke] of the invitation,
    so a log restored from before the revocation does not open the invitation
    again (design 5.1-4). An admission has one, a [Grant] on the principal it
    makes: it spends a token that opens once (design 5.1-3), and an Admin
    invitation also raises the role epoch of that principal. The revocation
    of an Admin assignment is a [Revoke] on its principal, a disable a
    [Disable], and a deletion a [Delete]. An enable has none: a log restored
    from before it leaves the principal disabled. *)
type applied =
  { state : t
  ; high_water : Authz_external_store.Change.t option
  }

val apply : t -> Authz_record.t -> (applied, refusal) result

(** {!apply} without the change: the fold function of the replay. *)
val step : t -> Authz_record.t -> (t, refusal) result
