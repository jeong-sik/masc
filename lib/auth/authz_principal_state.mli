(* HIGH-RISK-UNREVIEWED: this is who the authorization log says the people of the
   installation are, which identity each is bound to, and who is an Admin. A
   principal that this module holds is a person every later decision trusts. *)

(** The human principals that the admission records of [authz.jsonl] add up to
    (plan B3c-2, design 4.1 and 5.1-3). {!Authz_state} keeps one of these as its
    field.

    {b Admission.} One record spends an open invitation or an open
    registration of the allowlist, binds an identity, and makes a principal
    ({!admit}). Its author is the person who joins, signed in as the principal
    the record makes, so the record names no one else. An invitation with the
    role [Admin] makes the person an Admin in the same record; a registration
    makes a Member (plan C2d).

    {b Uniqueness.} A user id names one principal, and an identity is bound to
    one principal. A second admission with either is refused, which is the 409
    of design 5.1-3. Design 4.1 also keeps the id of a deleted principal from
    being given again: a deletion ({!apply_event}) frees the identity and keeps
    the id ({!is_deleted}) and the namespace. The writer draws a user id of 128
    bits from the OS CSPRNG and draws again when {!admit} refuses it as taken.

    {b Admins.} An admission through an Admin invitation makes an Admin
    assignment, and a revocation ({!revoke_admin}) ends one. The last Admin
    assignment in force is never revoked (design 5.1-5), so a log with one Admin
    keeps one. An Admin whose revocation the store gave up writes nothing
    (design 8.3), so that Admin does not count as the one that remains. *)

type status =
  | Active
  | Disabled  (** Acts no more, and is not counted as an Admin (design 4.1). *)

type principal = private
  { identity : Authz_external_identity.t
  ; status : status
  }

(** The membership that an admission makes in the workspace of the
    installation (design 4.1, plan B3c-4). *)
type membership = private
  { workspace_id : Authz_types.Workspace_id.t
  ; account_home_namespace : Authz_types.Account_home_namespace.t
  }

type t

val empty : t
val find : t -> Authz_types.User_id.t -> principal option

(** Every principal with its id, in the order of the ids. A deleted principal
    is in none ({!is_deleted}). *)
val bindings : t -> (Authz_types.User_id.t * principal) list

(** The principal an identity is bound to. *)
val find_identity : t -> Authz_external_identity.t -> Authz_types.User_id.t option

val find_membership : t -> Authz_types.User_id.t -> membership option

(** The member a namespace was given to. *)
val find_namespace : t -> Authz_types.Account_home_namespace.t -> Authz_types.User_id.t option

(** Whether the principal was deleted. Its id is never given again. *)
val is_deleted : t -> Authz_types.User_id.t -> bool

(** Whether a deleted principal was bound to this identity: the
    [previously_deleted] mark of an admission (design 5.1-6). It is read from
    the [Deleted] events of the log and is in no principal record. It does not
    stop the identity from joining again, as a new principal. *)
val was_deleted : t -> Authz_external_identity.t -> bool

(** Whether the principal exists and is [Active]. *)
val is_active : t -> Authz_types.User_id.t -> bool

(** Whether the principal is [Active] and has an Admin assignment in force. A
    disabled Admin keeps the assignment and does not act. *)
val is_admin : t -> Authz_types.User_id.t -> bool

(** Whether the principal has an Admin assignment in force, active or not:
    the role, where {!is_admin} is the role that acts. *)
val has_admin_assignment : t -> Authz_types.User_id.t -> bool

type refusal =
  | Author_is_not_the_person of
      { author : Authz_records.Author.t
      ; user_id : Authz_types.User_id.t
      }
      (** The author of an admission is not the principal it makes. *)
  | Invitation of Authz_invite_state.consume_refusal
  | Registration of Authz_registration_state.consume_refusal
  | User_id_taken of Authz_types.User_id.t
  | Identity_bound of
      { identity : Authz_external_identity.t
      ; user_id : Authz_types.User_id.t  (** The principal it is bound to. *)
      }
  | Workspace_differs of
      { given : Authz_types.Workspace_id.t
      ; workspace_id : Authz_types.Workspace_id.t  (** The workspace of the installation. *)
      }
  | Namespace_taken of
      { namespace : Authz_types.Account_home_namespace.t
      ; user_id : Authz_types.User_id.t  (** The member it was given to. *)
      }
      (** Two members never share the directory of their account homes. *)

val refusal_to_string : refusal -> string

type admitted =
  { principals : t
  ; invites : Authz_invite_state.t  (** With the invitation spent, if it came through one. *)
  ; registrations : Authz_registration_state.t
        (** With the open registration of the identity spent: the one it came
            through, or the one an invitation admission spends too. *)
  ; role : Authz_invite_event.role
        (** The role of the invitation, or [Member] through a registration. *)
  }

(** What one admission record does. [workspace_id] is the workspace of the
    installation. [at_ms] is the time of the record, which
    {!Authz_invite_state.consume} compares with the expiry of the invitation.
    The checks run in this order, and the first that fails is the result: the
    author, the invitation or the registration, the user id, the identity, the
    workspace, the namespace. A registration is spent only for the identity it
    was written for ({!Authz_registration_state.consume}). *)
val admit
  :  t
  -> invites:Authz_invite_state.t
  -> registrations:Authz_registration_state.t
  -> workspace_id:Authz_types.Workspace_id.t
  -> author:Authz_records.Author.t
  -> at_ms:int
  -> Authz_admission_event.t
  -> (admitted, refusal) result

type revocation_refusal =
  | Revoker_is_not_an_admin of Authz_records.Author.t
      (** Only an Admin that acts revokes one: a human principal with an
          Admin assignment in force, active, and not held. *)
  | Not_an_admin of Authz_types.User_id.t
      (** The principal has no Admin assignment in force. *)
  | Last_admin of Authz_types.User_id.t
      (** No other assignment in force belongs to an Admin that acts (design
          5.1-5). *)

val revocation_refusal_to_string : revocation_refusal -> string

(** What one revocation of an Admin assignment does. The checks run in this
    order: the author, the principal, the last Admin that acts. An Admin may
    revoke their own assignment while another Admin acts. An Admin acts when it
    is not disabled and [held] is false for it: [held] says whether the store
    gave up a revocation of that principal (design 8.3). The cause changes
    nothing here in the first stage (see {!Authz_admin_event}). *)
val revoke_admin
  :  t
  -> author:Authz_records.Author.t
  -> held:(Authz_types.User_id.t -> bool)
  -> Authz_admin_event.t
  -> (t, revocation_refusal) result

type principal_refusal =
  | Writer_is_not_an_admin of Authz_records.Author.t
      (** The author is not an Admin that acts (see {!Revoker_is_not_an_admin}). *)
  | No_principal of Authz_types.User_id.t
      (** Never admitted, or deleted. *)
  | Already_disabled of Authz_types.User_id.t
  | Not_disabled of Authz_types.User_id.t
  | Identity_differs of
      { user_id : Authz_types.User_id.t
      ; identity : Authz_external_identity.t  (** The identity the deletion named. *)
      }
  | Would_leave_no_admin of Authz_types.User_id.t
      (** The event would leave no Admin that acts (design 5.1-5). *)

val principal_refusal_to_string : principal_refusal -> string

(** What one principal record does (plan B3c-5). Only an Admin that acts writes
    one. A deletion takes the principal, its identity binding, its membership,
    and its Admin assignment out: the identity may join again as a new
    principal through a new invitation, and the user id and the namespace are
    never given again (design 4.1). The checks run in this order: the author,
    the principal, the identity of a deletion, the last Admin that acts, which
    [held] tells as in {!revoke_admin}. *)
val apply_event
  :  t
  -> author:Authz_records.Author.t
  -> held:(Authz_types.User_id.t -> bool)
  -> Authz_principal_event.t
  -> (t, principal_refusal) result
