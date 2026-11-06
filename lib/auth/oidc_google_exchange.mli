(* HIGH-RISK-UNREVIEWED: turns the code of a Google callback into the identity
   of a person. It sends the client secret, and the keys it keeps decide which
   signatures are believed. *)

(** The exchange with Google of a login (design 5.2, plan C2a-3): the
    discovery document, the authorization request, the token exchange, and
    the keys that check the ID token.

    The ID token comes only from the answer of the token endpoint, which the
    server reads itself. A token from the browser is never read, so the key ID
    of a token that is checked is one that Google wrote, and nobody outside
    can make the keys be fetched again.

    The transport is a function, so this module does no I/O of its own and the
    tests answer for Google. The server passes calls of the shared HTTP client,
    bounded by {!max_document_bytes} and a timeout. *)

(** One answer of the transport. *)
type response =
  { status : int
  ; headers : (string * string) list
  ; body : string
  }

type get = url:string -> (response, string) result
type post = url:string -> headers:(string * string) list -> body:string -> (response, string) result

(** The client of this installation at Google. The secret is in no function
    out of it: it is only sent in the token request. *)
module Client : sig
  type t

  val make : client_id:string -> client_secret:string -> redirect_uri:string -> t
  val client_id : t -> string
  val redirect_uri : t -> string
end

(** The addresses that the discovery document gives, each an [https] URL with
    a host and no query or fragment. *)
type endpoints = private
  { authorization_endpoint : string
  ; token_endpoint : string
  ; jwks_uri : string
  }

(** 64 KiB. A discovery document, a JWKS, or a token answer longer than this is
    refused. Google's are a few KiB. *)
val max_document_bytes : int

(** The discovery document and the JWKS that were read, each kept as long as
    its [Cache-Control] allows. Reads and writes take a lock; the fetches run
    outside it. *)
type cache

val cache : unit -> cache

(** How long an answer with these headers may be kept: the [max-age] of
    [Cache-Control] in milliseconds. [None] when there is no such header,
    when it has [no-store] or [no-cache], or when [max-age] is not a whole
    number of seconds written as digits (RFC 9111 section 5.2). *)
val cache_lifetime_ms : (string * string) list -> int option

type error =
  | Discovery_unavailable of string  (** The transport failed, or the status was not 200. *)
  | Discovery_malformed of string
      (** Not a JSON object, or the named member is missing, is not an
          [https] URL, or ([issuer]) is not Google. *)
  | Token_unavailable of string  (** The transport failed. *)
  | Token_refused of
      { status : int
      ; error : string option  (** The [error] member of the answer (RFC 6749 section 5.2). *)
      }
  | Token_answer_malformed
      (** Status 200, and no [id_token] string of at most
          {!max_document_bytes}. *)
  | Keys_unavailable of string  (** The transport failed, or the status was not 200. *)
  | Signature_refused of Oidc_id_token_signature.error
  | Claims_refused of Oidc_google.error

val error_to_string : error -> string

(** The endpoints, from the cache while it is fresh at [now_ms] and from
    {!Oidc_google.discovery_url} otherwise. *)
val endpoints : get:get -> cache -> now_ms:int -> (endpoints, error) result

(** Where the start of a login sends the browser: the authorization endpoint
    with [response_type=code], the client ID, the redirect URI, [scope=openid],
    the state, the nonce, and the S256 challenge of the transaction. Only
    [openid] is asked for: the identity is [sub], and an email is not an
    identity key (design 5.1-4). *)
val authorization_url : endpoints -> Client.t -> Oidc_login_transaction.started -> string

(** The identity of the person who came back with [code]: the token exchange
    with the verifier of [taken], the signature and expiry check at [now], and
    the claim check with the nonce of [taken]. The JWKS comes from the cache
    while it is fresh at [now_ms]. If the cached JWKS has no key with the
    token's key ID, it is read once more, because Google rotates its keys; a
    JWKS read in this call is not read again. *)
val identity
  :  get:get
  -> post:post
  -> cache
  -> now:Ptime.t
  -> now_ms:int
  -> Client.t
  -> code:string
  -> Oidc_login_transaction.taken
  -> (Authz_external_identity.t, error) result
