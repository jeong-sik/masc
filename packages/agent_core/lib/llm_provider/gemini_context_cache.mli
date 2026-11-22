(** Gemini explicit [cachedContents] resource lifecycle.

    Opt-in resource cache for large static Gemini prefixes ([systemInstruction],
    [tools], and [toolConfig]). Activated only when both the resolved capability
    declares {!Capabilities.Gemini_explicit_cached_content} and
    [Provider_config.explicit_context_cache_ttl_s] is [Some ttl_s].

    All cache-creation failures degrade cleanly to [None] so callers fall back
    to implicit caching without breaking turns. Stale/evicted resources rejected
    by [generateContent] or [streamGenerateContent] are invalidated via
    {!invalidate} and retried once with implicit caching. *)

(** Minimum serialized byte size of the static prefix required before creating
    an explicit [cachedContents] resource (matches Gemini's documented
    1024-token explicit cache floor; smaller prefixes stay on implicit
    caching). *)
val default_min_prefix_bytes : int

(** Default negative-cache TTL in seconds for permanent 4xx errors on
    [POST .../cachedContents] (e.g. [400 INVALID_ARGUMENT] when the prefix is
    below the model token floor). Transient/auth statuses (401/403/408/429/5xx)
    are never negative-cached. *)
val default_negative_ttl_s : float

type handle =
  { key : string
  ; resource_name : string
  }

(** Return [Some ttl_s] when [config] opts into explicit context caching and its
    resolved capability declares {!Capabilities.Gemini_explicit_cached_content}. *)
val explicit_cache_ttl_if_enabled : config:Provider_config.t -> int option

(** Resolve the [cachedContents] endpoint URL for [base_url].
    Supports both Gemini Developer API ([{base_url}/cachedContents]) and
    canonical Vertex Gemini publisher endpoints
    ([https://{host}/v1/projects/{project}/locations/{region}/cachedContents]). *)
val cached_contents_url : base_url:string -> string

(** Deterministic SHA-256 hex cache key scoped by endpoint [base_url], stable
    credential/header identity, [model_id], and canonical prefix JSON.

    Static API keys (such as AI Studio [x-goog-api-key] / [config.api_key]) are
    hashed so distinct accounts remain strictly isolated. Ephemeral OAuth
    [Authorization: Bearer] tokens (Vertex ADC / [Refreshable_credential]) are
    excluded from the hash so ~1h token rotations reuse live Vertex
    [cachedContents] resources instead of orphaning them; isolation instead
    comes from [base_url] (project/location), non-bearer auth headers,
    provider credential kind/scope, and stable request headers. *)
val prefix_key
  :  ?auth_headers:(string * string) list
  -> config:Provider_config.t
  -> prefix:Backend_gemini.cacheable_prefix
  -> unit
  -> string

(** Serialized JSON byte length of the cacheable prefix components. *)
val prefix_byte_size : Backend_gemini.cacheable_prefix -> int

(** Build the JSON request body for [POST .../cachedContents].
    When [base_url] is a canonical Vertex Gemini publisher endpoint, formats
    [model] as [projects/{project}/locations/{region}/publishers/google/models/{model_id}]. *)
val build_create_body
  :  ?base_url:string
  -> model_id:string
  -> ttl_s:int
  -> prefix:Backend_gemini.cacheable_prefix
  -> unit
  -> string

(** Resolve a live [cachedContents] handle for [prefix], creating one via
    [POST .../cachedContents] on cache miss or imminent TTL expiry.

    Coalesces concurrent misses on the same [prefix_key] (single-flight) so
    [N] concurrent callers issue a single outbound [POST .../cachedContents]
    request, cleaning up the in-flight slot on exception or cancellation so
    waiters never hang. Permanent 4xx responses (excluding 401/403/408/429) are
    negative-cached for [negative_ttl_s] (defaulting to
    {!default_negative_ttl_s}) so subsequent turns skip futile round-trips.
    401/403 responses evict any stale live entry and 401 also invalidates
    refreshable credentials via {!Provider_config.invalidate_credential}.

    Runs the creation POST inside a local [Eio.Switch.run] so one-shot sockets
    never leak hooks onto a caller's long-lived switch, includes
    {!Provider_config.effective_request_headers}, and returns [None] when the
    prefix is below [min_prefix_bytes] or creation fails so callers fall back
    transparently to implicit caching. When [POST .../cachedContents] returns
    HTTP 401 and invalidates a refreshable credential, [on_auth_invalidated]
    (when supplied) is invoked so the caller can refresh auth headers once
    before dispatching generation instead of sending a doomed request with the
    revoked token. Never holds the cache mutex across HTTP I/O and degrades
    cleanly without raising [Effect.Unhandled] outside Eio. *)
val resolve_or_create
  :  net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t
  -> ?clock:_ Eio.Time.clock
  -> ?timeout_s:float
  -> ?connection_cache:Http_client.cache
  -> ?min_prefix_bytes:int
  -> ?negative_ttl_s:float
  -> ?on_auth_invalidated:(unit -> unit)
  -> config:Provider_config.t
  -> auth_headers:(string * string) list
  -> ttl_s:int
  -> prefix:Backend_gemini.cacheable_prefix
  -> unit
  -> handle option

(** Whether an HTTP failure from [generateContent] / [streamGenerateContent]
    indicates an expired or evicted [cachedContent] resource that should be
    invalidated and retried with implicit caching. *)
val is_cached_content_error : Http_client.http_error -> bool

(** Evict a cached resource handle by its prefix key (e.g. after a 404). *)
val invalidate : key:string -> unit

(** Clear all process-local explicit cache handles (for unit tests). *)
val clear_for_tests : unit -> unit
