(** Tool_misc_web_fetch — Fetch a URL and return cleaned text content.

    Uses [curl] via [Tool_local_runtime_http] for HTTP GET, then applies
    the shared HTML cleaning pipeline from [Tool_misc_web_search] to
    strip tags, decode entities, and normalize whitespace.

    Provides separate cache + rate-limit state (same env config keys as
    web_search) and optional [<title>] / [<meta name="description">]
    extraction. *)

val default_timeout_sec : int
(** Default timeout for HTTP fetch operations (seconds). *)

val default_max_chars : int
(** Default maximum output length for extracted content. *)

val handle : tool_name:string -> start_time:float -> Yojson.Safe.t -> Tool_result.result
(** [handle ~tool_name ~start_time args] handles [masc_web_fetch] tool dispatch.
    Required: [url] (string, http/https only).
    Optional: [timeout] (int, clamped to [\[1, 60\]], default {!default_timeout_sec}).
    Optional: [extractMode] ("markdown" or "text", default "markdown").
    Optional: [maxChars] (int, clamped to [\[1, 100000\]], default {!default_max_chars}).

    On success the payload [data] is wrapped as
    [`Assoc [ "text", `String json ]] where [json] is the serialized
    [Tool_args.ok_response] envelope holding:
	    - [url]: the requested URL
	    - [final_url]: final URL after validated redirects
	    - [http_status]: HTTP status code
	    - [redirect_count]: number of followed redirects
	    - [extract_mode]: output extraction mode
	    - [content_kind]: [html], [text], [json], or [xml]
	    - [extraction_source]: [article], [main], [body], [document], or
	      [raw_text]
	    - [text]: readable extracted content, truncated at [maxChars]
	    - [content_chars]: length of [text]
	    - [truncated]: whether output truncation was applied
	    - [content_type]: optional upstream content type
	    - [downloaded_bytes]: optional curl-reported download size
	    - [title]: optional, extracted from [<title>] tag
	    - [description]: optional, extracted from [<meta name="description">]
      or [og:description]

    Failure classes (RFC-0189):
    - [Workflow_rejection]: invalid URL — caller-input violation.
    - [Transient_error]:    rate-limit hit + transport-layer failure;
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
