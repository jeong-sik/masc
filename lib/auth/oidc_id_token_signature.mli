(* HIGH-RISK-UNREVIEWED: decides whether an OIDC ID token was signed by a key
   the identity provider published. A wrong answer here logs someone in as a
   person who never authenticated. *)

(** Signature and expiry check of an OIDC ID token against a JWKS (design 5.2).

    Only the part that needs a crypto library lives here. The payload this
    returns was signed by a key in the JWKS and has not expired. It is not yet
    known to belong to this login: the login flow checks the issuer, the
    audience, the nonce, and the subject on it.

    Only RS256 is accepted, because that is what the provider signs with. The
    algorithm comes from the allow list here, not from the token: [none], the
    HMAC family, and every other algorithm are refused before any key is
    looked up. The key must be an RSA key of 2048 bits or more (RFC 7518
    section 3.3) whose [alg] is RS256 and whose [use] is [sig]. The library
    fills in the missing one when only one is given. A symmetric
    key, an encryption key, or a key that names another algorithm, listed
    under the same [kid], never verifies a token. The signature always uses
    SHA-256. The token must be in the canonical compact form: three unpadded
    base64url segments.

    The library this builds on leaves gaps that this module closes:
    - Its expiry check passes a token without [exp] and raises on an [exp]
      that is not an integer. Here [exp] must be a JSON integer.
    - It raises on input it cannot read: a token whose header or payload is
      not JSON, a JWKS that is not well formed, an EC key whose point it
      cannot read. Here each of those is an error and
      {!verify_signature_and_expiry} does not raise.
    - A key with neither [alg] nor [use] accepts a SHA-384 or SHA-512
      signature under an RS256 header, and an entry with [alg] RS256 and [use]
      [enc] verifies. Here those keys are refused.
    - It does not read a [crit] header. Here a token that has one is refused.
    - It accepts a trailing "=", a dangling last character, and nonzero
      padding bits in a segment, so one token has many spellings. Here only
      the canonical spelling is accepted.
    - It takes the first of two members with the same name, while RFC 7515
      section 4 and RFC 7519 section 4 tell a parser to reject the repeat or
      keep the last. Here a header or a payload that repeats a top-level
      member name is refused, so no reader of the payload can see a value the
      others do not.

    Not checked here: [nbf] and [iat], which the login flow can read from the
    payload, and [key_ops]. The caller bounds the size of the token and of the
    JWKS. *)

(** The constructors are listed in the order the checks run. *)
type error =
  | Malformed_token
      (** Not three compact segments, a segment that is not canonical
          unpadded base64url, a header or payload that is not JSON, one that
          repeats a top-level member name, or a header the library cannot
          read: an unknown [enc], an EC key it cannot read in the [jwk]
          field. *)
  | Algorithm_not_allowed  (** The header algorithm is not RS256. *)
  | Unsupported_critical_header
      (** The header has a [crit] list. RFC 7515 4.1.11 makes a token invalid
          when it names an extension the verifier does not support, and this
          module supports none. *)
  | Missing_key_id
  | Malformed_jwks
      (** Not JSON, no [keys] list, an entry without a [kty], or an EC entry
          whose point the library cannot read (off the curve, or a coordinate
          shorter than the curve size). One such entry refuses the whole
          document. An entry whose key material is unreadable in another way
          is dropped instead, so it ends as {!Unknown_key_id}. *)
  | Unknown_key_id  (** No readable JWKS entry carries the [kid]. *)
  | Key_not_rs256
      (** The entry for the [kid] is not an RSA key with [alg] RS256 and [use]
          [sig]. *)
  | Key_too_short
      (** The entry for the [kid] is an RSA key as above, with a modulus of
          fewer than 2048 bits. *)
  | Invalid_signature
  | Invalid_expiry
      (** [exp] is missing, is not an integer, or is out of range, or the
          payload is not a JSON object. A whole number too large for an OCaml
          [int] counts as not an integer. *)
  | Expired  (** [exp] is not later than [now]. *)

val error_to_string : error -> string

(** [verify_signature_and_expiry ~jwks ~now token] checks [token] against the
    JWKS document [jwks] and returns its payload. The checks run in the order
    of the constructors of {!error}, and the first failure is the result. The
    token is read before the JWKS, so a token without [kid] gets
    {!Missing_key_id} even when the JWKS is not JSON. [exp] is read after the
    signature, so it is only believed on a payload a key of the provider
    signed. When several entries carry the token's [kid], the first one is
    used. The caller reads the JWKS from the provider and keeps it fresh.
    Nothing here uses the network. *)
val verify_signature_and_expiry
  :  jwks:string
  -> now:Ptime.t
  -> string
  -> (Yojson.Safe.t, error) result
