(** Tool_misc_web_fetch — Fetch a URL and return cleaned text content.

    Uses [curl] via [Tool_local_runtime_http] for HTTP GET, then applies
    the shared HTML cleaning pipeline from [Tool_misc_web_search] to
    strip tags, decode entities, and normalize whitespace.

    Provides separate cache + rate-limit state (same env config keys as
    web_search) and optional [<title>] / [<meta name="description">]
    extraction. *)

val default_timeout_sec : int
(** Default timeout for HTTP fetch operations (seconds). *)

val validate_redirect_target : string -> (unit, string) result
(** [validate_redirect_target target] accepts a redirect hop only when
    it is a valid http(s) URL whose destination passes the literal
    boundary above (no loopback / private / link-local / unspecified
    address, no RFC 6761 localhost name).  Exposed so the per-hop
    boundary can be exercised without a network round trip. *)

val default_max_chars : int
(** Default maximum output length for extracted content. *)

val handle : tool_name:string -> start_time:float -> Yojson.Safe.t -> Tool_result.result
(** [handle ~tool_name ~start_time args] handles [masc_web_fetch] tool dispatch.
    Required: [url] (string, http/https only).
    Optional: [timeout] (int, clamped to [\[1, 60\]], default {!default_timeout_sec}).
    Optional: [extractMode] ("markdown" or "text", default "markdown").
    Optional: [maxChars] (int, clamped to [\[1, 100000\]], default {!default_max_chars}).

    On success [data] is the typed [Tool_args.ok_assoc] envelope holding:
	    - [url]: the requested URL
	    - [final_url]: final URL after validated redirects
	    - [http_status]: HTTP status code
	    - [redirect_count]: number of followed redirects
	    - [extract_mode]: output extraction mode
	    - [content_kind]: [html], [text], [json], or [xml]
	    - [extraction_source]: [article], [main], [body], [document], or
	      [raw_text]
	    - [text]: readable extracted content. Over [maxChars] it becomes a
	      deterministic head/tail window (three quarters of the budget from
	      the start, one quarter from the end, cut on line boundaries) around
	      a [\[TRUNCATED ... full_text_sha256=<sha256>\]] marker naming the
	      offloaded full text by content address.
	      When the extraction carries markdown ATX headings and the offload
	      succeeded, the marker is followed by an [\[OUTLINE ...\]] block:
	      up to 32 [<byte-offset> <heading-line>] rows addressing the
	      offloaded bytes, so a reader fetches one section via
	      [keeper_artifact_read(sha256, offset, max_bytes)] instead of
	      paging blindly. Fenced-code [#] lines are excluded;
	      heading-free documents carry no outline
	    - [content_chars]: length of [text]
	    - [truncated]: whether output truncation was applied
	    - [full_text_sha256]: present only when truncation offloaded the
	      full extracted text into the content-addressed [Tool_blob_store]
	      ([<base>/.masc/tool_blobs/], #28820 — the store
	      [keeper_artifact_read] resolves, so the keeper lane can re-read
	      it; identical pages reuse one blob); absent when no truncation
	      happened or the offload failed — the marker then says
	      [full_text_unavailable=<reason>] instead of hiding it. MASC never
	      deletes these blobs; retention is operator-managed. Cut points
	      that fall away from a newline snap to UTF-8 codepoint starts, so
	      a window never splits a multi-byte sequence. Each successful
	      offload also appends one [masc.web_artifact.v1] fact row (sha256,
	      source_url, optional title, bytes, fetched_at) to [index.jsonl]
	      under [<base>/.masc/artifacts/web-fetch/] — RFC-0383's
	      requeryable corpus. The index is a projection: deleting it
	      changes no behavior, and an append failure surfaces as an
	      [\[index_unavailable=<reason>\]] marker line without demoting the
	      offload
	    - [content_type]: optional upstream content type
	    - [downloaded_bytes]: optional curl-reported download size
	    - [title]: optional, extracted from [<title>] tag
	    - [description]: optional, extracted from [<meta name="description">]
      or [og:description]

    Destination boundary: the initial URL and every redirect hop are
    rejected when they target the loopback surface, private networks
    (RFC 1918 / fc00::/7), link-local ranges, the unspecified address,
    or an RFC 6761 localhost name.  The check is literal (no DNS
    resolution), so a public hostname resolving to a private address is
    outside this boundary by contract; NAT64-embedded IPv4 literals
    (64:ff9b::/96) are likewise not unwrapped — only the standard
    IPv4-mapped form (::ffff:0:0/96) is.

    Failure classes (RFC-0189):
    - [Workflow_rejection]: invalid or rejected URL — caller-input
      violation (blocked destinations included).
    - [Dependency_unavailable]:    rate-limit hit + transport-layer failure;
                            both retry-friendly.
    - [Runtime_failure]:    upstream HTTP non-2xx or missing status. *)

type fetch_response =
  { http_status : int option
  ; final_url : string
  ; redirect_count : int
  ; content_type : string option
  ; downloaded_bytes : int option
  ; body : string
  }

type fetch_failure =
  | Transport_error of string
  | Http_status of int
  | No_http_status
  | Invalid_redirect of string
  | Redirect_limit_exceeded
  | Unsupported_content_type of string

val with_http_fetch_for_test :
  (timeout_sec:int ->
   headers:(string * string) list ->
   max_response_bytes:int ->
   string ->
   (fetch_response, fetch_failure) result) ->
  (unit -> 'a) ->
  'a
(** [with_http_fetch_for_test http_fetch f] temporarily replaces the
    structured HTTP fetch boundary used by {!handle}. *)

val with_http_get_for_test :
  (timeout_sec:int ->
   headers:(string * string) list ->
   max_response_bytes:int ->
   string ->
   (int option * string, string) result) ->
  (unit -> 'a) ->
  'a
(** [with_http_get_for_test http_get f] temporarily replaces the HTTP
    GET boundary used by {!handle}, then restores the production curl
    implementation after [f] returns or raises.

    Test-only: URL validation, cache, rate-limit, status handling, HTML
    cleanup, title/description extraction, and result construction still
    run; only the external network request is replaced. *)
