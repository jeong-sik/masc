(* HIGH-RISK-UNREVIEWED: this is what the allowlist records of the authorization
   log add up to. A registration that this module holds open lets its identity
   join the installation as a Member at its first sign-in. *)

(** The allowlist that the registration records of [authz.jsonl] add up to
    (plan C2d). {!Authz_state} keeps one of these as its field and hands it
    every registration record of a bootstrapped log.

    {b Who may write.} An Admin registers an identity and removes any
    registration. The local operator does not register: its way in is the
    invitation. Who is an Admin, and which identities are bound to a
    principal, is for the caller to say ([is_admin] and [is_bound] of
    {!apply}), as both are made by records this module does not read.

    {b One open entry.} An identity has at most one open registration, and an
    identity that is bound to a principal is not registered. A registration id
    names one registration for good: a removed or spent one keeps its id, so a
    later registration takes another.

    {b Spending.} The first admission of the identity spends its open
    registration, whether it comes through the registration or through an
    invitation ({!consume} and {!spend_open}). So a person who is deleted later
    does not come back through an old registration: an Admin registers the
    identity again. *)

type status =
  | Open
  | Removed
  | Consumed of Authz_types.User_id.t
      (** An admission spent it, and made this principal. *)

type registration = private
  { identity : Authz_external_identity.t
  ; registrar : Authz_types.User_id.t
      (** The Admin who registered the identity: the owner of the entry
          (design 4.1). *)
  ; status : status
  }

type t

val empty : t
val find : t -> Authz_types.Registration_id.t -> registration option

(** Every registration with its id, in the order of the ids. *)
val bindings : t -> (Authz_types.Registration_id.t * registration) list

(** The open registration of this identity. *)
val find_open
  :  t
  -> Authz_external_identity.t
  -> (Authz_types.Registration_id.t * registration) option

(** The registration that an admission spent for this principal. Its registrar
    is the original approver of a principal who joined through it (design
    4.1). *)
val find_consumed_by
  :  t
  -> Authz_types.User_id.t
  -> (Authz_types.Registration_id.t * registration) option

type refusal =
  | Already_registered of Authz_types.Registration_id.t
      (** The id names a registration, open or not. *)
  | Identity_registered of Authz_types.Registration_id.t
      (** The identity has this open registration. *)
  | Identity_bound
      (** The identity is bound to a principal, so it signs in as that
          principal and needs no registration. *)
  | Not_registered of Authz_types.Registration_id.t
  | Already_removed of Authz_types.Registration_id.t
  | Already_consumed of Authz_types.Registration_id.t
  | Author_is_not_an_admin of Authz_types.Principal.t
      (** An authenticated principal that is not an Admin. A service has no
          Admin role (design 4.1). *)
  | Not_a_registration_author of Authz_records.Author.t
      (** The local operator or a system author, which {!Authz_record.admits}
          does not let write a registration record. *)

val refusal_to_string : refusal -> string

(** Why an admission cannot spend a registration. *)
type consume_refusal =
  | Registration_not_found of Authz_types.Registration_id.t
  | Registration_removed of Authz_types.Registration_id.t
  | Registration_consumed of Authz_types.Registration_id.t
  | Identity_differs of Authz_types.Registration_id.t
      (** The admission binds another identity than the one registered. *)

val consume_refusal_to_string : consume_refusal -> string

(** Spends an open registration for the principal that an admission through
    it makes. The admission binds [identity], which is the one registered.
    The admission record calls this ({!Authz_state}); no registration record
    does. *)
val consume
  :  t
  -> Authz_types.Registration_id.t
  -> identity:Authz_external_identity.t
  -> user_id:Authz_types.User_id.t
  -> (t, consume_refusal) result

(** Spends the open registration of [identity] for the principal that an
    admission through an invitation makes. An identity with no open
    registration leaves the allowlist as it is. *)
val spend_open : t -> Authz_external_identity.t -> user_id:Authz_types.User_id.t -> t

(** What one registration record does to the allowlist. [is_admin] says
    whether a human principal has an Admin assignment in force, and [is_bound]
    whether an identity is bound to a principal that is not deleted. *)
val apply
  :  t
  -> author:Authz_records.Author.t
  -> is_admin:(Authz_types.User_id.t -> bool)
  -> is_bound:(Authz_external_identity.t -> bool)
  -> Authz_registration_event.t
  -> (t, refusal) result
