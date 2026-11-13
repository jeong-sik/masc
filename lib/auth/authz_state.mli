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

    {!apply} is the function that the log is replayed with
    ({!Authz_zone.Replay.step}): the replay keeps the state and counts the
    changes for the high-water mark. A record that it refuses stops every later
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

(** A reduction that the external store gave up (design 8.3). Its subject
    stays blocked until a record names [aborted] in its [closes], or an
    eligible Admin cancels it ({!Authz_record.Kind.Revocation_cancel}); the zone
    holds one per given-up intent, so two reductions of one subject are closed
    apart. *)
type held = private
  { aborted : Authz_record.Hash.t
        (** The [intended_next_record_digest] of the intent given up. *)
  ; event : Authz_external_store.Change.authz_event
  ; subject : Authz_records.Subject.t
        (** The change of the intent given up is [Authz { event; subject }]. *)
  }

(** The block of an intent, if its change
    {!Authz_external_store.Change.is_reduction}. A block is made only here, so
    every block is of a reduction, which a retry of it can close. *)
val held_of_intent : Authz_external_store.intent -> held option

type t = private
  { mode : Authz_mode_state.t
  ; invites : Authz_invite_state.t  (** Plan B3c-1. *)
  ; principals : Authz_principal_state.t  (** Plan B3c-2. *)
  ; registrations : Authz_registration_state.t  (** Plan C2d. *)
  ; sessions : Authz_session_state.t  (** Plan C3. *)
  ; pats : Authz_pat_state.t  (** Plan C4. *)
  ; service_credentials : Authz_service_credential_state.t  (** Plan C4. *)
  ; provider_accounts : Authz_provider_account_state.t  (** Plan D1-1. *)
  ; runtimes : Authz_runtime_state.t  (** Plan D1. *)
  ; keepers : Authz_keeper_state.t  (** Plan D1-5. *)
  ; purges : Authz_purge_state.t  (** Plan S1b-3c. *)
  ; revocation_pending : held list
        (** The reductions whose intent the external store gave up (design
            8.3). No record adds one: the writer zone does, from the store
            ({!hold_revocations}). A record removes those it closes, and a
            cancel the one it names. *)
  ; latest_at_ms : int option
        (** The latest [at_ms] of the records read. [None] before the first. *)
  }

val empty : t

(** Blocks the subjects of reductions that the store gave up: an
    [Aborted_intent] whose change {!Authz_external_store.Change.is_reduction}.
    Design 8.3 blocks such a subject at the gate, without a record, until a
    record that names the aborted intent closes it: a record that makes the
    same change again, with the digests of {!closable} in its [closes], or the
    cancel of an Admin that is eligible for it (design 4.1). The cancel lifts
    the block and leaves the reduction undone. A
    revoked invitation that is blocked cannot be spent, which is what its
    revocation was for. A reduction already held is held once. *)
val hold_revocations : t -> held list -> t

(** The [aborted] digests of the held reductions whose change is this one:
    what a record that makes the change closes (design 8.3, a retry). Empty for
    a change that reduces nothing. *)
val closable : t -> Authz_external_store.Change.t -> Authz_record.Hash.t list

(** [Pending] while a reduction of [subject] is held (design 8.3,
    [revocation_pending(subject)]). *)
val revocation : t -> Authz_records.Subject.t -> Authz_records.Revocation_state.t

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
          disable, or [off] until it catches up. It holds every admission until
          then, and nothing lifts that early. *)
  | Closes_without_reduction
      (** The record has [closes], and the change it makes reduces nothing. *)
  | Closes_not_held of Authz_record.Hash.t
      (** The record closes this digest, and no held reduction of the change it
          makes has it. *)
  | Cancel_unreadable of Authz_cancel_event.error
  | Canceller_is_not_an_admin of Authz_records.Author.t
      (** The author of a cancel is not a human principal with an Admin
          assignment in force that is active. A held author is refused before
          this as {!Revocation_pending}. *)
  | Cancel_not_held of Authz_record.Hash.t
      (** No held reduction has this digest: none was given up with it, or a
          record closed or cancelled it before. *)
  | Cancel_subject_differs of
      { aborted : Authz_record.Hash.t
      ; named : Authz_records.Subject.t  (** The subject the cancel names. *)
      ; held : Authz_records.Subject.t  (** The subject of the held reduction. *)
      }
  | Canceller_owns_the_subject of Authz_records.Subject.t
      (** The canceller issued the invitation or wrote the registration that is
          the subject, which makes them its owner, or issued the invitation the
          principal that is the subject joined through, which makes them its
          original approver (design 4.1). *)
  | Cancel_owner_unknown of Authz_records.Subject.t
      (** No invitation or registration stands behind the subject, so this
          layer cannot tell its owner or its approver, and no Admin is known to
          be eligible. A block of a grant, a credential, a runtime, or a service
          stays until the layer that reads them. A block of a browser
          session is never cancelled: its owner closes it by signing out
          again, or a new sign-in of the browser by ending the session (plan
          C3). Nor is the block of a Keeper conversation whose purge was given
          up: its owner closes it by asking for the purge again (plan
          S1b-3c). *)
  | Registration_unreadable of Authz_registration_event.error
  | Registration of Authz_registration_state.refusal
  | Session_unreadable of Authz_session_event.error
  | Session of Authz_session_state.refusal
  | Pat_unreadable of Authz_pat_event.error
  | Pat of Authz_pat_state.refusal
  | Service_credential_unreadable of Authz_service_credential_event.error
  | Service_credential of Authz_service_credential_state.refusal
  | Provider_account_unreadable of Authz_provider_account_event.error
  | Provider_account of Authz_provider_account_state.refusal
  | Runtime_unreadable of Authz_runtime_event.error
  | Runtime of Authz_runtime_state.refusal
  | Keeper_unreadable of Authz_keeper_event.error
  | Keeper of Authz_keeper_state.refusal
  | Purge_unreadable of Authz_purge_event.error
  | Purge of Authz_purge_state.refusal

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
    from before it leaves the principal disabled. A cancel has none either: a
    log restored from before it brings the block back. A registration has
    none, as a log restored from before it keeps the identity out, and its
    removal is a [Revoke] of the registration, so the entry does not come back
    open (plan C2d). A sign-out is a [Revoke] on its session, and so is a
    sign-in that ends the session its browser held, on that session; a sign-in
    that ends nothing has none (plan C3). The link of a provider account has
    none: a log restored from before it leaves the account with no owner, and
    no Runtime may spend it (plan D1-1). A Runtime has none either: a log
    restored from before it has no such Runtime and no Self grant on it (plan
    D1). Nor does a Keeper record: a log restored from before it leaves the Keeper
    with no owner, or with the Runtime it was given before (plan D1-5). The
    start of a purge is a [Purge] on its target, so a log restored from before
    it does not make the target read again (design 8.5-1, plan S1b-3c). Its
    end has none: a log restored from before it holds the purge pending, and
    the maintenance deletes once more. *)
type applied =
  { state : t
  ; high_water : Authz_external_store.Change.t option
  }

val apply : t -> Authz_record.t -> (applied, refusal) result

(** The given-up reductions that a record names: its [closes], and the one a
    cancel lifts. The replay holds each one it has not reached before it reads
    the record ({!Authz_zone.Replay.step}), as the writer of the record held
    them all. A record cannot name an intent that begins after it, because the
    digest of the intent covers the head it began at. *)
val closed_by : Authz_record.t -> Authz_record.Hash.t list
