(** Tool_misc_web_fetch — Fetch a URL and return cleaned text content.

    Uses [curl] via [Tool_local_runtime_http] for HTTP GET, then applies
    the shared HTML cleaning pipeline from [Tool_misc_web_search] to
    strip tags, decode entities, and normalize whitespace.

    Provides separate cache + rate-limit state (same env config keys as
    web_search) and optional [<title>] / [<meta name="description">]
    extraction. *)

val default_timeout_sec : int
(** Default timeout for HTTP fetch operations (seconds). *)

val handle : tool_name:string -> start_time:float -> Yojson.Safe.t -> Tool_result.result
(** [handle ~tool_name ~start_time args] handles [masc_web_fetch] tool dispatch.
    Required: [url] (string, http/https only).
    Optional: [timeout] (int, clamped to [\[1, 60\]], default {!default_timeout_sec}).

    On success the payload [data] is wrapped as
    [`Assoc [ "text", `String json ]] where [json] is the serialized
    [Tool_args.ok_response] envelope holding:
    - [url]: the requested URL
    - [http_status]: HTTP status code
    - [text]: cleaned text content (HTML tags stripped, entities decoded,
      whitespace normalized, truncated at 100KB)
    - [title]: optional, extracted from [<title>] tag
    - [description]: optional, extracted from [<meta name="description">]
      or [og:description]

    Failure classes (RFC-0189):
    - [Workflow_rejection]: invalid URL — caller-input violation.
    - [Transient_error]:    rate-limit hit + transport-layer failure;
                            both retry-friendly.
    - [Runtime_failure]:    upstream HTTP non-2xx or missing status. *)
