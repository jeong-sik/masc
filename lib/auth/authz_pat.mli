(* HIGH-RISK-UNREVIEWED: this module issues scoped PATs and decides what a PAT
   token acts as. A token it lets through acts as its Human within the scope of
   the PAT. *)

(** Scoped PATs against the writer zone (design 4.4 and 5.3, plan C4-6).

    {!issue} writes the record of a new PAT and hands back its token, the only
    time the secret leaves the server. {!authenticate} reads a token against
    one snapshot. {!revoke} writes the record that ends a PAT. The routes of
    C4-10 call these; the request gate of C4-8 calls {!authenticate}. Whether
    the scope lets a request through is for {!Authz_decision}. *)

type error =
  | Id_not_drawn of Authz_id.error  (** [draw] gave a value that is not a PAT id. *)
  | Body_not_built of Authz_body.error
  | Commit_failed of Authz_zone.error

val error_to_string : error -> string

(** How many ids {!issue} draws before it gives up: an id that the snapshot
    already names is drawn again. *)
val attempts : int

(** Issues a PAT for [user_id], who asked for it, with the scope and the expiry
    they chose. [draw ()] gives the PAT id. *)
val issue
  :  Authz_zone.t
  -> user_id:Authz_types.User_id.t
  -> draw:(unit -> string)
  -> scope:Authz_types.Authorization_scope.t
  -> expires_at_ms:int option
  -> (Authz_credential_token.Pat.t, error) result

(** What a PAT acts as. [pat_scope] is the scope of the PAT, with its expiry in
    seconds since the epoch, as {!Authz_decision} reads it. *)
type signed_in =
  { user_id : Authz_types.User_id.t
  ; pat_id : Authz_types.Pat_id.t
  ; pat_scope : Authz_types.Pat_scope.t
  }

(** Why a token does not act. *)
type refusal =
  | Unknown  (** No PAT has the id of the token. *)
  | Ended  (** The PAT was revoked. *)
  | Expired
  | Secret_differs  (** The PAT is there, and the secret of the token is not its own. *)
  | Revocation_pending
      (** A revocation of the PAT was given up before it reached the log
          (design 8.3). *)
  | Principal_inactive of Authz_types.User_id.t
      (** The Human of the PAT is disabled or deleted. *)
  | Principal_revocation_pending of Authz_types.User_id.t
      (** A revocation of the Human of the PAT was given up before it reached
          the log (design 8.3). *)

val refusal_to_string : refusal -> string

(** What a token acts as at [now_ms], in the state of one snapshot that the
    zone could be trusted for ({!Authz_zone.read}). *)
val authenticate
  :  Authz_zone.trusted
  -> now_ms:int
  -> Authz_credential_token.Pat.t
  -> (signed_in, refusal) result

(** Ends a PAT of [user_id]. The state refuses the PAT of another Human. *)
val revoke
  :  Authz_zone.t
  -> user_id:Authz_types.User_id.t
  -> Authz_types.Pat_id.t
  -> (unit, error) result
