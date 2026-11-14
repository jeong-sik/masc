(* HIGH-RISK-UNREVIEWED: an Admin's browser reads through this route who the
   people of the installation are, which identity each is bound to, and who is
   an Admin. *)

(** What the member route answers (plan L2d): [GET /api/v1/auth/members] lists
    the people of the installation for an Admin. The session and the role are
    read in one trusted snapshot ({!Login_routes.admin_reading}). The request
    is a read ({!Authz_browser_request.Safe}), so it needs no CSRF token. Every
    answer is JSON with [cache-control: no-store]; a refusal is
    [{"error": ...}].

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
