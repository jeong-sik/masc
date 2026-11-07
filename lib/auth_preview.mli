(* HIGH-RISK-UNREVIEWED: [whoami] tells a browser who the server takes it for,
   and the pages start a login and sign a browser out. *)

(** The pages and the who-am-I answer of the localhost preview of
    multi-account login (plan, preview scope P2).

    Each value is an answer of {!Login_routes}, so the server writes it as it
    writes a login answer. This module holds no HTTP type: the preview command
    (P3) reads the request and registers the routes.

    The pages hold no request data. The invitation token stays in the
    fragment of the link ({!Authz_activation.link}), which the browser does
    not send, and the script of the invitation page copies it into the form.
    The CSRF token of a sign-out comes from [GET /auth/session]. *)

(** [GET /accounts/invite], the page that an invitation link opens: a form
    that starts a GitHub login with the token of the link. [nonce] is the
    nonce of its script. *)
val invite_page : nonce:string -> Login_routes.answer

(** [GET /]: the session of the browser and who the server takes it for, a
    form that starts a GitHub login, and a sign-out button. *)
val home_page : nonce:string -> Login_routes.answer

(** [GET /api/v1/auth/whoami], judged as [Read_auth] by {!Auth_gate.decide}.
    A 200 JSON [{"principal": ..., "role": ..., "binding": ...}], or a JSON
    [{"error": ...}] with a 401 or a 403 ({!Auth_gate.is_unauthenticated}). *)
val whoami : Authz_state.t -> now_ms:int -> Auth_gate.request -> Login_routes.answer
