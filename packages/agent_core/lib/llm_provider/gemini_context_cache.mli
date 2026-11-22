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

type handle =
  { key : string
  ; resource_name : string
  }

(** Return [Some ttl_s] when [config] opts into explicit context caching and its
    resolved capability declares {!Capabilities.Gemini_explicit_cached_content}. *)
val explicit_cache_ttl_if_enabled : config:Provider_config.t -> int option

(** Deterministic SHA-256 hex cache key scoped by endpoint [base_url], API-key
    fingerprint, [model_id], and canonical prefix JSON. *)
val prefix_key
  :  config:Provider_config.t
  -> prefix:Backend_gemini.cacheable_prefix
  -> string

(** Serialized JSON byte length of the cacheable prefix components. *)
val prefix_byte_size : Backend_gemini.cacheable_prefix -> int

(** Build the JSON request body for [POST {base_url}/cachedContents]. *)
val build_create_body
  :  model_id:string
  -> ttl_s:int
  -> prefix:Backend_gemini.cacheable_prefix
  -> string

(** Resolve a live [cachedContents] handle for [prefix], creating one via
    [POST {base_url}/cachedContents] on cache miss or imminent TTL expiry.
    Returns [None] when the prefix is below [min_prefix_bytes] or when creation
    fails, allowing the caller to fall back transparently to implicit caching.
    Never holds the cache mutex across HTTP I/O. *)
val resolve_or_create
  :  sw:Eio.Switch.t
  -> net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t
  -> ?clock:_ Eio.Time.clock
  -> ?connection_cache:Http_client.cache
  -> ?min_prefix_bytes:int
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
