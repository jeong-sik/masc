
(** Tool_misc_web_search — Web search MCP tool with a
    credentialed multi-provider chain.

    Tries providers in priority order ([Searxng] / [Brave] /
    [Tavily] / [Exa] / [Bing_api] / [Ollama]) with response
    caching. Only
    providers whose credentials are present enter the chain; an
    empty chain is an explicit configuration failure, never an
    empty success. [Brave_llm_context] joins only through explicit
    provider config (never the default order) and answers with a
    grounded context envelope — [context_text] + [sources] — in
    place of result rows; its token budget is negotiated in the
    provider request, not re-truncated locally.

    Internal: ~50+ helpers + internal types stay private —
    [normalized_hit] / [provider] (7-variant) /
    [grounded_source] / [grounded_context] / [search_payload] /
    [provider_response] / [cache_entry] (cache + provider data
    types kept internal so callers cannot construct half-formed
    state),
    the pre-compiled whitespace normalizer,
    text cleaning helpers ([normalize_spaces],
    [clean_search_text], [trim_nonempty]),
    [valid_search_result_url],
    [parse_json_search_results] (the generic JSON parser
    behind the per-provider parsers), [provider_to_string] /
    [provider_of_string] / [parse_provider_csv] /
    [default_provider_order] / [provider_order],
    [take_results], [normalize_hits], [provider_error],
    [result_data], the per-provider \[fetch_*\] HTTP fetchers,
    [fetch_provider], the atomic immutable [cache_entries] map,
    [cache_key], [cache_lookup], [cache_store],
    and [search_impl].  All consumed
    only inside {!handle} / {!simulate_for_test} pipelines. *)

(** {1 Simulation outcome (test-only)} *)

(** Per-provider outcome closure for the test simulator —
    [`Hits] supplies pre-fabricated (title, url, snippet)
    triples; [`Grounded] supplies (url, title, snippets) grounded
    entries rendered through the same envelope as the live
    grounded provider (no client-side truncation, matching the
    request-negotiated budget of the real path); [`Empty]
    simulates a successful response with no hits; [`Error msg]
    simulates a transport-layer failure. *)
type simulated_provider_outcome =
  [ `Error of string
  | `Empty
  | `Hits of (string * string * string) list
  | `Grounded of (string * string * string list) list
  ]

(** {1 Provider fallback plan} *)

val provider_plan : unit -> string list
(** [provider_plan ()] returns the resolved provider order as
    canonical lowercase labels ([searxng] / [brave] / [tavily] /
    [exa] / [bing_api] / [ollama], plus [brave_llm_context] when
    explicitly configured).  Reads
    {!Env_config.Tools.web_search_provider_opt} and
    [web_search_fallbacks_opt] at call time, dedupes preserving
    order, then appends the default provider order to fill any
    gap.  Drift to caching the result would silently freeze
    operator-visible provider order. *)

(** {1 Typed validation} *)

val validate_query : string -> (string, string) Result.t
(** [validate_query query] normalizes whitespace and rejects only an empty
    query. Query semantics remain opaque to this leaf and authorization belongs
    to the Keeper Gate. *)

val redact_transport_error_detail : string -> string
(** [redact_transport_error_detail message] truncates a
    transport error message before the [" for "] suffix that
    typically prefixes the offending request URL.  Keeps the
    useful curl/HTTP detail without echoing search queries or
    URL payloads in operator logs.  Pinned at the contract
    seam: drift would re-leak query content. *)

(** {1 Typed provider error (RFC-0189 PR-2)} *)

type provider_error =
  | Transport of string  (** network / transport-level failure *)
  | Server of string     (** endpoint returned a non-200 status or no status *)
  | Config of string     (** missing credentials / invalid configuration *)
  | Parse of string      (** payload could not be parsed into hits *)

val provider_error_to_string : provider_error -> string
(** [provider_error_to_string err] renders a typed per-provider
    failure as a human-readable, query-safe string with a
    [transport:] / [server:] / [config:] / [parse:] prefix.
    Used by {!search_impl}'s aggregate boundary so the fallback
    chain preserves the per-provider failure class instead of
    collapsing it into an opaque string. *)

(** {1 Provider parsers}

    Each parser returns [(title, url, snippet)] triples filtered
    by {!valid_search_result_url} and non-empty title.  Used
    internally by {!handle}'s fetch pipeline; exposed for unit
    tests so per-provider payload parsing can be exercised
    without an HTTP roundtrip. *)

val parse_searxng_json : string -> (string * string * string) list
(** Parse SearxNG JSON response from
    [{ "results": \[{title, url, content}, ...\] }]. *)

val parse_brave_json : string -> (string * string * string) list
(** Parse Brave Search JSON response from
    [{ "web": { "results": \[{title, url, description}, ...\] } }]. *)

val parse_tavily_json : string -> (string * string * string) list
(** Parse Tavily JSON response from
    [{ "results": \[{title, url, content}, ...\] }]. *)

val parse_exa_json : string -> (string * string * string) list
(** Parse Exa JSON response from
    [{ "results": \[{title, url, snippet}, ...\] }]. *)

val parse_bing_search_json : string -> (string * string * string) list
(** Parse Bing Search API JSON response from
    [{ "webPages": { "value": \[{name, url, snippet}, ...\] } }]. *)

val parse_ollama_search_json : string -> (string * string * string) list
(** Parse an Ollama web-search response from
    [{ "results": \[{title, url, content}, ...\] }]. *)

val parse_brave_llm_context_json : string -> (string * string * string list) list
(** Parse a Brave LLM Context response from
    [{ "grounding": { "generic": \[{url, title, snippets}, ...\] } }]
    into (url, title, snippets) entries.  Total like its sibling
    parsers: malformed JSON or an unexpected shape yields [[]].
    Entries without a valid http(s) url or with zero snippets are
    dropped; a missing title falls back to the url. *)

(** {1 HTML cleaning} *)

val clean_search_text : string -> string
(** [clean_search_text html] strips HTML tags, CDATA sections, decodes
    common HTML entities, and normalizes whitespace.  Reusable for any
    HTML snippet — not limited to search result cleaning.  Exposed so
    [Tool_misc_web_fetch] can share the same pipeline without
    duplicating regexes and entity tables. *)

(** {1 Tool dispatch + simulation} *)

val handle : tool_name:string -> start_time:float -> Yojson.Safe.t -> Tool_result.result
(** [handle ~tool_name ~start_time args] handles [masc_web_search] tool dispatch.
    Required: [query] (string).  Optional: [limit] (int,
    clamped to [\[1, 10\]], default 5).
    The misc facade also accepts [includeContent=true] to best-effort fetch
    each result page via [WebFetch] and add a top-level keeper-readable
    [content_text] rendering (fetched bodies ride only there — the
    [results] hits keep title/url/snippet), plus optional [contentMaxChars]
    and [contentTimeout] controls. This module remains the search-provider
    boundary to avoid depending on fetch.

    On success [data] is the typed search result envelope. When the
    serving provider is [brave_llm_context] the envelope carries
    [grounded=true], [context_text] (the pre-extracted chunks) and
    [sources] (url/title/snippet_count metadata) instead of [results]
    rows; [includeContent=true] is then a structural no-op — there are
    no result rows to enrich and the content already rides inline.

    Failure classes (RFC-0189):
    - [Workflow_rejection]: empty query input.
    - [Runtime_failure]:    aggregate "all web search providers
      failed: ..." — provider fallback chain exhausted.
      Per-provider transport/server distinction is collapsed in
      the aggregate today; a future PR may lift fetch_provider
      to typed variants. *)

val simulate_for_test :
  query:string ->
  limit:int ->
  (string * simulated_provider_outcome) list ->
  Tool_result.result
(** [simulate_for_test ~query ~limit outcomes] is a pure
    deterministic projection of {!handle}'s fallback chain for
    unit tests.  [outcomes] maps provider names to
    {!simulated_provider_outcome}; the simulator iterates in
    list order, returns the first [`Hits] result that produces
    non-empty hits, accumulates errors otherwise.

    Bypasses cache, rate-limit, and secret detection — those
    are tested separately at {!handle}.  Pinned in the .mli so
    tests cannot rely on internal state cells. *)

val with_simulated_search_for_test :
  outcomes:(string * simulated_provider_outcome) list ->
  (unit -> 'a) ->
  'a
(** [with_simulated_search_for_test ~outcomes f] temporarily replaces
    {!handle}'s provider boundary with the same deterministic simulator
    used by {!simulate_for_test}, then restores the production provider
    chain after [f] returns or raises.

    Test-only: validation, cache, rate-limit, result construction, and
    dispatch wrappers still run; only the external web provider calls are
    replaced. *)
