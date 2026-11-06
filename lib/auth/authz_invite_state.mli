(* HIGH-RISK-UNREVIEWED: this is what the invite records of the authorization log
   add up to. An invitation that this module holds open lets the holder of its
   token join the installation, as an Admin if its role says so. *)

(** The invitations that the invite records of [authz.jsonl] add up to (plan
    B3c-1). {!Authz_state} keeps one of these as its field and hands it every
    invite record of a bootstrapped log.

    {b Who may write.} In this layer the local operator issues invitations with
    the role [Admin] and revokes any invitation. That is how the first Admin is
    made (plan B3, the first Admin). An invitation by an authenticated principal
    needs to know who the Admins are, and the layer that reads the Admins
    (B3c-3) opens it. Until then such a record is refused.

    {b Identity.} An invite id and a token digest name one invitation for
    good: a revoked invitation keeps both, so a second invitation can take
    neither. A token that was given out for a revoked invitation therefore never
    opens another one.

    {b Expiry.} Nothing here reads a clock. An admission spends an open
    invitation only if the time of its record is before [expires_at_ms]
    ({!consume}), so a replay of the log gives the same answer on any day. *)

type status =
  | Open
  | Revoked
  | Consumed of Authz_types.User_id.t
      (** An admission spent it, and made this principal (plan B3c-2). *)

type invitation = private
  { token_digest : Authz_invite_event.Token_digest.t
  ; expires_at_ms : int
  ; role : Authz_invite_event.role
  ; status : status
  }

type t

val empty : t
val find : t -> Authz_types.Invite_id.t -> invitation option

(** The invitation whose token has this digest, open or not. *)
val find_by_token_digest
  :  t
  -> Authz_invite_event.Token_digest.t
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
  | Authenticated_author_not_read of Authz_types.Principal.t
      (** No layer reads yet whether this principal may write invitations. *)
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

(** What one invite record does to the invitations. *)
val apply
  :  t
  -> author:Authz_records.Author.t
  -> Authz_invite_event.t
  -> (t, refusal) result
