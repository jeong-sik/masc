(* HIGH-RISK-UNREVIEWED: this is the line format of the authorization log, and
   its writer-side check says which author may write which record. A record
   that gets past it is a grant, revocation, or principal that the whole
   system will treat as true. *)

(** One record of [authz.jsonl] (design 6.3 and 8.1).

    A record is one JSON line that carries the hash of the line before it, so
    the log is a chain: changing, dropping, or reordering a line breaks every
    hash after it. A record can only be made through {!make} or {!of_line}, and
    both refuse when the author may not write the kind (design 6.3). A value of
    type {!t} is therefore a record with a valid hash and an admitted author.

    The body is an {!Authz_body.t}: plain JSON that every reader reads the same
    way. The shape of the body is the business of the layer that owns the kind.

    This module writes every byte of a line itself, so what it writes does not
    depend on the version of any library. A line holds [seq], [previous_hash],
    [at_ms], [author], [kind], [body], and [hash], in that order and with no
    spaces. A record that closes given-up reductions has [closes] between
    [body] and [hash]; every other record has no such member. [seq] and
    [at_ms] are decimal digits and are not range-checked:
    [seq] comes from the head, and [at_ms] from the clock that {!Authz_zone}
    reads, so [at_ms] may be zero or negative, and a tool that reads numbers as
    doubles reads it exactly only up to 2^53 - 1. The hash is
    the SHA-256 of ["masc-authz-record-v1\n"] followed by the line with its
    [hash] member cut out, closing brace kept. [test_authz_record] pins one line
    and its hash. *)

open Authz_records

(** SHA-256 of a record, as 64 lowercase hex characters. *)
module Hash : sig
  type t

  (** The [previous_hash] of the first record. *)
  val genesis : t

  val of_hex : string -> t option
  val to_hex : t -> string
  val equal : t -> t -> bool
end

(** What a record is about. Each kind admits only certain authors; see
    {!admits}. A layer that needs a new kind adds a constructor here, and the
    compiler stops at {!admits} until that layer has decided who may write it. *)
module Kind : sig
  type t =
    | Runtime_grant
    | Delegate_policy
    | Principal
      (** A human principal is disabled, enabled, or deleted (design 4.1 and
          5.1-5, plan B3c-5). The body is that of {!Authz_principal_event}. *)
    | Internal_service_credential
      (** A Service credential is issued or revoked (design 5.3, plan C4). The
          body is that of {!Authz_service_credential_event}. *)
    | Permission_revocation
    | Trigger_evidence
    | Lease_terminal_evidence
    | Preauthorized_expiry
    | Migration_diagnostic
    | Local_recovery
    | Mode_event
      (** A change of the mode of the installation (design 5.1). The body is
          that of {!Authz_mode_event}. *)
    | Invite
      (** The issue or the revocation of an invitation to join the
          installation (design 5.1-2b). The body is that of
          {!Authz_invite_event}. *)
    | Admission
      (** A person joins through an invitation: the invitation is spent, the
          identity is bound, and the principal is made, in one record (design
          5.1-3, plan B3c). The body is that of {!Authz_admission_event}. *)
    | Admin_assignment
      (** A change of the Admin assignment of a principal (design 4.1, plan
          B3c-3). The body is that of {!Authz_admin_event}. *)
    | Revocation_cancel
      (** An eligible Admin lifts the block of a given-up reduction (design
          8.3, plan B2e-2b). The body is that of {!Authz_cancel_event}. *)
    | Registration
      (** An Admin registers an identity on the allowlist, or removes the
          registration (plan C2d). The first sign-in of a registered identity
          makes a Member. The body is that of {!Authz_registration_event}. *)
    | Session
      (** A person signs in and gets a browser session, or ends one (design
          5.2, plan C3). The body is that of {!Authz_session_event}. *)
    | Pat
      (** A person issues or revokes a scoped PAT (design 4.4, plan C4). The
          body is that of {!Authz_pat_event}. *)
    | Provider_account
      (** A person links a subscription as their own provider account (design
          4.2 and 5.4, plan D1-1). The body is that of
          {!Authz_provider_account_event}. *)
    | Runtime
      (** A person makes a Runtime on a provider account they own, with its
          Self grant in the same record (design 4.2-4.3, plan D1). The body is
          that of {!Authz_runtime_event}. *)
    | Keeper
      (** A person makes a Keeper and is its owner, and gives it one of
          their Runtimes (design 4.3, plan D1-5). The body is that of
          {!Authz_keeper_event}. *)
    | Purge
      (** A person starts the purge of what they own, and the system
          maintenance ends it once it has deleted that, or failed to (design
          8.5, plan S1b-3c). The body is that of {!Authz_purge_event}. *)

  val all : t list
  val to_string : t -> string
  val of_string : string -> t option
end

(** Whether [author] may write a record of this kind (design 6.3).
    [Runtime_grant], [Delegate_policy], [Principal], [Permission_revocation], [Admission],
    [Admin_assignment], [Revocation_cancel], and [Registration] need an
    authenticated principal: the person who joins writes their own admission,
    and an Admin writes the revocation of an Admin assignment, the cancel of a
    block, and the allowlist. Which Admin may cancel which block, and that the
    writer of the allowlist is an Admin, are questions of the state. The local
    operator does not write the allowlist: its way in is the invite. Each system author writes only its own records.
    The local operator writes recovery records, mode events, and invites, and an
    authenticated principal writes invites too: the first Admin is invited by
    the local operator and every later one by an Admin. Which authenticated
    principal may invite is a question of the state, so {!Authz_state} answers
    it. A [Session] record needs an authenticated principal too: the person
    whose session it is, and so does a [Pat] record: the person whose PAT it
    is, a [Provider_account] record: the person who links the account, and a
    [Runtime] record: the person who makes the Runtime, and a [Keeper]
    record: the person who makes the Keeper or gives it a Runtime. An [Internal_service_credential] record is written by the local
    operator: the host CLI issues and revokes the credentials of the services
    the host starts (user decision 2026-11-07). A [Purge] record is written by
    an authenticated principal, who starts the purge of what they own, and by
    the system maintenance, which ends it. Which of the two writes which event
    is a question of the state. *)
val admits : Kind.t -> Author.t -> bool

(** Where the next record goes: its position and the hash it must carry. *)
type head

val genesis : head
val next_seq : head -> int
val head_hash : head -> Hash.t

type t = private
  { seq : int  (** From 1. *)
  ; previous_hash : Hash.t
  ; at_ms : int
        (** Wall clock in milliseconds. The order of the log is [seq]. An
            admission is judged against the expiry of its invitation with this
            time ({!Authz_invite_state.consume}), and {!Authz_state} refuses
            one before a record it has read. *)
  ; author : Author.t
  ; kind : Kind.t
  ; body : Authz_body.t
  ; closes : Hash.t list
        (** The given-up reductions that this record closes (design 8.3), as
            the [intended_next_record_digest] of each intent, in ascending
            order and each once. Empty for a record from {!make}. The writer
            zone fills it ({!closing}), and {!Authz_state} says which
            records may. The hash covers it. *)
  ; hash : Hash.t
  }

(** The head once the given record has been appended. *)
val head_after : t -> head

type make_error =
  | Author_not_admitted of
      { kind : Kind.t
      ; author : Author.t
      }

val make
  :  head:head
  -> at_ms:int
  -> author:Author.t
  -> kind:Kind.t
  -> body:Authz_body.t
  -> (t, make_error) result

(** The record with [closes] in their order, and the hash that covers them.
    Its author passed {!make} already. *)
val closing : t -> closes:Hash.t list -> t

type decode_error =
  | Not_json
  | Unexpected_shape
      (** Not exactly the fields of a record, in order, with [closes] only when
          it holds a digest. *)
  | Unknown_kind of string
  | Invalid_author
  | Invalid_hash
  | Invalid_closes  (** [closes] holds something other than 64 lowercase hex characters. *)
  | Seq_mismatch of { expected : int; actual : int }
  | Previous_hash_mismatch
  | Author_not_admitted_to_write of { kind : Kind.t; author : Author.t }
  | Invalid_body of Authz_body.error  (** The body is not what {!Authz_body} accepts. *)
  | Hash_mismatch
  | Non_canonical  (** Parses to a valid record but is not the line {!to_line} writes. *)

val decode_error_to_string : decode_error -> string

(** The record as one line, without the trailing newline. *)
val to_line : t -> string

(** Reads a line that is expected at [head]. The line must be the exact bytes
    {!to_line} would write for the record it names. The checks run in the order
    of the constructors of {!decode_error}, and the first failure is the
    result. *)
val of_line : head:head -> string -> (t, decode_error) result

(** The JSON of a principal as {!to_line} writes it inside an author, and how
    {!of_line} reads it back. Other files of the authorization layer name a
    principal the same way, so the two functions are shared. *)
val principal_text : Authz_types.Principal.t -> string

val principal_of_json : Yojson.Safe.t -> Authz_types.Principal.t option
