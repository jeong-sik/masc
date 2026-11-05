(** The process's provider connection cache (RFC-0492 §3.1).

    The server installs one cache at startup. Every provider transport that
    {!Runtime_agent} builds after that on the installing domain takes its
    idle connections from it, so Keepers that call the same origin share
    connections.

    A cached connection's fibers run on the cache's switch, and Eio refuses a
    switch from another domain. A transport built on any other domain gets no
    cache: each of its requests opens its own connection and closes it, as
    every request does when no cache is installed. *)

val install :
  sw:Eio.Switch.t -> clock:_ Eio.Time.clock -> idle_ttl_seconds:float -> unit
(** Creates a cache on [sw] and installs it for the calling domain, replacing
    any cache installed before. Its idle connections close after
    [idle_ttl_seconds]. The eviction fiber starts on [sw], so a call from a
    domain that does not own [sw] raises [Invalid_argument]. *)

val for_this_domain : unit -> Llm_provider.Http_client.cache option
(** The installed cache when the calling domain installed it. *)

val stats : unit -> Llm_provider.Http_client.cache_stats option
(** The installed cache's statistics. Any domain may read them. *)
