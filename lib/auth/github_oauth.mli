(* HIGH-RISK-UNREVIEWED: turns the code of a GitHub callback into the identity
   of a person. It sends the client secret, and holds an access token for the
   one request that reads the user. *)

(** The exchange of a GitHub login with GitHub (design 5.2.1, plan C2b-2):
    the authorization request, the token exchange, and one [GET /user].

    The identity is the numeric user [id]. The [login] can change and an email
    is not an identity key, so neither is read. No scope is asked for: a token
    without scopes still authenticates as its owner and reads the public user.

    The access token serves that one request. It is not returned, kept, or
    written into an error.

    The four values below are GitHub's, from its documentation (checked
    2026-11-06). GitHub has no discovery document. The transport is
    {!Login_transport}, so this module does no I/O of its own and the tests
    answer for GitHub. *)

val authorize_url : string
val token_url : string
val user_url : string

(** The REST API version that [GET /user] asks for. Without the header GitHub
    answers as 2022-11-28, whose support ends on 2028-03-10. *)
val api_version : string

(** Where the start of a GitHub login sends the browser: {!authorize_url} with
    the client ID, the redirect URI, the state and the S256 challenge of the
    transaction. GitHub accepts no other challenge method. *)
val authorization_url : Login_client.t -> unit Oidc_login_transaction.started -> string

type error =
  | Token_unavailable of string
      (** The transport failed, or the answer is longer than
          {!Login_transport.max_answer_bytes}. *)
  | Token_refused of
      { status : int
      ; error : string option  (** The [error] member of the answer. *)
      }
      (** The answer is not status 200 with a non-empty [access_token]
          string. GitHub's documentation gives no status for its errors, so
          the answer decides and not the status alone. *)
  | User_unavailable of string
      (** The transport failed, the status was not 200, or the answer is too
          long. *)
  | User_answer_malformed  (** Not a JSON object with an integer [id]. *)
  | Identity_refused of Authz_external_identity.error
      (** The [id] is not positive, or above 2^53 - 1. *)

val error_to_string : error -> string

(** The identity of the person who came back with [code]: the token exchange
    with the verifier of [taken], then [GET /user] with the token. A refused
    token exchange reads no user. *)
val identity
  :  get:Login_transport.get
  -> post:Login_transport.post
  -> Login_client.t
  -> code:string
  -> unit Oidc_login_transaction.taken
  -> (Authz_external_identity.t, error) result
