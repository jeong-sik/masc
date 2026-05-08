(** Tool_misc_web_fetch — Fetch a URL and return cleaned text content.

    Uses [curl] via [Tool_local_runtime_http] for HTTP GET, then applies
    the shared HTML cleaning pipeline from [Tool_misc_web_search] to
    strip tags, decode entities, and normalize whitespace.

    Provides separate cache + rate-limit state (same env config keys as
    web_search) and optional [<title>] / [<meta name="description">]
    extraction. *)

val default_timeout_sec : int
(** Default timeout for HTTP fetch operations (seconds). *)

val handle : Yojson.Safe.t -> bool * string
(** [handle args] handles [masc_web_fetch] tool dispatch.
    Required: [url] (string, http/https only).
    Optional: [timeout] (int, clamped to [\[1, 60\]], default {!default_timeout_sec}).

    Returns [(true, json)] with fields:
    - [url]: the requested URL
    - [http_status]: HTTP status code
    - [text]: cleaned text content (HTML tags stripped, entities decoded,
      whitespace normalized, truncated at 100KB)
    - [title]: optional, extracted from [<title>] tag
    - [description]: optional, extracted from [<meta name="description">]
      or [og:description]

    Returns [(false, error_json)] on validation failure, rate limit,
    transport error, or non-2xx HTTP status. *)
