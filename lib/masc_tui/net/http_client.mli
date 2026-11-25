(** Typed HTTP client running on {!Io_domain}.

    Automatically attaches optional [X-Masc-Expected-Instance] and
    [X-Masc-Expected-Workspace] guard headers so every request validates
    workspace identity in-memory on the server without double [/health]
    pre/post-flight probes, classifying [409 Conflict] ([workspace_mismatch])
    as a first-class variant. *)

open Masc_tui_core
open Masc_tui_protocol

val expected_instance_header : string
val expected_workspace_header : string

type workspace_guard = {
  expected_instance : string option;
  expected_workspace : string option;
}

val no_guard : workspace_guard

type endpoint = {
  scheme : string;
  host : string;
  port : int;
  bearer_token : string option;
  guard : workspace_guard;
}

val make_endpoint :
  ?scheme:string ->
  host:string ->
  port:int ->
  ?bearer_token:string ->
  ?guard:workspace_guard ->
  unit ->
  endpoint

val with_guard : endpoint -> workspace_guard -> endpoint

type http_error =
  | Transport of Health.transport_error
  | Workspace_mismatch of {
      expected_instance : string option;
      observed_instance : string option;
      observed_workspace_sha256 : string option;
      message : string;
    }
  | Http_error of {
      status : int;
      body : string;
      api_error : Wire_common.api_error option;
    }
  | Decode_error of string

val http_error_to_string : http_error -> string

(** {1 Pure Helpers (Testable Without Sockets)} *)

val build_url : endpoint -> path:string -> string

val build_headers :
  ?extra:(string * string) list ->
  ?content_type:string ->
  endpoint ->
  (string * string) list
(** Build sanitized HTTP headers, stripping NUL and ASCII control bytes from
    values, dropping invalid/CTL header names, and automatically injecting
    [X-Masc-Expected-Instance], [X-Masc-Expected-Workspace], and
    [Authorization: Bearer ...] when configured on [endpoint]. *)

val classify_response :
  endpoint -> status:int -> body:string -> (string, http_error) result
(** Map HTTP status + body into [Ok body], [Error (Workspace_mismatch ...)] on
    [409] workspace mismatch, or [Error (Http_error ...)]. *)

val sanitize_timeout_path : string -> string
(** Sanitize an endpoint path or URL for timeout diagnostics: strip ASCII
    control bytes, cut query strings ([?...]) and fragments ([#...]), and drop
    any RFC 3986 [<scheme>://authority] or protocol-relative [//authority]
    prefix so credentials, tokens, or query parameters never leak into error
    strings or toasts. *)

val transport_error_of_failure :
  ?path:string ->
  ?streaming:bool ->
  Masc_http_client.failure ->
  Health.transport_error
(** Map a {!Masc_http_client.failure} into {!Health.transport_error},
    preserving exact timeout phase, duration, and sanitized [?path]. When
    [streaming = true], {!Masc_http_client.Pool.Timed_out} maps to
    {!Health.Timeout_stream_header}; otherwise it maps to
    {!Health.Timeout_response}. *)

val should_autostart_server :
  contact:Masc_server_lifecycle.contact -> already_attempted:bool -> bool
(** Delegate to {!Masc_server_lifecycle.start_due}. *)

(** {1 Async HTTP Calls on [Io_domain]} *)

val get_raw :
  io:Io_domain.t ->
  clock:[> float Eio.Time.clock_ty ] Eio.Resource.t ->
  ?timeout_sec:float ->
  ?max_body_bytes:int ->
  ?extra_headers:(string * string) list ->
  endpoint ->
  path:string ->
  (string, http_error) result

val post_raw :
  io:Io_domain.t ->
  clock:[> float Eio.Time.clock_ty ] Eio.Resource.t ->
  ?timeout_sec:float ->
  ?extra_headers:(string * string) list ->
  content_type:string ->
  body:string ->
  endpoint ->
  path:string ->
  (string, http_error) result

val put_raw :
  io:Io_domain.t ->
  clock:[> float Eio.Time.clock_ty ] Eio.Resource.t ->
  ?timeout_sec:float ->
  ?extra_headers:(string * string) list ->
  content_type:string ->
  body:string ->
  endpoint ->
  path:string ->
  (string, http_error) result

val delete_raw :
  io:Io_domain.t ->
  clock:[> float Eio.Time.clock_ty ] Eio.Resource.t ->
  ?timeout_sec:float ->
  ?extra_headers:(string * string) list ->
  ?content_type:string ->
  ?body:string ->
  endpoint ->
  path:string ->
  (string, http_error) result

val post_stream :
  io:Io_domain.t ->
  clock:[> float Eio.Time.clock_ty ] Eio.Resource.t ->
  ?idle_timeout_sec:float ->
  ?header_timeout_sec:float ->
  ?extra_headers:(string * string) list ->
  content_type:string ->
  body:string ->
  on_response:(status:int -> headers:(string * string) list -> unit) ->
  on_chunk:(string -> unit) ->
  endpoint ->
  path:string ->
  (unit, http_error) result
(** Execute a streaming [POST] request (e.g. [POST /api/v1/keepers/chat/stream])
    on {!Io_domain}, delivering response chunks via [on_chunk] while classifying
    non-2xx buffered responses and [409 workspace_mismatch]. *)

val get_json :
  io:Io_domain.t ->
  clock:[> float Eio.Time.clock_ty ] Eio.Resource.t ->
  ?timeout_sec:float ->
  endpoint ->
  path:string ->
  decode:(Yojson.Safe.t -> ('a, string) result) ->
  ('a, http_error) result

val post_json :
  io:Io_domain.t ->
  clock:[> float Eio.Time.clock_ty ] Eio.Resource.t ->
  ?timeout_sec:float ->
  endpoint ->
  path:string ->
  body:Yojson.Safe.t ->
  decode:(Yojson.Safe.t -> ('a, string) result) ->
  ('a, http_error) result

val put_json :
  io:Io_domain.t ->
  clock:[> float Eio.Time.clock_ty ] Eio.Resource.t ->
  ?timeout_sec:float ->
  endpoint ->
  path:string ->
  body:Yojson.Safe.t ->
  decode:(Yojson.Safe.t -> ('a, string) result) ->
  ('a, http_error) result

val delete_json :
  io:Io_domain.t ->
  clock:[> float Eio.Time.clock_ty ] Eio.Resource.t ->
  ?timeout_sec:float ->
  ?body:Yojson.Safe.t ->
  endpoint ->
  path:string ->
  decode:(Yojson.Safe.t -> ('a, string) result) ->
  ('a, http_error) result
