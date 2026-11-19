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

type cache_capacity =
  | Unbounded
  | Max_entries of int
(** Declared cache capacity bound. [Max_entries n] requires [n > 0] (invalid
    values raise [Invalid_argument]). Expired entries are always pruned before
    evicting the least-recently-used live entry. *)

type config =
  { success_ttl_sec : float
  ; failure_ttl_sec : float
  ; capacity : cache_capacity
  }

val create :
  ?success_ttl_sec:float ->
  ?failure_ttl_sec:float ->
  ?capacity:cache_capacity ->
  fetch:
    (user_id:string ->
     (Slack_rest_client.user_info_ok, Slack_rest_client.error) result) ->
  now:(unit -> float) ->
  unit ->
  t
(** [fetch] and [now] are injected so cache behavior is deterministic under
    test; production passes {!Slack_rest_client.users_info} and
    [Unix.gettimeofday]. *)

val create_with_config :
  config:config ->
  fetch:
    (user_id:string ->
     (Slack_rest_client.user_info_ok, Slack_rest_client.error) result) ->
  now:(unit -> float) ->
  unit ->
  t
(** Same as {!create} configured from an explicit {!config} record. *)

val config : t -> config
(** Resolved cache configuration. *)

val cache_size : t -> int
(** Current number of entries retained in the directory cache. *)

val display_label : t -> user_id:string -> string option
(** The user's display label by Slack's documented precedence
    ([profile.display_name], then [profile.real_name], then the legacy
    handle). [None] when the lookup failed or no name is usable — callers
    render the raw id. Serves from cache within the TTLs; fetches otherwise. *)

(** Who the bot's own mention stands for in one message: the connector-wide
    rule of {!Connector_self_mention}. [Bot_user_id_unknown] is the case where
    [auth.test] gave no bot user id; every mention then renders through the
    directory. *)
type self = Connector_self_mention.t =
  | Bot_user_id_unknown
  | Bound_keeper of { bot_user_id : string; keeper_name : string }

val rewrite_mentions : t -> self:self -> string -> string
(** Rewrites [<@U…>] and [<@U…|label>] mention escapes to [@label]. A
    mention whose id equals [self]'s [bot_user_id] renders as
    [@keeper_name] instead of the bot's Slack name. Channel, special and link
    escapes ([<#…>], [<!…>], [<http…>]) pass through unchanged, as does any
    other mention whose id cannot be resolved. *)

val label_of_user_info : Slack_rest_client.user_info_ok -> string option
(** Display precedence over one [users.info] record, exposed for unit
    tests. *)
