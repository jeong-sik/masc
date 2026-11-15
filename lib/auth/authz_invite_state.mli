(* HIGH-RISK-UNREVIEWED: this is what the invite records of the authorization log
   add up to. An invitation that this module holds open lets the holder of its
   token join the installation, as an Admin if its role says so. *)

(** The invitations that the invite records of [authz.jsonl] add up to (plan
    B3c-1). {!Authz_state} keeps one of these as its field and hands it every
    invite record of a bootstrapped log.

    {b Who may write.} The local operator issues invitations with the role
    [Admin] and revokes any invitation. That is how the first Admin is made
    (plan B3, the first Admin). An Admin issues invitations of either role and
    revokes any invitation (plan B3c-3). Who is an Admin is for the caller to
    say ([is_admin] of {!apply}), as the Admins are made by admissions, which
    this module does not read.

    {b Identity.} An invite id and a token digest name one invitation for
    good: a revoked invitation keeps both, so a second invitation can take
    neither. A token that was given out for a revoked invitation therefore never
    opens another one.

    {b Expiry.} Nothing here reads a clock. An admission spends an open
    invitation only if the time of its record is before [expires_at_ms]
    ({!consume}), so a replay of the log gives the same answer on any day. The
    zone reads that time inside its locks, and {!Authz_state} refuses an
    admission whose time is before a record it has read
    ({!Authz_state.Admission_behind_log}). *)

type status =
  | Open
  | Revoked
  | Consumed of Authz_types.User_id.t
      (** An admission spent it, and made this principal (plan B3c-2). *)

(** Who wrote the issue of an invitation: its owner (design 4.1). Only the
    local operator and an Admin may issue one, so nothing else can stand
    here. *)
type issuer =
  | Local_operator_issued
  | Admin_issued of Authz_types.User_id.t

type invitation = private
  { token_digest : Authz_invite_event.Token_digest.t
  ; expires_at_ms : int
  ; role : Authz_invite_event.role
  ; issuer : issuer
  ; status : status
  }

type t

val empty : t
val find : t -> Authz_types.Invite_id.t -> invitation option

(** Every invitation with its id, in the order of the ids. *)
val bindings : t -> (Authz_types.Invite_id.t * invitation) list

(** The invitation whose token has this digest, open or not. *)
val find_by_token_digest
  :  t
  -> Authz_invite_event.Token_digest.t
  -> (Authz_types.Invite_id.t * invitation) option

(** The invitation that an admission spent for this principal: the one the
    principal joined through. Its issuer is the original approver of the
    principal (design 4.1). {!Authz_principal_state} gives a user id to one
    admission only, so at most one invitation has it. *)
val find_consumed_by
  :  t
  -> Authz_types.User_id.t
  -> (Authz_types.Invite_id.t * invitation) option

type refusal =
  | Already_issued of Authz_types.Invite_id.t
  | Token_digest_taken of Authz_types.Invite_id.t
      (** Another invitation, open or revoked, has the same token digest. *)
  | Not_issued of Authz_types.Invite_id.t
  | Already_revoked of Authz_types.Invite_id.t
  | Already_consumed of Authz_types.Invite_id.t
  | Local_operator_invites_only_admins
      (** The local operator issued an invitation with the role [Member]. *)
  | Author_is_not_an_admin of Authz_types.Principal.t
      (** An authenticated principal that is not an Admin. A service has no
          Admin role (design 4.1). *)
  | Not_an_invite_author of Authz_records.Author.t
      (** A system author, which {!Authz_record.admits} does not let write an
          invite record. *)

val refusal_to_string : refusal -> string

(** Why an admission cannot spend an invitation. *)
type consume_refusal =
  | Invitation_not_issued of Authz_types.Invite_id.t
  | Invitation_revoked of Authz_types.Invite_id.t
  | Invitation_consumed of Authz_types.Invite_id.t
  | Invitation_expired of
      { invite_id : Authz_types.Invite_id.t
      ; expires_at_ms : int
      ; at_ms : int  (** The time of the admission record. *)
      }

val consume_refusal_to_string : consume_refusal -> string

(** Spends an open invitation for the principal that an admission makes, and
    gives its role. [at_ms] is the time of the admission record, and the
    invitation is spent only if it is before [expires_at_ms]. The admission
    record calls this ({!Authz_state}); no invite record does. *)
val consume
  :  t
  -> Authz_types.Invite_id.t
  -> user_id:Authz_types.User_id.t
  -> at_ms:int
  -> (t * Authz_invite_event.role, consume_refusal) result

(** What one invite record does to the invitations. [is_admin] says whether a
    human principal has an Admin assignment in force. *)
val apply
  :  t
  -> author:Authz_records.Author.t
  -> is_admin:(Authz_types.User_id.t -> bool)
  -> Authz_invite_event.t
  -> (t, refusal) result
