(* HIGH-RISK-UNREVIEWED: answers the routes that sign a browser in and out. A
   callback that this module answers with a session cookie lets that browser
   act as a principal. *)

(** What the login routes answer (design 5.2 and 5.2.1, plan C3-8): the start
    and the callback of the Google and the GitHub login, the sign-out, and the
    session of a browser.

    Each function takes what the server read from the request and gives the
    answer as a value. This module holds no HTTP type: the server reads the
    request, writes the answer, and registers the routes (S1), and the tests
    call it with a zone on real files and providers that the tests play.

    No answer carries a token, a secret, a code or a provider error: a refused
    login gets a page with a sentence for its status. That page and the page
    of a completed login are written in the frame of {!Account_page}, under a
    policy that lets a browser apply the one sheet of that frame. *)

type status =
  | Ok_200
  | No_content_204
  | See_other_303
  | Bad_request_400
  | Unauthorized_401
  | Forbidden_403
  | Not_found_404
  | Conflict_409
  | Too_many_requests_429
  | Internal_error_500
  | Bad_gateway_502
  | Service_unavailable_503
  | Gateway_timeout_504

val status_code : status -> int

type answer =
  { status : status
  ; headers : (string * string) list
        (** Lowercase names. Every answer has [cache-control: no-store].
            [set-cookie] may come more than once. *)
  ; body : string
  }

type provider =
  | Google
  | Github

type google_login =
  { client : Login_client.t
  ; cache : Oidc_google_exchange.cache
  }

(** What the routes share, made once at boot (S1). A provider whose login is
    [None] is not configured, and its routes answer 404. *)
type t =
  { zone : Authz_zone.t
  ; transactions : Oidc_login_transaction.t
  ; google : google_login option
  ; github : Login_client.t option
  ; get : Login_transport.get
  ; post : Login_transport.post
  ; now : unit -> Ptime.t  (** The wall clock. *)
  ; draw : unit -> string
        (** 32 random bytes as lowercase hex ({!Random_id.hex} in the server):
            user ids, namespaces, session ids, and the nonce of a page. *)
  }

(** [POST /auth/oidc/start] and [POST /auth/github/start].

    [fields] is the form of the request: [invite], the token of an invitation
    link, and [return_to], a local path ([/] when absent). Each is optional
    and comes at most once; another field, or one that does not parse, is a
    400. The request comes from this origin, or the answer is a 403, so a page
    elsewhere cannot start a login with an invitation of its choosing in a
    visitor's browser.

    A [session_cookie] that acts names the session that the sign-in ends
    ({!Oidc_login_transaction.taken}); one that does not act is not read
    further. Several session cookies are a 401: they name no one session
    to end. The answer is a 303 to the provider with the transaction
    cookie. A return path too long for that cookie
    ({!Oidc_login_transaction.max_sealed_length}) is a 400. *)
val start
  :  t
  -> provider
  -> origin:Authz_browser_request.origin
  -> session_cookie:Authz_browser_request.session_cookies
  -> fields:(string * string) list
  -> answer

(** [GET /auth/oidc/callback] and [GET /auth/github/callback].

    The transaction cookie is the only credential it reads (design 5.2).
    [query] is the query of the request: [state] once, and [code] or [error]
    once; other parameters are not read. A signed-in person gets a session,
    which ends the session that the start named if that one still acts. The
    answer is a 200 page that moves the browser to [return_to], so the next
    request is a same-site one that carries the [SameSite=Strict] session
    cookie. Every answer clears the transaction cookie.

    A refusal of the login is a 409 when another writer came first
    ({!Authz_login.is_conflict}), a 401 when the transaction, the provider or
    the code does not sign the person in, a 403 when the person may not sign
    in, a 502 when the provider does not answer, and a 503 when the log cannot
    be written. An admission written before the session fails to be issued
    stays: the person signs in again. *)
val callback
  :  t
  -> provider
  -> transaction_cookie:string option
  -> query:(string * string) list
  -> answer

(** [POST /auth/logout]. The request passes {!Authz_browser_request.check},
    so it carries the CSRF token. The answer is a 204 that clears the session
    cookie, or a JSON [{"error": ...}]. A cookie that does not act is cleared
    with its 401; a refusal for the origin or the token clears nothing, and
    neither does the 503 of a zone that cannot be trusted
    ({!zone_uncertain}). *)
val logout : t -> Authz_browser_request.request -> answer

(** [GET /auth/session]. The JSON
    [{"user_id": ..., "expires_at_ms": ..., "csrf_token": ...}] of the
    session, or a JSON [{"error": ...}] with a 401 or a 403, or the 503 of
    {!zone_uncertain}. A page reads the CSRF token here, as the cookie is
    HttpOnly. *)
val session : t -> Authz_browser_request.request -> answer

(** For the other routes a browser session calls (the allowlist of plan
    C3-9): the session that [request] acts through, and its cookie, or the
    JSON refusal that {!session} would give, a 401, a 403 or a 503. *)
val acting
  :  t
  -> Authz_browser_request.request
  -> (Authz_browser_session.Cookie.t * Authz_browser_session.signed_in, answer) result

(** A JSON object answer with [cache-control: no-store]. *)
val json : status -> (string * Yojson.Safe.t) list -> answer

(** What a person is told when a route decides on the authorization state
    and the zone cannot be trusted ({!Authz_zone.read}): one fixed sentence.
    The reason names a path of the server, so this writes it to the log and
    does not give it. *)
val zone_uncertain_message : Authz_zone.uncertain -> string

(** The answer of such a route: a 503 JSON [{"error": ...}] with the sentence
    of {!zone_uncertain_message}. *)
val zone_uncertain : Authz_zone.uncertain -> answer
