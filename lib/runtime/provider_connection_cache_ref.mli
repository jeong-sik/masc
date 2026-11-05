(** The process's provider connection cache (RFC-0492 §3.1).

    The server installs one cache at startup. Every provider transport that
    {!Runtime_agent} builds after that takes its idle connections from it, so
    Keepers that call the same origin share connections. Without an installed
    cache each provider request opens its own connection and closes it. *)

val install : Llm_provider.Http_client.cache -> unit
(** Replaces the installed cache. *)

val get : unit -> Llm_provider.Http_client.cache option
