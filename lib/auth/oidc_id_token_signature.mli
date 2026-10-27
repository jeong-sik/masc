(* HIGH-RISK-UNREVIEWED: decides whether an OIDC ID token was signed by a key
   the identity provider published. A wrong answer here logs someone in as a
   person who never authenticated. *)

(** Signature and expiry check of an OIDC ID token against a JWKS (design 5.2).

    Only the part that needs a crypto library lives here. The claims that bind
    a token to one login (issuer, audience, nonce, subject) are checked by the
    login flow on the payload this returns.

    Only RS256 is accepted, because that is what the provider signs with. The
    algorithm comes from the allow list here, not from the token: [none], the
    HMAC family, and every other algorithm are refused before any key is
    looked up. The key must be an RSA key that declares RS256, either with
    [alg] or with [use] set to [sig]. A symmetric key or an encryption key
    listed under the same [kid] never verifies a token, and the signature
    always uses SHA-256.

    The library this builds on leaves four gaps that this module closes:
    - A token without a usable [exp] counts as not expired there. Here an
      [exp] that is missing or is not a JSON integer is an error.
    - It raises on input it cannot read: a token whose header or payload is
      not JSON, a JWKS that is not well formed, an EC key that is not on the
      curve. Here each of those is an error and [verify] does not raise.
    - A key with neither [alg] nor [use] accepts a SHA-384 or SHA-512
      signature under an RS256 header. Here that key is refused.
    - It does not read a [crit] header. Here a token that has one is refused. *)

type error =
  | Malformed_token
      (** Not three compact segments, a segment that does not decode, or a
          header or payload the library cannot read: not JSON, an unknown
          [enc], an EC key off the curve in the [jwk] field. *)
  | Malformed_jwks
      (** Not JSON, no [keys] list, an entry without a [kty], or an EC entry
          off the curve. One such entry refuses the whole document. An entry
          whose key material is unreadable in another way is dropped instead,
          so it ends as {!Unknown_key_id}. *)
  | Algorithm_not_allowed  (** The header algorithm is not RS256. *)
  | Unsupported_critical_header
      (** The header has a [crit] list. RFC 7515 4.1.11 makes a token invalid
          when it names an extension the verifier does not support, and this
          module supports none. *)
  | Missing_key_id
  | Unknown_key_id  (** No readable JWKS entry carries the [kid]. *)
  | Key_not_rs256  (** The entry for the [kid] is not an RSA key that declares RS256. *)
  | Invalid_signature
  | Invalid_expiry
      (** [exp] is missing, not an integer, or out of range, or the payload is
          not a JSON object. *)
  | Expired  (** [exp] is not later than [now]. *)

val error_to_string : error -> string

(** [verify ~jwks ~now token] checks [token] against the JWKS document [jwks]
    and returns its payload. The caller reads the JWKS from the provider and
    keeps it fresh. Nothing here uses the network. *)
val verify : jwks:string -> now:Ptime.t -> string -> (Yojson.Safe.t, error) result
