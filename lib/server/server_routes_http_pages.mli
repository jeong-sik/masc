(** Server_routes_http_pages — static HTML / asset
    handlers + GraphQL playground / iql.

    Reached three different ways depending on the
    consumer:
    - [include Server_routes_http_pages] in
      {!Server_routes_http} — facade re-export consumed
      indirectly by everyone who [open Server_routes_http]
      (server_h2_gateway / _routes_extra,
      server_runtime_bootstrap, bin/main_eio).
    - [open Server_routes_http_pages] in
      {!Server_routes_http_routes_frontend} — reaches
      the 6 handlers below unqualified.
    - [module Pages = Server_routes_http_pages] aliases
      in 4 sister routing modules + the test —
      production sister aliases are unused leftovers
      (cycle 223 unused-alias pattern).

    External surface (19 entries):
    - {b Legacy dashboard handlers}
      ({!serve_dashboard_index},
      {!serve_dashboard_static}).
    - {b GraphQL handlers + assets}
      ({!handle_graphql},
      {!handle_post_graphql},
      {!serve_graphiql_asset},
      {!serve_playground_asset},
      {!graphql_playground_html},
      {!graphql_csp_header}).
    - {b Asset / file utilities}
      ({!asset_content_type},
      {!read_file},
      {!playground_asset_path},
      {!dashboard_etag_of_body},
      {!dashboard_index_cache_control},
      {!favicon_svg}).
    - {b Server-state helpers}
      ({!get_server_state_result},
      {!server_state_error_json}).
    - {b Misc} ({!serve_favicon}).

    Internal helpers stay private at this boundary
    (~9 internal lets — [graphiql_asset_path] /
    [graphiql_asset_root], [assets_root] /
    [playground_asset_root], [handle_get_graphql],
    [graphql_headers] helper). *)

(** {1 GraphQL Playground / iql assets} *)

val graphql_playground_html : nonce:string -> string
(** Renders the GraphQL Playground HTML with the given
    CSP nonce inlined into the boot script. *)

val graphql_csp_header : string -> string

val fresh_graphql_csp_nonce : unit -> string
(** Per-response CSP nonce for the GraphQL playground. Both transports call
    this so the playground is served with one nonce implementation rather than
    a copy per route table. *)
(** Builds the [Content-Security-Policy] header value
    pinned to the GraphQL Playground asset set, threading
    the per-request nonce. *)

val serve_graphiql_asset :
  string -> Httpun.Request.t -> Httpun.Reqd.t -> unit
(** Serves a GraphiQL static asset by name (CSS / JS /
    favicon).  404s on miss. *)

val serve_playground_asset :
  string -> Httpun.Request.t -> Httpun.Reqd.t -> unit
(** Serves a GraphQL Playground static asset by name. *)

val handle_graphql : Httpun.Request.t -> Httpun.Reqd.t -> unit
(** Dispatches [GET /graphql] (Playground HTML) and
    [POST /graphql] (query execution) to their
    respective internal handlers. *)

val handle_post_graphql : Httpun.Request.t -> Httpun.Reqd.t -> unit
(** Handles [POST /graphql] body — invokes the GraphQL
    schema, threads {!get_server_state_result} for
    request context, and surfaces 503 with
    {!server_state_error_json} when the runtime state
    has not been wired yet. *)

(** {1 Asset / file utilities} *)

val asset_content_type : string -> string
(** Returns the [Content-Type] for [name] based on its
    extension (.css / .js / .html / .svg / .png / etc.).
    Defaults to [application/octet-stream] for unknown
    extensions. *)

val read_file : string -> (string, string) result
(** Reads [path] in binary mode and returns its bytes
    as a string.  [Error msg] on [Sys_error] and similar
    OS failures.  [Eio.Cancel.Cancelled] re-raises. *)

val playground_asset_path : string -> string option
(** Path to a Playground asset under the
    [.../playground/] resource root. *)

val dashboard_etag_hex_chars : int
(** Number of hex digest characters included in the
    dashboard index ETag. *)

val dashboard_etag_of_body : string -> string
(** Content-derived ETag digest for dashboard [index.html]
    response bytes, truncated to [dashboard_etag_hex_chars]. *)

val dashboard_index_cache_control : string
(** Cache-control header value for the dashboard index
    response: ["no-store, max-age=0, must-revalidate"]. *)

val favicon_svg : string
(** Inline SVG bytes for the [/favicon.svg] response. *)

(** {1 Legacy dashboard handlers} *)

val serve_dashboard_index :
  Httpun.Request.t -> Httpun.Reqd.t -> unit
(** Serves the legacy dashboard's [index.html]. *)

val serve_dashboard_static :
  string -> Httpun.Request.t -> Httpun.Reqd.t -> unit
(** Serves a legacy-dashboard static asset by name. *)

(** {1 Server-state helpers} *)

val get_server_state_result :
  unit -> (Mcp_server.server_state, string) result
(** Returns [Ok state] when {!Server_auth.current_server_state}
    has been wired, [Error "server state not initialized"]
    otherwise.  Used by every handler that needs the
    runtime state to satisfy the request. *)

val server_state_error_json : string -> string
(** Serialises a single-field error JSON
    ([\{ "error": "…" \}]) used by handlers that surface
    a 503 / 500 with a textual reason. *)

(** {1 Misc} *)

val serve_favicon : Httpun.Request.t -> Httpun.Reqd.t -> unit
(** Serves [/favicon.svg] (inline SVG bytes from
    {!favicon_svg}). *)
