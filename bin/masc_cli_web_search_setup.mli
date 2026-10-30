(** [masc web-search-setup]: what each web search provider needs, and the
    [web_search] section of runtime.toml.

    The section holds where to search and in what order. An API key is read
    from the environment of the process that starts the server and is never
    written here: runtime.toml is committed. *)

val provider_names : string
(** The provider labels, comma separated, for option help. *)

val run
  :  base_path:string
  -> searxng_url:string option
  -> provider:string option
  -> provider_order:string option
  -> fallbacks:string option
  -> timeout_sec:int option
  -> cache_ttl_sec:float option
  -> unset:Web_search_setup.key list
  -> int
(** With every change option absent, writes nothing and prints the state. With
    some, writes them in one commit and then prints the state. The file is the
    one the server reads for [base_path], [MASC_CONFIG_DIR] included. The
    result is the process exit code: [0] when it printed the state, [1] when it
    refused and said why on stderr. *)
