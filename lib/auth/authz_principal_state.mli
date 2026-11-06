(* HIGH-RISK-UNREVIEWED: this is who the authorization log says the people of the
   installation are, which identity each is bound to, and who is an Admin. A
   principal that this module holds is a person every later decision trusts. *)

(** The human principals that the admission records of [authz.jsonl] add up to
    (plan B3c-2, design 4.1 and 5.1-3). {!Authz_state} keeps one of these as its
    field.

    {b Admission.} One record spends an open invitation, binds an identity, and
    makes a principal ({!admit}). Its author is the person who joins, signed in
    as the principal the record makes, so the record names no one else. An
    invitation with the role [Admin] makes the person an Admin in the same
    record.

    {b Uniqueness.} A user id names one principal, and an identity is bound to
    one principal. A second admission with either is refused, which is the 409
    of design 5.1-3. Design 4.1 also keeps the id of a deleted principal from
    being given again. No layer deletes a principal yet (B3c-5 does), so every
    id that was ever given is still held here. The writer draws a user id of 128
    bits from the OS CSPRNG and draws again when {!admit} refuses it as taken.

    {b Admins.} An admission through an Admin invitation makes an Admin
    assignment, and a revocation ({!revoke_admin}) ends one. The last Admin
    assignment in force is never revoked (design 5.1-5), so a log with one Admin
    keeps one. An Admin whose revocation the store gave up writes nothing
    (design 8.3), so that Admin does not count as the one that remains. *)

type status = Active

type principal = private
  { identity : Authz_external_identity.t
  ; status : status
  }

type t

val empty : t
val find : t -> Authz_types.User_id.t -> principal option

(** The principal an identity is bound to. *)
val find_identity : t -> Authz_external_identity.t -> Authz_types.User_id.t option

(** Whether the principal has an Admin assignment that is in force. *)
val is_admin : t -> Authz_types.User_id.t -> bool

type refusal =
  | Author_is_not_the_person of
      { author : Authz_records.Author.t
      ; user_id : Authz_types.User_id.t
      }
      (** The author of an admission is not the principal it makes. *)
  | Invitation of Authz_invite_state.consume_refusal
  | User_id_taken of Authz_types.User_id.t
  | Identity_bound of
      { identity : Authz_external_identity.t
      ; user_id : Authz_types.User_id.t  (** The principal it is bound to. *)
      }

val refusal_to_string : refusal -> string

type admitted =
  { principals : t
  ; invites : Authz_invite_state.t  (** With the invitation spent. *)
  ; role : Authz_invite_event.role  (** The role of the invitation. *)
  }

(** What one admission record does. [at_ms] is the time of the record, which
    {!Authz_invite_state.consume} compares with the expiry of the invitation.
    The checks run in this order, and the first that fails is the result: the
    author, the invitation, the user id, the identity. *)
val admit
  :  t
  -> invites:Authz_invite_state.t
  -> author:Authz_records.Author.t
  -> at_ms:int
  -> Authz_admission_event.t
  -> (admitted, refusal) result

type revocation_refusal =
  | Revoker_is_not_an_admin of Authz_records.Author.t
      (** Only a human principal with an Admin assignment in force revokes one. *)
  | Not_an_admin of Authz_types.User_id.t
      (** The principal has no Admin assignment in force. *)
  | Last_admin of Authz_types.User_id.t
      (** Every other assignment in force is held, or there is none (design
          5.1-5). *)

val revocation_refusal_to_string : revocation_refusal -> string

(** What one revocation of an Admin assignment does. The checks run in this
    order: the author, the principal, the last Admin. An Admin may revoke their
    own assignment while another Admin remains. [held] says whether the store
    gave up a revocation of that principal (design 8.3), and an Admin it holds
    is not one that remains. The cause changes nothing here in the first stage
    (see {!Authz_admin_event}). *)
val revoke_admin
  :  t
  -> author:Authz_records.Author.t
  -> held:(Authz_types.User_id.t -> bool)
  -> Authz_admin_event.t
  -> (t, revocation_refusal) result
