(** The process's provider connection cache (RFC-0492 §3.1).

    The server installs one cache at startup. Every provider transport that
    {!Runtime_agent} builds after that on the installing domain takes its
    idle connections from it, so Keepers that call the same origin share
    connections.

    A new cached connection is opened on a switch that a daemon on the
    cache's switch runs, and Eio refuses a switch from another domain. A transport built on any other domain gets no
    cache: each of its requests opens its own connection and closes it, as
    every request does when no cache is installed. *)

val install :
  sw:Eio.Switch.t -> mono_clock:_ Eio.Time.Mono.t -> idle_ttl_seconds:float -> unit
(** Creates a cache on [sw] and installs it for the calling domain, replacing
    any cache installed before. A request takes only a connection idle for at
    most [idle_ttl_seconds] on [mono_clock], counted from when the cache
    parked it. The eviction fiber starts on [sw], so a call from
    a domain that does not own [sw] raises [Invalid_argument]. The cache is
    uninstalled when [sw] is released. *)

val for_this_domain : unit -> Llm_provider.Http_client.cache option
(** The installed cache when the calling domain installed it. A transport
    keeps the cache it was built with, so it runs on the domain that built
    it; {!Runtime_agent} builds and runs a transport in one run. *)

val with_fresh_connections : (unit -> 'a) -> 'a
(** In the current Eio fiber and its children, build transports without the
    installed idle connection cache. Restores the surrounding policy on return
    or exception; other fibers keep using their own policy. This does not
    resend a request or close another request's connection. *)

val stats : unit -> Llm_provider.Http_client.cache_stats option
(** The installed cache's statistics. Any domain may read them. *)
