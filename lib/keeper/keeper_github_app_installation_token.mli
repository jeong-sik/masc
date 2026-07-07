(** GitHub App installation access token issuance + per-installation cache.

    A GitHub App installation token is the scoped, short-lived credential git
    (via the RFC-0236 §3 credential helper) consumes as [GH_TOKEN]. This module
    mints it with [POST /app/installations/{id}/access_tokens] and caches the
    result per installation. See RFC-0236 §10. *)

val mint_timeout_sec : float
(** Existing outbound HTTP pool liveness boundary used for installation-token
    mint requests. *)

val mint :
  clock:[> float Eio.Time.clock_ty ] Eio.Resource.t ->
  timeout_sec:float ->
  app_id:string ->
  installation_id:string ->
  pem:string ->
  now:int ->
  unit ->
  (string, string) result
(** [mint ~clock ~timeout_sec ~app_id ~installation_id ~pem ~now ()] ignores the
    cache and requests a fresh installation token. Signs the App JWT via
    {!Keeper_github_app_jwt.sign}, then [POST]s to GitHub. Returns [Ok token]
    on HTTP 201 with a parseable [token] field, or [Error reason] on JWT
    failure, transport failure, non-201 status, or a malformed response. The
    returned token is the value to project as [GH_TOKEN]. *)

val get :
  clock:[> float Eio.Time.clock_ty ] Eio.Resource.t ->
  timeout_sec:float ->
  app_id:string ->
  installation_id:string ->
  pem:string ->
  now:int ->
  unit ->
  (string, string) result
(** [get] returns a cached token whose 55-minute validity window (1h lifetime
    minus a 5-minute refresh skew) has not elapsed, minting and caching a fresh
    token otherwise. The cache is keyed by [app_id ^ ":" ^ installation_id].
    The process-wide mutex guards only cache lookup/store; it is never held
    across the GitHub HTTP request, so unrelated keepers are not blocked by a
    slow mint. [pem] is consumed only on a mint. *)
