(* HIGH-RISK-UNREVIEWED: decides whether a browser request in multi-account mode
   acts through its session cookie. A request this module lets through acts as
   the principal of the session. *)

(** The cookies of a browser login and the check of a request that carries
    the session cookie (design 5.2 and 5.3, plan C3-7).

    The routes of C3-8 write the cookies. {!check} is a function of what the
    server read from the request; the server reads the headers, and C4 puts
    the check on every request path ([Auth_gate.decide]). *)

(** [__Host-masc_session]. *)
val session_cookie : string

(** [__Host-masc_oidc_txn]. *)
val transaction_cookie : string

(** The header a page sends the CSRF token in: [x-masc-csrf-token]. *)
val csrf_header : string

(** [Set-Cookie] values. Every cookie is [Secure], [HttpOnly], host-only (no
    [Domain]) and [Path=/], as the [__Host-] prefix requires. The session
    cookie is [SameSite=Strict] and lasts {!Authz_session_state.lifetime_ms};
    the transaction cookie is [SameSite=Lax], so the redirect back from the
    provider carries it, and lasts {!Oidc_login_transaction.lifetime_ms}. A
    clear sets the value empty with [Max-Age=0]. *)
val set_session_cookie : Authz_browser_session.Cookie.t -> string

val clear_session_cookie : string
val set_transaction_cookie : Oidc_login_transaction.Id.t -> string
val clear_transaction_cookie : string

type method_ =
  | Safe  (** [GET] or [HEAD]: it changes nothing. *)
  | Unsafe  (** Any other method. *)

(** The [Origin] of the request, as the server classified it. A dev origin
    that single-user mode allows is [Other_origin] here: multi-account mode
    allows no credentialed cross-origin request (design 5.3). *)
type origin =
  | Same_origin
  | Other_origin  (** Another origin, several [Origin] fields, or one that does not parse. *)
  | No_origin

type request =
  { method_ : method_
  ; session_cookie : string option  (** The value of {!session_cookie}, if any. *)
  ; bearer : bool  (** An [Authorization] or an internal token header is there. *)
  ; query_credential : bool
        (** A credential in the query string: [token], [sse_kind=observer], or
            the IDE LSP token. *)
  ; origin : origin
  ; csrf : string option  (** The value of {!csrf_header}, if any. *)
  }

type refusal =
  | Query_credential
      (** Multi-account mode reads no credential from a query string
          (design 5.2). *)
  | Session_and_bearer
      (** Two credentials: the cookie does not win over the bearer, nor the
          bearer over the cookie (design 5.2). *)
  | Not_a_session_cookie  (** The cookie is there, and its value is not one. *)
  | Cross_origin
  | Origin_missing  (** A request that changes something names no origin. *)
  | Csrf_missing
  | Csrf_differs
  | Session_refused of Authz_browser_session.refusal

val refusal_to_string : refusal -> string

(** [true] for the refusals of a request without a working session (401);
    [false] for those of a request whose origin or CSRF token is wrong (403).
    A refusal for the origin or the token keeps the session of the browser. *)
val is_unauthenticated : refusal -> bool

type verdict =
  | No_session
      (** The request has no session cookie; the other credentials decide
          (C4). *)
  | Session of
      { cookie : Authz_browser_session.Cookie.t
      ; signed_in : Authz_browser_session.signed_in
      }

(** The checks run in this order: a query credential, a bearer beside the
    cookie, the cookie value, the origin, and for an {!Unsafe} request the
    origin again (it must be there) and the CSRF token, and last the session
    in the trusted snapshot at [now_ms]. A request with the cookie needs the token whether
    or not it also carries a bearer (design 5.3), and a {!Safe} request with
    the cookie needs no token because it changes nothing. *)
val check : Authz_zone.trusted -> now_ms:int -> request -> (verdict, refusal) result
