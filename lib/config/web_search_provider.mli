(** Web_search_provider — the web-search providers, the label runtime.toml
    spells for each, and the environment variables whose presence admits it.

    One definition for the two questions a provider asks about its credential:
    is it there, and what is it. {!Tool_misc_web_search} selects and calls
    providers through this module and [masc web-search-setup] reports them
    through it, so a provider the command shows as usable is one a search tries.
    The variable names used to live in the presence check and again in each
    fetcher, and the two once disagreed: a provider looked selectable and the
    call then found no key (#21972 P2-3).

    {!Keeper_runtime_setting_registry} still lists the same variables as
    documentation rows, with their own descriptions. A test holds every name
    here to a row there. *)

type t =
  | Searxng
  | Brave
  | Brave_llm_context
  | Tavily
  | Exa
  | Bing_api
  | Ollama
  | Zai
      (** z.ai's Web Search MCP server (GLM Coding Plan). *)
[@@deriving enumerate]
(* [all] is generated, so a provider added to [t] is in it. *)

val label : t -> string
(** The canonical label runtime.toml and the provider plan spell. *)

val of_label : string -> t option
(** The provider a label names, case-insensitively and without surrounding
    blanks. Accepts the canonical labels and the aliases a provider has always
    been read under ([searx], [bing], [brave-llm-context]). [auto], the empty
    string and any unknown label all give [None]: a reader drops them without
    saying so, which turns a typo in a provider list into the default order.
    A writer therefore refuses on [None] instead of carrying the string
    through. *)

val credential_env_names : t -> string list
(** The variables that admit the provider, in the order a call reads them. One
    of them being present is enough. For {!Searxng} the variable carries the
    instance URL, not a secret. *)

val credential : t -> string option
(** The first non-blank value among {!credential_env_names}, trimmed. Read where
    the server reads: the process environment, then the boot overrides
    runtime.toml seeds into {!Env_config_core.raw_value_opt}. *)

val has_credentials : t -> bool
(** [credential] is [Some _]. This is what admits a provider into the default
    order; whether a call needs it is {!needs_credential_to_call}. *)

val needs_credential_to_call : t -> bool
(** Whether a call to the provider fails without its credential. [false] for
    {!Searxng} only: the reader falls back to the default instance address
    ({!Masc_network_defaults.searxng_default_url}) when the variable is unset
    or blank, so SearXNG is absent from the default order but still searches
    when a provider list names it. Every other provider reports
    ["missing <variable>"] on each call. *)

val in_default_order : t -> bool
(** Whether the provider joins the chain when nothing configures one.
    {!Brave_llm_context} does not: it answers with a grounded context envelope
    instead of result rows, which is a caller's choice made through provider
    config and not a fallback. {!Zai} does not either, for another reason: its
    key is the one the [glm-coding] model provider already reads, so the key is
    present on every install that talks to GLM, and a search spends the plan's
    MCP allowance and not a model call. A search joins that allowance only when
    the operator names the provider in [provider], [provider_order] or
    [fallbacks]. *)

val default_order : t list
(** The providers {!in_default_order} holds, in the order the chain tries them,
    before credentials filter it. *)
