# Antigravity local account identity boundary

Primary observation on 2026-09-27: installed `agy --version` reports `1.2.11`.
The selected default file at `$HOME/.gemini/antigravity-cli/antigravity-oauth-token`
was inspected read-only, emitting keys and types only. No values, hashes of real
credentials, decoded subjects, email addresses, or keychain contents were recorded.

Observed source structure:

```text
object
  token: object
    access_token: string
    token_type: string
    refresh_token: string
    expiry: string
  auth_method: string
  id_token: string (three compact segments)
ID token header keys/types: alg:string, kid:string, typ:string
ID token payload keys/types: iss:string, azp:string, aud:string, sub:string,
  email:string, email_verified:boolean, at_hash:string, iat:integer, exp:integer
```

[Google's OpenID reference](https://developers.google.com/identity/openid-connect/reference)
defines `sub` as a stable account identifier and permits the issuer spellings
`accounts.google.com` and `https://accounts.google.com`. The implementation
canonicalizes those issuer spellings and hashes the issuer/subject pair for local
session continuity. It does not use token bytes, expiry, issuance time or email as
identity. The selected private file is validated before managed account directory
creation; missing, ambiguous or unsupported identity refuses admission.

This local credential selection comparison is not signature validation or an
authentication/readiness result. The native client owns authentication and refresh;
actual runtime verification proves usable provider/tool access separately. Tests
use synthetic native JSON and synthetic compact tokens, never real credentials.
The Keeper regression distinguishes native credential refresh, source credential
refresh (same principal, Resume), and source principal replacement (new HOME, Start).
Fusion observes the actual selected child HOME and retained native token across
source refresh, followed by a new generation on principal replacement.
