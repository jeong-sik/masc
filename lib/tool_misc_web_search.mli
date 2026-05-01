open Base

(** Tool_misc_web_search — Web search MCP tool with multi-provider
    fallback chain.

    Tries providers in priority order ([Searxng] / [Brave] /
    [Tavily] / [Exa] / [Bing_api] / [Ddg] / [Bing_rss]) with
    cache + rate-limit + secret-redaction safeguards.

    Internal: ~50+ helpers + 5 internal types stay private —
    \[normalized_hit] / \[provider] (7-variant) /
    \[provider_response] / \[cache_entry] (cache + provider data
    types kept internal so callers cannot construct half-formed
    state), \[max_web_search_query_length] (= 500),
    9 pre-compiled regex constants (\[whitespace_re], \[html_tag_re],
    \[cdata_*_re], \[rss_re], \[channel_re], \[item_re],
    \[title_re], \[link_re], \[description_re], \[ddg_result_re],
    \[ddg_snippet_re]), \[html_entity_replacements] data table,
    JSON envelope helpers (\[json_error], \[json_ok]), text
    cleaning helpers (\[normalize_spaces], \[strip_html_tags],
    \[strip_cdata], \[decode_html_entities],
    \[clean_search_text], \[trim_nonempty]),
    \[valid_search_result_url], \[search_field],
    \[parse_json_search_results] (the generic JSON parser
    behind the per-provider parsers), \[provider_to_string] /
    \[provider_of_string] / \[parse_provider_csv] /
    \[default_provider_order] / \[provider_order],
    \[is_secret_token_char] / \[contains_secret_token_prefix] /
    \[query_contains_secret_like_content] (secret detection),
    \[take_results], \[normalize_hits], \[provider_error],
    \[result_json], all 7 \[fetch_*] HTTP fetchers,
    \[fetch_provider], the cache state cells
    (\[initial_cache_capacity = 32], \[cache_entries] hashtable,
    \[cache_mutex], \[request_times] queue, \[rate_limit_mutex]),
    \[cache_key], \[cache_lookup], \[cache_store],
    \[enforce_rate_limit], and \[search_impl].  All consumed
    only inside {!handle} / {!simulate_for_test} pipelines. *)

(** {1 Simulation outcome (test-only)} *)

(** Per-provider outcome closure for the test simulator —
    [`Hits] supplies pre-fabricated (title, url, snippet)
    triples; [`Empty] simulates a successful response with no
    hits; [`Error msg] simulates a transport-layer failure. *)
type simulated_provider_outcome =
  [ `Error of string
  | `Empty
  | `Hits of (string * string * string) list
  ]

(** {1 Provider fallback plan} *)

val provider_plan : unit -> string list
(** [provider_plan ()] returns the resolved provider order as
    canonical lowercase labels ([searxng] / [brave] / [tavily] /
    [exa] / [bing_api] / [duckduckgo] / [bing_rss]).  Reads
    {!Env_config.Tools.web_search_provider_opt} and
    [web_search_fallbacks_opt] at call time, dedupes preserving
    order, then appends the default provider order to fill any
    gap.  Drift to caching the result would silently freeze
    operator-visible provider order. *)

(** {1 Validation + redaction} *)

val validate_query : string -> (string, string) Result.t
(** [validate_query query] returns [Ok normalized] (whitespace
    collapsed) when:

    - [normalized] is non-empty after whitespace normalization
    - length is at most 500 chars (pinned literal)
    - no secret-like patterns are detected (Authorization:
      header, Bearer token, x-api-key:, [api_key=], [token=]
      markers, plus prefix probes for [ghp_], [github_pat_],
      [sk-]).

    Returns [Error _] otherwise.  Secret detection is
    fail-closed at the contract seam — drift to permissive
    matching would re-open the credential leak window into
    third-party search APIs. *)

val redact_transport_error_detail : string -> string
(** [redact_transport_error_detail message] truncates a
    transport error message before the [" for "] suffix that
    typically prefixes the offending request URL.  Keeps the
    useful curl/HTTP detail without echoing search queries or
    URL payloads in operator logs.  Pinned at the contract
    seam: drift would re-leak query content. *)

(** {1 Provider parsers}

    Each parser returns [(title, url, snippet)] triples filtered
    by {!valid_search_result_url} and non-empty title.  Used
    internally by {!handle}'s fetch pipeline; exposed for unit
    tests so per-provider payload parsing can be exercised
    without an HTTP roundtrip. *)

val looks_like_rss_payload : string -> bool
(** [looks_like_rss_payload payload] is [true] iff [payload]
    contains a [<] character AND matches either an [<rss]
    or [<channel] tag (case-insensitive).  Used by the Bing
    fetcher to dispatch between {!parse_bing_rss_items} and
    {!parse_bing_search_json}. *)

val parse_bing_rss_items : string -> (string * string * string) list
(** Parse Bing RSS feed items.  Reads [<item>], [<title>],
    [<link>], [<description>] tags via pre-compiled regex. *)

val parse_ddg_html : string -> (string * string * string) list
(** Parse DuckDuckGo HTML lite results.  Decodes URL-encoded
    href values via [Uri.pct_decode]. *)

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

(** {1 Tool dispatch + simulation} *)

val handle : Yojson.Safe.t -> bool * string
(** [handle args] handles [masc_web_search] tool dispatch.
    Required: [query] (string).  Optional: [limit] (int,
    clamped to [\[1, 10\]], default 5).

    Returns [(true, json)] with search hits on success,
    [(false, error_json)] when validation fails, the query is
    rate-limited, or all providers fail.  Cache hit returns
    early before rate-limit check.  The cache + rate-limit
    state is module-level (process-wide) — operator-visible
    counters live in [Env_config.Tools.web_search_*]. *)

val simulate_for_test :
  query:string ->
  limit:int ->
  (string * simulated_provider_outcome) list ->
  bool * string
(** [simulate_for_test ~query ~limit outcomes] is a pure
    deterministic projection of {!handle}'s fallback chain for
    unit tests.  [outcomes] maps provider names to
    {!simulated_provider_outcome}; the simulator iterates in
    list order, returns the first [`Hits] result that produces
    non-empty hits, accumulates errors otherwise.

    Bypasses cache, rate-limit, and secret detection — those
    are tested separately at {!handle}.  Pinned in the .mli so
    tests cannot rely on internal state cells. *)
