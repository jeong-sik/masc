(* HIGH-RISK-UNREVIEWED: an Admin's browser writes the allowlist through these
   routes. An entry lets its identity join the installation as a Member. *)

(** What the allowlist routes answer (plan C3-9): [POST /api/v1/auth/allowlist]
    registers an identity, [DELETE /api/v1/auth/allowlist/<id>] removes an
    entry ({!Authz_allowlist}, plan C2d-8), and [GET /api/v1/auth/allowlist]
    lists the entries (plan L2d).

    A write acts through a browser session ({!Login_routes.acting}): it
    changes something, so it comes from this origin with the CSRF token of the
    session. The session's principal is the author of the record, and the
    state decides whether that principal is an Admin. Every answer is JSON
    with [cache-control: no-store]; a refusal is [{"error": ...}].

    Like {!Login_routes}, this module holds no HTTP type, and the routes are
    registered at boot (S1). *)

(** [body] is the identity as JSON: [{"provider":"google","sub":...}] or
    [{"provider":"github","user_id":...}], with no other member; anything else
    is a 400. The answer is a 200
    [{"registration_id": ..., "previously_deleted": ...}]; [previously_deleted]
    says that a deleted principal had this identity (design 5.1-6). A
    principal that is not an Admin gets a 403, and an identity that is bound
    or already has an open entry a 409. *)
val register : Login_routes.t -> Authz_browser_request.request -> body:string -> Login_routes.answer

(** [/api/v1/auth/allowlist], the path of the collection. An entry is at
    [<path>/<registration_id>]. *)
val path : string

(** The entries of the allowlist for an Admin's browser: a 200
    [{"registrations": [...]}], one object per registration in the order of the
    ids, removed and spent ones included. An entry has [registration_id],
    [identity] (the body {!register} takes), [registrar] (the user id of the
    Admin who registered it), [status] and, when spent, the [user_id] of
    the principal that the admission made. [status] is ["open"],
    ["removal_pending"] (open, but its removal was not recorded and the
    external store holds it: no one joins through it, and a remove retries
    it, design 8.3), ["removed"] or ["consumed"]. The request is a read ({!Authz_browser_request.Safe}), so
    it needs no CSRF token; the session and the role are read in one trusted
    snapshot ({!Login_routes.admin_reading}). A principal that is not an
    Admin gets a 403. *)
val list : Login_routes.t -> Authz_browser_request.request -> Login_routes.answer

(** [registration_id] is the [<id>] of the path; one that is not an id is a
    400. The answer is a 204, a 404 for an id the allowlist never had, and a
    409 for an entry that was removed or spent. *)
val remove : Login_routes.t -> Authz_browser_request.request -> registration_id:string -> Login_routes.answer
