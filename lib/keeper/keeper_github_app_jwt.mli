(** GitHub App JWT (RS256) signing for installation-token issuance.

    A GitHub App authenticates to the installation-token endpoint
    ([POST /app/installations/{id}/access_tokens]) with a short-lived
    RS256-signed JWT whose [iss] is the App ID and whose [exp] is within 10
    minutes of [iat]. This module mints that JWT from the App's PEM-encoded RSA
    private key.

    PEM decoding and the RSA primitive reuse {!X509.Private_key} and
    {!Mirage_crypto_pk.Rsa} rather than a hand-rolled DER parser — both PKCS#1
    ({ -----BEGIN RSA PRIVATE KEY----- }) and PKCS#8 ({ -----BEGIN PRIVATE
    KEY----- }) stanzas are accepted by {!X509.Private_key.decode_pem}, and the
    decoded [RSA] variant carries a {!Mirage_crypto_pk.Rsa.priv} directly. *)

val sign : app_id:string -> pem:string -> now:int -> unit -> (string, string) result
(** [sign ~app_id ~pem ~now ()] mints a RS256-signed GitHub App JWT.

    - [app_id] is the GitHub App identifier (the numeric string from the App's
      "About" panel; carried verbatim as the JWT [iss] claim).
    - [pem] is the PEM private key (PKCS#1 or PKCS#8 stanza).
    - [now] is the signing instant in Unix seconds, injected so the caller
      controls the clock (no hidden {!Unix.time} — deterministic for tests).
    - [exp] = [now + 540] (9 minutes); GitHub rejects a JWT whose [exp] exceeds
      [iat] by more than 10 minutes.

    Returns [Ok jwt] where [jwt = b64url(header) ^ "." ^ b64url(payload) ^ "."
    ^ b64url(signature)] (base64url with no padding), or [Error reason] when the
    PEM does not decode to an RSA key or the key is too small for SHA-256 (RSA
    [>=] 2048 bits). *)
