(** Slack_user_directory — inbound identity rendering for Slack user ids
    (issue #28376).

    Resolves [U…]/[W…] ids to display labels through an injected
    [users.info] fetch with a TTL cache, and rewrites [<@U…>] mention
    escapes into plain [@label] text. Rendering only: the raw id stays the
    identity key everywhere; an unresolvable id keeps its exact wire form. *)

type t

val default_success_ttl_sec : float
(** Seconds a resolved label serves from cache (3600). *)

val default_failure_ttl_sec : float
(** Seconds a failed lookup is not retried (300). Failure caching keeps a
    permanently failing id (e.g. missing [users:read] scope) from refetching
    on every inbound message, while still picking a fix up promptly. *)

val create :
  ?success_ttl_sec:float ->
  ?failure_ttl_sec:float ->
  fetch:
    (user_id:string ->
     (Slack_rest_client.user_info_ok, Slack_rest_client.error) result) ->
  now:(unit -> float) ->
  unit ->
  t
(** [fetch] and [now] are injected so cache behavior is deterministic under
    test; production passes {!Slack_rest_client.users_info} and
    [Unix.gettimeofday]. *)

val display_label : t -> user_id:string -> string option
(** The user's display label by Slack's documented precedence
    ([profile.display_name], then [profile.real_name], then the legacy
    handle). [None] when the lookup failed or no name is usable — callers
    render the raw id. Serves from cache within the TTLs; fetches otherwise. *)

val rewrite_mentions : t -> string -> string
(** Rewrites [<@U…>] and [<@U…|label>] mention escapes to [@label]. Channel,
    special and link escapes ([<#…>], [<!…>], [<http…>]) pass through
    unchanged, as does any mention whose id cannot be resolved. *)

val label_of_user_info : Slack_rest_client.user_info_ok -> string option
(** Display precedence over one [users.info] record, exposed for unit
    tests. *)
