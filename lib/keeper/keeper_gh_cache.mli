(** In-memory cache of valid GH PR/issue numbers per repo.

    Populated lazily via [gh api repos/{slug}/pulls|issues?state=all]
    (REST, not GraphQL -- GraphQL has known false negatives, see
    masc-mcp board post p-10f3f0914beeb9e0d22f80e0b0e107a8).

    Used by [handle_keeper_github] to reject hallucinated PR/issue
    numbers BEFORE invoking gh, and return the valid number list as
    alternatives. Works regardless of LLM instruction-following quality.

    Thread-safety: mutex-protected, shared across all keepers.

    Fail-open: cache fetch failures return [`Unknown], which the caller
    interprets as "proceed with normal execution". *)

type entity_kind = PR | Issue

type validation_result =
  [ `Valid
  | `Invalid of int list
    (** number not in cache; caller SHOULD return valid alternatives *)
  | `Unknown
    (** cache fetch failed or returned empty; caller SHOULD fallthrough *)
  ]

val validate_number :
  config:Room.config ->
  repo_slug:string ->
  kind:entity_kind ->
  number:int ->
  validation_result
(** Check whether [number] is a known-valid PR/issue for [repo_slug].

    On first call for a given [(repo_slug, kind)] the cache is populated
    via a subprocess [gh api] call. Subsequent calls within the TTL
    window (120 s) are served from memory. *)

val invalidate : repo_slug:string -> kind:entity_kind -> unit
(** Clear the cache entry for [(repo_slug, kind)]. Call this after a
    successful mutation (pr create, issue create, pr close) so the next
    validation picks up the new/removed number. *)

val metrics : unit -> (string * int) list
(** Return [("hits", n); ("misses", n); ("bypasses", n); ("fetch_errors", n)].

    [hits]          number was in cache and valid
    [misses]        number was NOT in cache (hallucination detected)
    [bypasses]      cache empty or fetch failed (command proceeded normally)
    [fetch_errors]  gh api subprocess failed *)
