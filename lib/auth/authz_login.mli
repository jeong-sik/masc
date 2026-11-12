(* HIGH-RISK-UNREVIEWED: decides who a login signs in as and writes the
   admission that lets a new person into the installation. *)

(** What the callback of a login decides with the writer zone, once the
    identity is known (design 5.1-2 to 5.1-6, plans C2a-4 and C2d).

    The decision starts on one snapshot that the zone could be trusted for
    ({!Authz_zone.read}). A zone whose file stopped, or whose files disagree,
    gives none, and every login is then refused as uncertain, whatever the
    identity.

    - An identity bound to an active principal signs in as it. A disabled one
      is refused (design 4.1), and so is one whose revocation the external
      store gave up and is still blocked (design 8.3).
    - An identity with no principal joins through the invitation whose token
      came with the login: one admission record spends the invitation, binds
      the identity, and makes the principal and its membership (design 5.1-3).
      The user id and the namespace are drawn here.
    - An identity with no principal and no invitation joins through its open
      entry of the allowlist, which an Admin wrote for it: one admission record
      spends the entry and makes a Member (design 5.1-2a).
    - An identity with no principal, no invitation, and no open entry is
      refused, and nothing is written: stage 1 has no admission request (design
      5.1-2c).
    - An identity bound to a principal that comes with an invitation is
      refused, and the invitation stays open: a new principal for a bound
      identity would bind it twice (design 5.1-3).

    Before the commit, the admission is checked against a snapshot with
    {!Authz_principal_state.admit}, the check the zone runs again inside its
    lock, so a refusal is typed without reading the error of the zone. If the
    commit fails and the log moved meanwhile, another writer came first: the
    admission is checked again against the new snapshot, which names what it
    took (the invitation, the entry, or the identity). An invitation admission
    of the same identity spends its entry too, so of the two the first commit
    joins and the other is a conflict (design 5.1-3). A user id or a namespace that is
    taken is drawn again (design 4.1). Each of these goes around at most
    {!attempts} times. *)

type outcome =
  | Signed_in of Authz_types.User_id.t
  | Admitted of
      { user_id : Authz_types.User_id.t
      ; role : Authz_invite_event.role
      ; previously_deleted : bool
          (** A deleted principal was bound to this identity (design 5.1-6).
              The person joins as a new principal all the same. *)
      }

type refusal =
  | Not_invited
      (** No principal has the identity, no invitation came, and the allowlist
          has no open entry for it. *)
  | Disabled of Authz_types.User_id.t
  | Blocked of Authz_types.User_id.t
      (** A revocation of this principal that the store gave up is held. *)
  | Uncertain
      (** The zone cannot be trusted now ({!Authz_zone.read}): nobody signs in
          and nobody joins. *)
  | Already_joined of Authz_types.User_id.t
      (** An invitation came with an identity bound to this principal, or
          another admission bound the identity before this one was written. *)
  | Invitation_unknown  (** No invitation has the digest of the token. *)
  | Admission_refused of Authz_principal_state.refusal
      (** The invitation expired, was revoked or spent, the entry was removed
          or spent, or the identity was bound, as the snapshot shows. *)
  | Not_bootstrapped  (** The state has no workspace, so no membership can be made. *)
  | Id_not_drawn of Authz_id.error  (** [draw] gave a value that is not an id. *)
  | Body_not_built of Authz_body.error
  | Commit_failed of Authz_zone.error
      (** The zone wrote nothing it could not undo, as its error says, and the
          log did not move, or moved {!attempts} times. *)

val refusal_to_string : refusal -> string

(** Whether the refusal is a conflict with another writer, which the route
    answers with 409 (design 5.1-3): the invitation or the registration was
    spent, or the identity was bound, by someone else, or an invitation came
    with a bound identity. *)
val is_conflict : refusal -> bool

(** Three. *)
val attempts : int

(** [sign_in zone ~now_ms ~draw ~identity ~invite] signs [identity] in, or lets
    it join through the invitation whose token has the digest [invite], or,
    with no [invite], through its open allowlist entry.
    [now_ms] is the clock of the zone, read for the check before the commit;
    the zone reads it again for the record. [draw ()] gives 32 random lowercase
    hex characters for each id it makes ({!Random_id.hex} in the server). *)
val sign_in
  :  Authz_zone.t
  -> now_ms:(unit -> int)
  -> draw:(unit -> string)
  -> identity:Authz_external_identity.t
  -> invite:Authz_invite_event.Token_digest.t option
  -> (outcome, refusal) result
