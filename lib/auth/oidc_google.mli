(* HIGH-RISK-UNREVIEWED: decides which Google account an ID token names and
   whether the token was issued for this login. A wrong answer logs someone in
   as another person. *)

(** What Google declares about its ID tokens, and the claim check of the login
    flow (design 5.2, plan C2a-1).

    {!Oidc_id_token_signature} has checked the signature and the expiry. This
    module checks the claims that tie the token to this login, in this order:
    - [iss] is [https://accounts.google.com] or [accounts.google.com], the two
      values Google documents. It is only checked here: the identity is a
      Google one because the Google flow ran, not because of this string
      (design 6, decision 8).
    - [aud] is one string, the client ID of this installation. A list is
      refused: this installation asks for tokens with its own client ID only,
      so a token for several audiences was not issued for it, and [azp] never
      has to be read.
    - [nonce] is the nonce of the login transaction.
    - [sub] is a Google [sub] that {!Authz_external_identity.google} accepts.

    [iat], [nbf], [email], and [hd] are not read: the validation steps of
    Google do not ask for the first two, and an email is not an identity key
    (design 5.1-4). Source: Google's OpenID Connect guide,
    https://developers.google.com/identity/openid-connect/openid-connect,
    read 2026-11-06.

    No network, no clock. *)

type error =
  | Payload_not_an_object
  | Issuer_not_google  (** [iss] is missing, not a string, or another value. *)
  | Audience_is_a_list
  | Audience_not_this_client
      (** [aud] is missing, not a string, or another client ID. *)
  | Nonce_differs  (** [nonce] is missing, not a string, or another value. *)
  | Subject_not_a_string  (** [sub] is missing or not a string. *)
  | Subject_invalid of Authz_external_identity.error

val error_to_string : error -> string

(** [identity ~client_id ~nonce payload] is the Google identity that [payload]
    names, if its claims are those of a token Google issued for this login. The
    checks run in the order of the constructors of {!error}, and the first
    failure is the result. A payload whose top-level member names repeat never
    gets here: {!Oidc_id_token_signature} refuses it. *)
val identity
  :  client_id:string
  -> nonce:string
  -> Yojson.Safe.t
  -> (Authz_external_identity.t, error) result
