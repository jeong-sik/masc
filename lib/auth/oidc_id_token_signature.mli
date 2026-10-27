(* HIGH-RISK-UNREVIEWED: decides whether an OIDC ID token was signed by a key
   the identity provider published. A wrong answer here logs someone in as a
   person who never authenticated. *)

(** Signature and expiry check of an OIDC ID token against a JWKS (design 5.2).

    Only the part that needs a crypto library lives here. The claims that bind
    a token to one login (issuer, audience, nonce, subject) are checked by
    the login flow on the payload this returns.

    Only RS256 is accepted, because that is what the provider signs with. The
    algorithm comes from the allow list here, not from the token: [none], the
    HMAC family, and every other algorithm are refused before any key is
    looked up. The key must be an RSA key whose [alg] is RS256 and whose [use]
    is [sig]. The library fills in either one from the other when only one is
    given. A symmetric key, an encryption key, or a key that names another
    algorithm, listed under the same [kid], never verifies a token. The
    signature always uses SHA-256. The token must be in the canonical compact
    form: three unpadded base64url segments.

    The library this builds on leaves gaps that this module closes:
    - Its expiry check passes a token without [exp] and raises on an [exp]
      that is not an integer. Here [exp] must be a JSON integer.
    - It raises on input it cannot read: a token whose header or payload is
      not JSON, a JWKS that is not well formed, an EC key whose point it
      cannot read. Here each of those is an error and [verify] does not raise.
    - A key with neither [alg] nor [use] accepts a SHA-384 or SHA-512
      signature under an RS256 header, and an entry with [alg] RS256 and [use]
      [enc] verifies. Here those keys are refused.
    - It does not read a [crit] header. Here a token that has one is refused.
    - It accepts a trailing "=", a dangling last character, and nonzero
      padding bits in a segment, so one token has many spellings. Here only
      the canonical spelling is accepted.

    Not checked here: [nbf] and [iat], which the login flow can read from the
    payload, the size of the RSA key, and [key_ops]. A member name that
    appears twice in the header or the payload takes its first value, as in
    the library. The caller bounds the size of the token and of the JWKS. *)

type error =
  | Malformed_token
      (** Not three compact segments, a segment that is not canonical
          unpadded base64url, or a header or payload the library cannot read:
          not JSON, an unknown [enc], an EC key it cannot read in the [jwk]
          field. *)
  | Malformed_jwks
      (** Not JSON, no [keys] list, an entry without a [kty], or an EC entry
          whose point the library cannot read (off the curve, or a coordinate
          shorter than the curve size). One such entry refuses the whole
          document. An entry whose key material is unreadable in another way
          is dropped instead, so it ends as {!Unknown_key_id}. *)
  | Algorithm_not_allowed  (** The header algorithm is not RS256. *)
  | Unsupported_critical_header
      (** The header has a [crit] list. RFC 7515 4.1.11 makes a token invalid
          when it names an extension the verifier does not support, and this
          module supports none. *)
  | Missing_key_id
  | Unknown_key_id  (** No readable JWKS entry carries the [kid]. *)
  | Key_not_rs256
      (** The entry for the [kid] is not an RSA key with [alg] RS256 and [use]
          [sig]. *)
  | Invalid_signature
  | Invalid_expiry
      (** [exp] is missing, not an integer, or out of range, or the payload is
          not a JSON object. *)
  | Expired  (** [exp] is not later than [now]. *)

val error_to_string : error -> string

(** [verify ~jwks ~now token] checks [token] against the JWKS document [jwks]
    and returns its payload. When several entries carry the token's [kid], the
    first one is used. The caller reads the JWKS from the provider and keeps it
    fresh. Nothing here uses the network. *)
val verify : jwks:string -> now:Ptime.t -> string -> (Yojson.Safe.t, error) result
