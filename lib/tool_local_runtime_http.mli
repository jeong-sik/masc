open Base

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

    {b Include cascade:} starts with [include Tool_local_runtime_core]
    so siblings ({!Tool_local_runtime_bench},
    {!Tool_local_runtime_verify}, {!Tool_local_runtime_probe})
    receive the core surface transitively via
    [include Tool_local_runtime_http].

    Internal helpers ([split_http_body_and_status],
    [append_headers]) stay private. *)

include module type of struct
  include Tool_local_runtime_core
end

(** {1 String / JSON helpers} *)

val trim_to_option : string -> string option
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

val http_get_text_with_status_with_headers :
  ?timeout_sec:int ->
  ?headers:(string * string) list ->
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

    Errors include curl exit code, signals, and stop reasons. *)

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
