(** [masc web-search-setup]: what each web search provider needs, and the
    [web_search] section of runtime.toml.

    The section holds where to search and in what order. An API key is read
    from the environment of the process that starts the server and is never
    written here: runtime.toml is committed. *)

val provider_names : string
(** The provider labels, comma separated, for option help. *)

val run
  :  base_path:string
  -> port:int
  -> agent:string
  -> searxng_url:string option
  -> provider:string option
  -> provider_order:string option
  -> fallbacks:string option
  -> timeout_sec:int option
  -> cache_ttl_sec:float option
  -> unset:Web_search_setup.key list
  -> int
(** With every change option absent, writes nothing and prints the state. With
    some, writes them in one commit and then prints the state.

    When the process that holds the lease of [base_path] announces [port] as
    the server of a single user and is ready, the state is the text it holds
    and the commit goes through it (RFC-0482 §3.2), with the sign-in
    [masc login] keeps for [agent]; a server still starting, a lease holder
    that does not announce [port] that way or a missing sign-in writes
    nothing. With nothing holding the lease of [base_path], the file is the
    one the server reads for it, [MASC_CONFIG_DIR] included.

    The result is the process exit code: [0] when it printed the state, [1]
    when it refused and said why on stderr. *)
