(** Lane Add-on web-search service port — the secret-free half a
    [world.web_search] package speaks (task-2527 E11).

    A package that declares [world.web_search] lists {!t} requests
    through [lane_host_requests]; the host runs its existing
    {!Tool_misc_web_search} provider chain — credentials, cache, rate
    limit and fallback plan stay on the host — and delivers the
    {!result} envelope. The envelope embeds the serving provider's own
    typed result data under [search] (rows, or the grounded
    [context_text] envelope), so result identity and sources are
    preserved, not summarised. No field of this port carries a secret.

    Cache identity follows the host tool: a repeated (query, limit,
    provider plan) request inside the host cache window is answered
    from the cache, visibly marked with [cache_hit = true]. The host
    cancellation policy is the tool's; an abandoned request is retried
    at the next cycle, at most once per cycle. *)

type request = {
  request_id : string;
  query : string;
  limit : int option;
}
(** The package's request. [request_id] must be unique per listing, like
    every host request kind. [limit] is the host tool's [\[1, 10\]] clamp,
    default 5 when absent. *)

val request_id : request -> string

val request_to_json : request -> Yojson.Safe.t
(** The [lane_host_requests] listing entry: exactly
    [{"kind": "web_search", "request_id", "query"}] plus
    [{"limit", int}] when present. *)

val request_of_json : Yojson.Safe.t -> (request, string) Stdlib.result
(** The host's projection of a listed request; the inverse of
    {!request_to_json}. Exact: an unknown key is refused whole, the
    [kind] stamp included. *)

type result = {
  serving_provider : string option;
  provider_errors : (string * string) list;
  search : Yojson.Safe.t;
}
(** What the host chain produced: the serving provider ([None] means the
    chain answered without a usable provider identity), every per-provider
    error the chain kept, and the serving provider's own result data. *)

val result_to_json : result -> Yojson.Safe.t
(** The delivered result body. *)

val result_of_json : Yojson.Safe.t -> (result, string) Stdlib.result
(** The host's projection of what it delivered; the inverse of
    {!result_to_json}. Exact: an unknown key is refused whole. *)

val plan_summary : ?limit:int -> string -> Yojson.Safe.t
(** The package-side view of a planned request: query and limit. It is a
    display projection, not a result identity — cache identity stays the
    host tool's (query, limit, provider plan) key. *)
