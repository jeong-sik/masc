
(** Tool_misc_web_search — Web search MCP tool with a
    credentialed multi-provider chain.

    Tries providers in priority order ([Searxng] / [Brave] /
    [Tavily] / [Exa] / [Bing_api] / [Ollama]) with response
    caching. Only
    providers whose credentials are present enter the chain; an
    empty chain is an explicit configuration failure. A valid empty
    response is returned if no later provider finds hits; provider failures
    remain in [provider_errors] alongside the successful result. [Brave_llm_context] joins only through explicit
    provider config (never the default order) and answers with a
    grounded context envelope — [context_text] + [sources] — in
    place of result rows; its token budget is negotiated in the
    provider request, not re-truncated locally. [Zai] joins the same way,
    through [provider], [provider_order] or the fallbacks only: its key is
    the one the GLM model provider already reads, so the key being present
    says nothing about wanting the plan's search allowance spent. A [Zai]
    search is three requests (session, notification, call), each under the
    provider timeout, so it can take three times as long as another provider
    and an answer streamed past the timeout is lost with its request.

    Internal: ~50+ helpers + internal types stay private —
    [provider] (8-variant) /
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
    [take_results], [normalize_hits], [provider_failure],
    [result_object], the per-provider \[fetch_*\] HTTP fetchers,
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
    simulates a transport-layer failure; [`Brave_body body] feeds
    [body] as a Brave HTTP 200 response through the same parse path
    as the real Brave provider, and [`Ollama_body body] does the same
    for the Ollama provider. [`Hits] rows are {!Engine_summary} rows. *)
type simulated_provider_outcome =
  [ `Error of string
  | `Empty
  | `Hits of (string * string * string) list
  | `Grounded of (string * string * string list) list
  | `Brave_body of string
  | `Ollama_body of string
  ]

(** {1 Result rows} *)

(** What an engine wrote in a result row's text field. Each engine's
    parser names it from the field that engine documents as text from the
    page: Ollama [content], Tavily [content] (at the requested depth) and
    Exa [text] are [Engine_text]. SearXNG [content], Brave [description],
    Bing [snippet] and z.ai [content] are not documented as page text and
    are [Engine_summary]. A missing field is an empty text of the same
    kind. *)
type row_text =
  | Engine_summary of string  (** the engine's own preview of the result *)
  | Engine_text of string     (** text the engine took from the result's page *)

(** One served result row, read-only outside this module so no caller
    builds a half-formed row. [snippet] is the cleaned preview, bounded
    to 1 KiB. [engine_text] is an [Engine_text] row's text, whole and
    trimmed; [None] for an [Engine_summary] row or an empty text. *)
type normalized_hit = private {
  title : string;
  url : string;
  snippet : string;
  engine_text : string option;
  source : string;
  rank : int;
  published_at : string option;
}

(** {1 Provider fallback plan} *)

val provider_plan : unit -> string list
(** [provider_plan ()] returns the resolved provider order as
    canonical lowercase labels ([searxng] / [brave] / [tavily] /
    [exa] / [bing_api] / [ollama], plus [brave_llm_context] and [zai] when
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
  | Account_refused of Runtime_account_access.refusal
      (** the provider needs a key, and the process does not send with the
          keys of its host (plan D4d) *)

val provider_error_to_string : provider_error -> string
(** [provider_error_to_string err] renders a typed per-provider
    failure as a human-readable, query-safe string with a
    [transport:] / [server:] / [config:] / [parse:] / [account:] prefix.
    Used by {!search_impl}'s aggregate boundary so the fallback
    chain preserves the per-provider failure class instead of
    collapsing it into an opaque string. *)

(** {1 Provider parsers}

    Each parser returns [Ok] with [(title, url, text)] triples filtered
    by {!valid_search_result_url} and non-empty title.  Used
    internally by {!handle}'s fetch pipeline; exposed for unit
    tests so per-provider payload parsing can be exercised
    without an HTTP roundtrip. Malformed JSON, missing result arrays and
    nonempty arrays with no usable entries return [Error (Parse _)]. Only an
    explicit empty array returns [Ok []]. *)

val parse_searxng_json : string -> ((string * string * row_text) list, provider_error) result
(** Parse SearxNG JSON response from
    [{ "results": \[{title, url, content}, ...\] }]. *)

val parse_brave_json : string -> ((string * string * row_text) list, provider_error) result
(** Parse Brave Search JSON response from
    [{ "web": { "results": \[{title, url, description}, ...\] } }]. *)

val parse_tavily_json : string -> ((string * string * row_text) list, provider_error) result
(** Parse Tavily JSON response from
    [{ "results": \[{title, url, content}, ...\] }]. *)

val parse_exa_json : string -> ((string * string * row_text) list, provider_error) result
(** Parse Exa JSON response from
    [{ "results": \[{title, url, text}, ...\] }]. *)

val parse_bing_search_json : string -> ((string * string * row_text) list, provider_error) result
(** Parse Bing Search API JSON response from
    [{ "webPages": { "value": \[{name, url, snippet}, ...\] } }]. *)

val parse_zai_search_text : string -> ((string * string * row_text) list, provider_error) result
(** Parse the text block z.ai's [web_search_prime] tool answers with: a JSON
    string whose content is [\[{title, link, content, refer}, ...\]], or that
    array itself. Entries without a title or an http(s) [link] are dropped; a
    non-empty array with no usable entry is [Error (Parse _)]. *)

val curl_mcp_post_with_for_test :
  run:
    (deadline:Monotonic_deadline.t ->
     timeout_sec:int ->
     headers:(string * string) list ->
     url:string ->
     body_json:string ->
     unit ->
     (Tool_local_runtime_http.http_header_response, string) result) ->
  timeout_sec:int ->
  Mcp_client.post
(** The MCP transport the [Zai] provider uses, over a caller-supplied [run]
    (in production, {!Tool_local_runtime_http.http_post_json_response_with_headers}).
    It drops any [Content-Type] the client lists, since the helper writes its
    own, forwards the shared deadline, and turns the helper's answer into the
    client's response record. *)

val search_via_zai_for_test :
  post:Mcp_client.post ->
  api_key:string ->
  query:string ->
  limit:int ->
  ((string * string * string) list, provider_error) result
(** One z.ai search as [(title, url, snippet)] rows: open an MCP session, call
    [web_search_prime], parse the answer, keep [limit] rows. [post] is the
    transport, so a test answers the three requests of the session itself. *)

val parse_ollama_search_json : string -> ((string * string * row_text) list, provider_error) result
(** Parse an Ollama web-search response from
    [{ "results": \[{title, url, content}, ...\] }]. *)

val parse_brave_llm_context_json : string -> ((string * string * string list) list, provider_error) result
(** Parse a Brave LLM Context response from
    [{ "grounding": { "generic": \[{url, title, snippets}, ...\] } }]
    into (url, title, snippets) entries.  Malformed JSON or an unexpected shape returns [Error (Parse _)].
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

val handle : tool_name:string -> start_time:Tool_timing.started -> Yojson.Safe.t -> Tool_result.result
(** [handle ~tool_name ~start_time args] handles [masc_web_search] tool dispatch.
    Required: [query] (string).  Optional: [limit] (int,
    clamped to [\[1, 10\]], default 5).
    [Tool_misc_web_enrichment.handle] also accepts [includeContent=true] to
    best-effort fetch each result page via [WebFetch] and add a top-level
    keeper-readable [content_text] rendering (fetched bodies ride only
    there — the [results] hits keep title/url/snippet), plus optional
    [contentMaxChars] and [contentTimeout] controls. It reads the rows
    through {!handle_with_rows}. This module remains the search-provider
    boundary to avoid depending on fetch.

    On success [data] is the typed search result envelope. When the
    serving provider is [brave_llm_context] the envelope carries
    [grounded=true], [context_text] (the pre-extracted chunks) and
    [sources] (url/title/snippet_count metadata) instead of [results]
    rows; [includeContent=true] is then a structural no-op — there are
    no result rows to enrich and the content already rides inline.

    Failure classes (RFC-0189):
    - [Workflow_rejection]: empty query input.
    - [Dependency_unavailable]: no configured provider.
    - [Runtime_failure]: every provider failed. A valid empty result is
      successful and keeps any failed providers in [provider_errors].
    - [Policy_rejection]: a multi-account process sends nothing with the keys
      of its host, and no provider of the order needs none. SearXNG needs
      none, so it still searches there; a provider with a key fails in the
      chain with an [account:] error. *)

val handle_with_rows :
  on_rows:(normalized_hit list -> Yojson.Safe.t -> Yojson.Safe.t) ->
  tool_name:string ->
  start_time:Tool_timing.started ->
  Yojson.Safe.t ->
  Tool_result.result
(** [handle_with_rows ~on_rows] is {!handle}, except that a served answer
    with result rows reaches the caller as [on_rows rows data]: the typed
    rows the envelope's [results] were rendered from, in the same order,
    and the envelope. A cache hit keeps its rows. A grounded answer has no
    rows and is served as it is; a failure never reaches [on_rows]. *)

val addon_search_runner :
  query:string -> limit:int option -> (Lane_addon_search_result.result, string) result
(** The Lane Add-on web-search port's server-side runner (task-2527 E11).
    Same validation, cache identity/window and provider fallback plan as
    {!handle}; returns the secret-free port envelope — the serving
    provider's own typed result data, its name and every per-provider error
    the chain kept. No credential or cache key is exposed. The server
    registers this once via
    [Lane_addon_runtime.register_web_search_runner]. *)

val simulate_for_test :
  query:string ->
  limit:int ->
  (string * simulated_provider_outcome) list ->
  Tool_result.result
(** [simulate_for_test ~query ~limit outcomes] is a pure
    deterministic projection of {!handle}'s fallback chain for
    unit tests.  [outcomes] maps provider names to
    {!simulated_provider_outcome}; the simulator iterates in
    list order, returns the first nonempty result, or the first valid empty
    response if no later provider finds hits. Provider errors remain visible
    in the successful envelope; only an entirely failed chain is an error.

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
