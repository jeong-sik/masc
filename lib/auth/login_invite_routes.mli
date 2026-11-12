(* HIGH-RISK-UNREVIEWED: an Admin's browser issues and revokes invitations
   through these routes. The answer to an issue holds the token of the
   invitation, and whoever holds it joins the installation. *)

(** What the invitation routes answer (plan C6 ③, issue #51483):
    [POST /api/v1/auth/invites] issues an invitation, and
    [DELETE /api/v1/auth/invites/<id>] revokes one ({!Authz_invite}).

    The request acts through a browser session ({!Login_routes.acting}): it
    changes something, so it comes from this origin with the CSRF token of the
    session. The session's principal is the author of the record, and the
    state decides whether that principal is an Admin. Every answer is JSON
    with [cache-control: no-store]; a refusal is [{"error": ...}].

    Like {!Login_routes}, this module holds no HTTP type. *)

(** [/api/v1/auth/invites], the path of the collection. An invitation is at
    [<path>/<invite_id>]. *)
val path : string

(** [body] is [{"role":"member"}] or [{"role":"admin"}], with no other
    member; anything else is a 400. The answer is a 200
    [{"invite_id": ..., "role": ..., "expires_at_ms": ..., "link": ...}].
    [link] is [/accounts/invite#<token>], a reference on this server: the
    page that asked puts its own origin in front of it, and the server names
    no address of its own. The token is in no other answer and in no record,
    so a link that is lost is revoked and issued again. A principal that is
    not an Admin gets a 403. *)
val issue : Login_routes.t -> Authz_browser_request.request -> body:string -> Login_routes.answer

(** [invite_id] is the [<id>] of the path; one that is not an id is a 400.
    The answer is a 204, a 404 for an id no invitation had, and a 409 for an
    invitation that was revoked or that a person joined through. An
    invitation that expired and that no one spent is open, and is revoked as
    any other. *)
val revoke : Login_routes.t -> Authz_browser_request.request -> invite_id:string -> Login_routes.answer
