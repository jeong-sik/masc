
(** Tool_local_runtime_http — curl-shelled HTTP helpers for local
    runtime probing.

    All requests:
    - Force HTTP/1.1 ([--http1.1]) — keeps curl off proxies that
      mishandle HTTP/2.
    - Pass through {!Masc_exec.Exec_gate.run_argv_with_status} so
      tool exec policy / timeouts / audit logging stay consistent.
    - Append [\\n%\{http_code\}] to capture the status code as the
      last line of the body (parsed by
      {!split_http_body_and_status}).

    {b Include runtime:} starts with [include Tool_local_runtime_core]
    so siblings ({!Tool_local_runtime_bench},
    {!Tool_local_runtime_verify}, {!Tool_local_runtime_probe})
    receive the core surface transitively via
    [include Tool_local_runtime_http].

    Internal helpers stay private. *)

include module type of struct
  include Tool_local_runtime_core
end

(** {1 String / JSON helpers} *)

(** [trim_to_option raw] returns [Some s] iff [s = String.trim raw]
    is non-empty, else [None].  Used for "treat empty string as
    missing" semantics on JSON / shell inputs. *)

val int_member : Yojson.Safe.t -> string -> int option
(** [int_member json key] reads [json.key] as an int.  Accepts both
    [\`Int n] and [\`Intlit s] (parsed via [parse_int_opt]).  Returns
    [None] when the field is missing, the wrong type, or
    [Intlit] failed to parse. *)

val string_member : Yojson.Safe.t -> string -> string option
(** [string_member json key] reads [json.key] as a non-empty string.
    Returns [None] when the field is missing, not a string, or the
    string is empty after trimming. *)

(** {1 GET helpers} *)

type http_get_response =
  { http_status : int option
  ; effective_url : string option
  ; redirect_url : string option
  ; content_type : string option
  ; downloaded_bytes : int option
  ; body : string
  }
(** Structured curl GET response metadata.  [body] is the response body with
    curl's write-out metadata stripped.  [effective_url], [redirect_url],
    [content_type], and [downloaded_bytes] are populated from curl write-out
    fields when available. *)

val http_get_text_response_with_headers :
  ?timeout_sec:int ->
  ?headers:(string * string) list ->
  ?follow_redirects:bool ->
  ?max_redirects:int ->
  ?compressed:bool ->
  ?max_response_bytes:int ->
  string ->
  (http_get_response, string) Result.t
(** [http_get_text_response_with_headers ?timeout_sec ?headers url] issues a
    [GET url] via curl and returns both body text and curl write-out metadata.

    It is the metadata-preserving form of
    {!http_get_text_with_status_with_headers}. *)

val http_get_text_with_status_with_headers :
  ?timeout_sec:int ->
  ?headers:(string * string) list ->
  ?follow_redirects:bool ->
  ?max_redirects:int ->
  ?compressed:bool ->
  ?max_response_bytes:int ->
  string ->
  ((int option * string), string) Result.t
(** [http_get_text_with_status_with_headers ?timeout_sec ?headers url]
    issues a [GET url] via curl.  Returns
    [Ok (http_status_opt, body)] on curl exit 0, where:

    - [http_status_opt = Some n] when curl emitted a status line, or
      [None] when the body lacked a trailing status line.
    - [body] is the response body with the status-code suffix stripped.

    [timeout_sec] defaults to 10 (floored at 1).
    [headers] defaults to [\[\]]; appended in left-to-right order
    (each pair becomes [-H "name: value"]).
    [follow_redirects] defaults to [false]; when [true], curl follows
    redirects up to [max_redirects] (default 3).
    [compressed] enables curl's transparent compression handling.
    [max_response_bytes], when set, asks curl to cap the response.

    Errors include curl exit code, signals, and stop reasons. *)

val curl_get_argv_for_test :
  ?timeout_sec:int ->
  ?headers:(string * string) list ->
  ?follow_redirects:bool ->
  ?max_redirects:int ->
  ?compressed:bool ->
  ?max_response_bytes:int ->
  string ->
  string list

(** Pure curl argv builder exposed for focused regression tests. *)

val http_get_text_with_status :
  ?timeout_sec:int ->
  string ->
  ((int option * string), string) Result.t
(** [http_get_text_with_status] is
    {!http_get_text_with_status_with_headers} with no extra headers. *)

val http_get_json_with_status :
  ?timeout_sec:int ->
  string ->
  ((int option * Yojson.Safe.t), string) Result.t
(** [http_get_json_with_status ?timeout_sec url] composes
    {!http_get_text_with_status} + [Yojson.Safe.from_string].  Returns
    [Error "invalid json from <url>: <msg>"] on parse failure. *)

(** {1 POST helpers} *)

val http_post_json_text_with_status_with_headers :
  timeout_sec:int ->
  ?headers:(string * string) list ->
  url:string ->
  body_json:string ->
  unit ->
  ((int option * string), string) Result.t
(** [http_post_json_text_with_status_with_headers ~timeout_sec
      ?headers ~url ~body_json ()] issues a [POST url] with
    [Content-Type: application/json] and [body_json] as the request
    body.  Returns [Ok (http_status_opt, body_text)] on curl exit 0.

    [timeout_sec] is required (no default — caller must commit to a
    bound).  [headers] defaults to [\[\]] and is appended after the
    built-in [Content-Type] header. *)

val http_post_json_text_with_status :
  timeout_sec:int ->
  url:string ->
  body_json:string ->
  ((int option * string), string) Result.t
(** [http_post_json_text_with_status] is
    {!http_post_json_text_with_status_with_headers} with no extra
    headers. *)

val http_post_json_with_status :
  timeout_sec:int ->
  url:string ->
  body_json:string ->
  ((int option * Yojson.Safe.t), string) Result.t
(** [http_post_json_with_status ~timeout_sec ~url ~body_json] composes
    {!http_post_json_text_with_status} + [Yojson.Safe.from_string].
    Returns [Error "invalid json from <url>: <msg>"] on parse
    failure. *)
