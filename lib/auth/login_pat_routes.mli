(* HIGH-RISK-UNREVIEWED: a person's browser issues and revokes their scoped PATs
   through these routes. A token issued here acts as its Human within its
   scope. *)

(** What the PAT routes answer (plan C4-10): [POST /api/v1/auth/pats] issues a
    scoped PAT for the person of the session, [GET /api/v1/auth/pats] lists
    their PATs, and [DELETE /api/v1/auth/pats/<id>] revokes one of them
    ({!Authz_pat}, plan C4-6).

    Every request acts through a browser session ({!Login_routes.acting}). The
    issue and the revoke change something, so they come from this origin with
    the CSRF token of the session. A PAT is not a session, so no PAT issues
    another PAT (design 4.4). The person of the session writes the record, and
    a PAT is always their own. Every answer is JSON with
    [cache-control: no-store]; a refusal is [{"error": ...}].

    Like {!Login_routes}, this module holds no HTTP type, and the routes are
    registered at boot (S1). *)

(** [/api/v1/auth/pats], the path of the collection. A PAT is at
    [<path>/<id>]. *)
val path : string

(** [body] is [{"scope": ..., "expires_at_ms": ...}], these two members in this
    order. [scope] is the object {!Authz_scope_body} reads, and
    [expires_at_ms] is milliseconds since the epoch, or [null] for a PAT that
    does not expire. There is no default scope: a body without one is a 400
    (design 4.4). An expiry that is not after now is a 400.

    The answer is a 200 [{"pat_id": ..., "token": ...}]. This is the only time
    the token leaves the server. A person who is not active is a 403. *)
val issue : Login_routes.t -> Authz_browser_request.request -> body:string -> Login_routes.answer

(** The PATs of the person of the session, in the order of their ids:
    [{"pats": [...]}], each [{"pat_id", "scope", "expires_at_ms",
    "issued_at_ms", "status"}]. [status] is what {!Authz_pat_state.find_active}
    says now: ["open"], ["expired"] or ["revoked"]. No token and no digest is
    in the answer. *)
val list : Login_routes.t -> Authz_browser_request.request -> Login_routes.answer

(** [pat_id] is the [<id>] of the path; one that is not an id is a 400. The
    answer is a 204, a 404 for an id that names no PAT of this person, and a
    409 for a PAT that is revoked already. The PAT of another person gets the
    same 404 as an id that names nothing, so the answer says nothing of other
    people's PATs. *)
val revoke : Login_routes.t -> Authz_browser_request.request -> pat_id:string -> Login_routes.answer
