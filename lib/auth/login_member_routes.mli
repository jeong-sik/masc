(* HIGH-RISK-UNREVIEWED: an Admin's browser reads through this route who the
   people of the installation are, which identity each is bound to, and who is
   an Admin. *)

(** What the member routes answer (plan L2d & lifecycle routes):
    - [GET /api/v1/auth/members] lists the people of the installation for an
      Admin ({!list}). The request is a read ({!Authz_browser_request.Safe}),
      so it needs no CSRF token.
    - [POST /api/v1/auth/members/<id>/disable] disables a principal ({!disable}).
    - [POST /api/v1/auth/members/<id>/enable] re-enables a disabled principal
      ({!enable}).
    - [POST /api/v1/auth/members/<id>/revoke-admin] revokes an Admin assignment
      with a required closed-sum cause ({!revoke_admin}).
    - [DELETE /api/v1/auth/members/<id>] deletes a principal ({!delete}).

    The four mutations require an active, non-held Admin browser session on the
    same origin with a valid CSRF token ({!Login_routes.acting_reading} plus
    the writer zone commit). Every answer carries [cache-control: no-store]; a
    refusal is JSON [{"error": ...}].

    Like {!Login_routes}, this module holds no HTTP type. *)

(** [/api/v1/auth/members]. *)
val path : string

(** A 200 [{"members": [...]}], one object per principal in the order of the
    user ids. A deleted principal is not listed. A member has [user_id],
    [identity] (the identity it is bound to, in the body shape of
    {!Login_allowlist_routes.register}), [role] (["admin"] while an Admin
    assignment is in force, which a disabled Admin keeps, or ["member"]),
    [status] (["active"] or ["disabled"]) and [held]: the reductions of the
    principal that the log did not record and the external store holds
    (design 8.3), by the label of their change in the store, sorted, each
    once: ["revoke"] (the end of an Admin assignment), ["disable"],
    ["delete"]. While [held] is not empty the principal does not act,
    whatever [status] says ({!Authz_state.revocation}). The same reduction
    made again closes the holds of its own change only. A principal that is
    not an Admin gets a 403. *)
val list : Login_routes.t -> Authz_browser_request.request -> Login_routes.answer

(** [POST /api/v1/auth/members/<id>/disable]. Commits
    {!Authz_principal_event.Disabled}. Answers 200
    [{"user_id": ..., "status": "disabled"}], 400 on an invalid [user_id],
    401/403 on authentication, CSRF, origin, or non-Admin refusal, 404 when
    the principal does not exist, 409 when already disabled or when disabling
    would leave no active Admin, and 503 when the zone is unavailable. *)
val disable
  :  Login_routes.t
  -> Authz_browser_request.request
  -> user_id:string
  -> Login_routes.answer

(** [POST /api/v1/auth/members/<id>/enable]. Commits
    {!Authz_principal_event.Enabled}. Answers 200
    [{"user_id": ..., "status": "active"}], 400 on an invalid [user_id],
    401/403 on authentication, CSRF, origin, or non-Admin refusal, 404 when
    the principal does not exist, 409 when the principal is not disabled, and
    503 when the zone is unavailable. *)
val enable
  :  Login_routes.t
  -> Authz_browser_request.request
  -> user_id:string
  -> Login_routes.answer

(** [POST /api/v1/auth/members/<id>/revoke-admin]. Parses [body] strictly as
    [{"cause": "security_incident"}] or [{"cause": "operational"}] with no
    default or extra fields, and commits {!Authz_admin_event.Revoked}. Answers
    200 [{"user_id": ..., "role": "member", "cause": ...}], 400 on an invalid
    [user_id] or body, 401/403 on authentication, CSRF, origin, or non-Admin
    refusal, 409 when the principal has no Admin assignment or is the last
    active Admin, and 503 when the zone is unavailable. *)
val revoke_admin
  :  Login_routes.t
  -> Authz_browser_request.request
  -> user_id:string
  -> body:string
  -> Login_routes.answer

(** [DELETE /api/v1/auth/members/<id>]. Commits
    {!Authz_principal_event.Deleted} with the principal's bound identity.
    Answers 204 with an empty body on success, 400 on an invalid [user_id],
    401/403 on authentication, CSRF, origin, or non-Admin refusal, 404 when
    the principal does not exist, 409 when deleting would leave no active
    Admin or the bound identity changed concurrently, and 503 when the zone
    is unavailable. *)
val delete
  :  Login_routes.t
  -> Authz_browser_request.request
  -> user_id:string
  -> Login_routes.answer
