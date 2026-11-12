(* HIGH-RISK-UNREVIEWED: an Admin issues and revokes invitations here. Whoever
   holds the token of an open invitation joins the installation, as an Admin
   if the invitation says so. *)

(** What an Admin does to the invitations with the writer zone (plan C6 ③):
    issue one, or revoke one. The routes of {!Login_invite_routes} call these;
    nothing here reads a request.

    The zone checks each record with {!Authz_state.apply} inside its lock and
    refuses it with the reason of the state ([Commit_failed (Refused _)]), so
    who may write and what may be written are decided there
    ({!Authz_invite_state}): the author is an Admin that acts, an issued
    invitation takes an id and a token digest no invitation had, and a revoked
    one is open. The revocation is a [Revoke] intent of the invitation, which
    the zone writes to the external store before the record (design 8.2).

    The host-local operator issues the first Admin invitation without a
    server ({!Authz_activation}). *)

(** An invitation that was just committed. [token] is written nowhere: the
    log holds its digest, and the answer to the Admin is the only place it
    leaves the server. *)
type issued =
  { invite_id : Authz_types.Invite_id.t
  ; token : string
  ; expires_at_ms : int
  ; role : Authz_invite_event.role
  }

type error =
  | Id_not_drawn of Authz_id.error  (** [draw] gave a value that is not an id. *)
  | Body_not_built of Authz_body.error
  | Commit_failed of Authz_zone.error
      (** The zone says what it wrote. [Refused] is the reason of the state,
          and nothing was written. *)

val error_to_string : error -> string

(** How long an invitation of an Admin stays open: as long as one of the
    operator ({!Authz_activation.admin_invitation_lifetime_ms}). *)
val lifetime_ms : int

(** Three. *)
val attempts : int

(** [issue zone ~admin ~draw ~now_ms role] writes an invitation of [role] as
    the human principal [admin]. It expires {!lifetime_ms} after [now_ms ()].
    [draw ()] gives 32 random bytes as lowercase hex ({!Random_id.hex} in the
    server): one draw is the id, drawn again while the snapshot names it, at
    most {!attempts} times, and one is the token. *)
val issue
  :  Authz_zone.t
  -> admin:Authz_types.User_id.t
  -> draw:(unit -> string)
  -> now_ms:(unit -> int)
  -> Authz_invite_event.role
  -> (issued, error) result

(** [revoke zone ~admin invite_id] revokes an open invitation as the human
    principal [admin]. *)
val revoke
  :  Authz_zone.t
  -> admin:Authz_types.User_id.t
  -> Authz_types.Invite_id.t
  -> (unit, error) result
