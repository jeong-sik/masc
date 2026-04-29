(** Http_server_h2 — HTTP/2 server wrapper over [h2-eio].

    Replaces [httpun-eio] for HTTP/2 support with unlimited SSE
    streams per connection.  HTTP/2 multiplexing eliminates the
    browser's 6-connection-per-domain limit.

    Surface mirrors the implementation: 2 top-level types,
    1 default value, 1 helper, 4 nested modules ({!Response},
    {!Request}, {!Router}, {!Compat}), 3 helper toplevels, and
    {!run}.

    Currently aliased as [Http_h2] by both [bin/main_eio.ml] and
    [lib/server/server_routes_http_common.ml] — kept stable as
    the future-callable surface even though direct dotted access
    has not been wired through yet.

    @see <https://github.com/anmonteiro/ocaml-h2> h2 documentation *)

(** {1 Server configuration} *)

type config = {
  port : int;
  host : string;
  max_connections : int;
}
(** Server configuration record.  [port] / [host] are typically
    populated from {!Env_config_core.masc_http_port_int} /
    {!Env_config_core.masc_host}; [max_connections] is the
    [Eio.Net.listen ~backlog] value. *)

val default_config : config
(** [default_config] is [{ port = Env_config_core.masc_http_port_int ();
      host = Env_config_core.masc_host (); max_connections = 128 }].
    Reads env values at module-load time — restart required for
    env changes to take effect. *)

(** {1 Request types} *)

type h2_request_handler = H2.Reqd.t -> unit
(** Raw H2 request handler signature.  Used directly when the
    caller wants full access to the [H2.Reqd.t] (e.g. SSE
    streaming via {!Response.start_sse}). *)

type request = {
  meth : H2.Method.t;
  target : string;
  headers : H2.Headers.t;
}
(** Abstracted request projected from {!H2.Reqd.t} for route
    matching.  [target] is the raw request URI (path + query). *)

val request_of_reqd : H2.Reqd.t -> request
(** [request_of_reqd reqd] extracts the {!request} fields from
    an [H2.Reqd.t]. *)

(** {1 Response helpers} *)

(** Status / body / streaming response writers over the H2
    streaming API.  Every function closes the body writer except
    {!Response.start_sse}, which keeps the writer open for SSE
    event streaming. *)
module Response : sig
  val send_body : H2.Reqd.t -> H2.Response.t -> string -> unit
  (** [send_body reqd response body] writes [body] using
      [respond_with_streaming] with [~flush_headers_immediately:true]
      and closes the writer. *)

  val text :
    ?status:H2.Status.t -> string -> H2.Reqd.t -> unit
  (** Plain-text response.  Default status [`OK].  Sets
      [content-type: text/plain; charset=utf-8] and
      [content-length]. *)

  val html :
    ?status:H2.Status.t ->
    ?headers:(string * string) list ->
    string ->
    H2.Reqd.t ->
    unit
  (** HTML response.  Default status [`OK].  Caller-supplied
      headers are appended after [content-type] /
      [content-length]. *)

  val json :
    ?status:H2.Status.t -> string -> H2.Reqd.t -> unit
  (** JSON response.  Default status [`OK].  Sets
      [content-type: application/json; charset=utf-8] and
      [content-length]. *)

  val not_found : H2.Reqd.t -> unit
  (** Pinned ["404 Not Found"] body, status [`Not_found]. *)

  val method_not_allowed : H2.Reqd.t -> unit
  (** Pinned ["405 Method Not Allowed"] body, status
      [`Method_not_allowed]. *)

  val bad_request : string -> H2.Reqd.t -> unit
  (** [bad_request msg reqd] returns status [`Bad_request] with
      [msg] as the plain-text body. *)

  val start_sse :
    ?headers:(string * string) list ->
    H2.Reqd.t ->
    H2.Body.Writer.t
  (** [start_sse ?headers reqd] begins an SSE stream.  Returns
      the body writer left {b open} so callers can keep emitting
      events; closing is the caller's responsibility.  Sets
      [content-type: text/event-stream] +
      [cache-control: no-cache]. *)

  val bytes :
    ?status:H2.Status.t ->
    ?headers:(string * string) list ->
    content_type:string ->
    string ->
    H2.Reqd.t ->
    unit
  (** Arbitrary-content response.  Default status [`OK].  Caller
      supplies [content_type] explicitly. *)

  val internal_error : string -> H2.Reqd.t -> unit
  (** [internal_error msg reqd] returns status
      [`Internal_server_error] with body
      ["500 Internal Server Error: " ^ msg]. *)
end

(** {1 Request helpers} *)

(** Helpers projected from a {!request} record.  Pure — no
    [H2.Reqd.t] state reads. *)
module Request : sig
  val path : request -> string
  (** [path req] is the path portion of [req.target] (everything
      before [?]). *)

  val query_string : request -> string option
  (** [query_string req] is the query portion of [req.target]
      (everything after [?]) or [None] when no [?] is present. *)

  val method_string : request -> string
  (** [method_string req] is the canonical method label
      ([H2.Method.to_string]). *)

  val header : string -> request -> string option
  (** [header name req] looks up the first matching header by
      lowercased canonical name. *)

  val content_type : request -> string option
  (** Convenience: [header "content-type" req]. *)
end

(** {1 Router} *)

(** Simple method+exact-path router.  Routes are tried in
    insertion order via [List.find_opt] inside
    {!find_route}; the first match wins. *)
module Router : sig
  type route = {
    meth : H2.Method.t;
    path : string;
    handler : request -> H2.Reqd.t -> unit;
  }

  type t = route list

  val empty : t
  (** Empty route list. *)

  val add :
    H2.Method.t ->
    string ->
    (request -> H2.Reqd.t -> unit) ->
    t ->
    t
  (** [add meth path handler routes] prepends a route.  Insertion
      order is reverse of registration order — most recently
      added wins on conflict. *)

  val get :
    string -> (request -> H2.Reqd.t -> unit) -> t -> t
  (** [get path handler routes] is [add `GET path handler routes]. *)

  val post :
    string -> (request -> H2.Reqd.t -> unit) -> t -> t
  (** [post path handler routes] is [add `POST path handler routes]. *)

  val delete :
    string -> (request -> H2.Reqd.t -> unit) -> t -> t
  (** [delete path handler routes] is [add `DELETE path handler routes]. *)

  val options :
    string -> (request -> H2.Reqd.t -> unit) -> t -> t
  (** [options path handler routes] is [add `OPTIONS path handler routes]. *)

  val find_route : t -> request -> route option
  (** [find_route routes req] returns the first route whose
      [meth] and [path] both equal [req.meth] / [Request.path req]. *)

  val to_handler : t -> h2_request_handler
  (** [to_handler routes] is the {!h2_request_handler} that
      dispatches via {!find_route}, falling through to
      {!Response.not_found} on no match. *)
end

(** {1 Body / error handling} *)

val read_body_async : H2.Reqd.t -> (string -> unit) -> unit
(** [read_body_async reqd callback] schedules an async body read
    using [H2.Body.Reader.schedule_read].  [callback body_str] is
    invoked on EOF with the accumulated string. *)

val error_handler :
  Eio.Net.Sockaddr.stream ->
  ?request:H2.Request.t ->
  H2.Server_connection.error ->
  (H2.Headers.t -> H2.Body.Writer.t) ->
  unit
(** H2 connection error handler.  Logs via [Log.Http.error] and
    writes a [text/plain] body.  Wired into {!run} via
    [H2_eio.Server.create_connection_handler]. *)

val make_request_handler : Router.t -> h2_request_handler
(** [make_request_handler routes] is a {!h2_request_handler} that
    catches every non-cancellation exception and converts it to a
    {!Response.internal_error} 500 response.
    [Eio.Cancel.Cancelled] is re-raised so the cancellation
    propagates upward. *)

(** {1 Httpun compatibility} *)

(** Adapter shim that lets handlers written against the old
    httpun-eio types coexist with the H2 wrapper while the
    migration completes. *)
module Compat : sig
  type httpun_request = {
    meth :
      [ `GET
      | `POST
      | `DELETE
      | `OPTIONS
      | `PUT
      | `HEAD
      | `CONNECT
      | `TRACE
      | `Other of string ];
    target : string;
    headers : (string * string) list;
  }
  (** Httpun-style request projection — method as polymorphic
      variant, headers as plain assoc list. *)

  val to_httpun_request : request -> httpun_request
  (** [to_httpun_request h2_req] converts an H2 {!request} to
      the Httpun-shaped record.  All standard methods preserved
      verbatim; [`Other s] propagates the SDK label. *)

  val header_get :
    (string * string) list -> string -> string option
  (** Case-insensitive byte-wise header lookup ([String_util.equals_ci]).
      Pinned at the contract seam — drift to allocation-heavy
      lowercase comparisons would add 2 allocs per header
      inspected on every HTTP request. *)

  module Headers : sig
    val get : (string * string) list -> string -> string option
    (** Alias for {!header_get}. *)

    val of_list : (string * string) list -> (string * string) list
    (** Identity — kept for Httpun-API parity. *)
  end
end

(** {1 Server entry point} *)

val run :
  sw:Eio.Switch.t ->
  net:[> `Generic ] Eio.Net.ty Eio.Resource.t ->
  clock:_ Eio.Time.clock ->
  config ->
  h2_request_handler ->
  unit
(** [run ~sw ~net ~clock config request_handler] binds to
    [config.host:config.port] with [Eio.Net.listen
    ~backlog:config.max_connections], then accepts in a loop.
    Each accepted connection is handled in a forked fiber under
    its own switch; flow close is registered via
    [Eio.Switch.on_release].

    Backoff: per-iteration accept errors trigger exponential
    backoff (50 ms initial, 1 s ceiling) via [Eio.Time.sleep
    clock]; successful accepts reset the backoff to 50 ms.
    [Eio.Cancel.Cancelled] always propagates — the loop only
    swallows non-cancellation exceptions. *)
