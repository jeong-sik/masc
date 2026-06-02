(** Server_routes_http_pages — static HTML / asset
    handlers + GraphQL playground / iql + Bonsai
    dashboard index + JSON keeper-summary endpoint.

    Reached three different ways depending on the
    consumer:
    - [include Server_routes_http_pages] in
      {!Server_routes_http} — facade re-export consumed
      indirectly by everyone who [open Server_routes_http]
      (server_h2_gateway / _routes_extra,
      server_runtime_bootstrap, bin/main_eio).
    - [open Server_routes_http_pages] in
      {!Server_routes_http_routes_frontend} — reaches
      the 9 handlers below unqualified.
    - [module Pages = Server_routes_http_pages] aliases
      in 4 sister routing modules + the test — only
      [test/test_keeper_registry] uses
      [Pages.keepers_summary_from_registry] in practice;
      production sister aliases are unused leftovers
      (cycle 223 unused-alias pattern).

    External surface (23 entries):
    - {b Bonsai dashboard handlers}
      ({!serve_bonsai_index},
      {!serve_bonsai_static},
      {!bonsai_api_keepers_summary},
      {!keepers_summary_from_registry}).
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
      {!dashboard_asset_root},
      {!dashboard_index_path},
      {!dashboard_etag},
      {!dashboard_index_cache_control},
      {!favicon_svg}).
    - {b Server-state helpers}
      ({!get_server_state_result},
      {!server_state_error_json}).
    - {b Misc} ({!serve_favicon}).

    Internal helpers stay private at this boundary
    (~17 internal lets — [graphiql_asset_path] /
    [graphiql_asset_root], [bonsai_asset_root] /
    [bonsai_index_html], [assets_root] /
    [playground_asset_root], [bonsai_keeper_status_of_phase],
    [handle_get_graphql], [graphql_headers]
    helper). *)

(** {1 GraphQL Playground / iql assets} *)

val graphql_playground_html : nonce:string -> string
(** Renders the GraphQL Playground HTML with the given
    CSP nonce inlined into the boot script. *)

val graphql_csp_header : string -> string
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

val playground_asset_path : string -> string
(** Path to a Playground asset under the
    [.../playground/] resource root. *)

val dashboard_asset_root : unit -> string
(** Base directory for the legacy dashboard SPA
    (Preact + HTM, built by Vite). *)

val dashboard_index_path : unit -> string
(** Resolved path to the legacy dashboard's
    [index.html]. *)

val dashboard_etag : unit -> string
(** ETag derived from the dashboard index file's mtime
    digest (first 12 hex chars).  Stable across
    process restarts as long as the asset bundle is
    untouched. *)

val dashboard_index_cache_control : string
(** Cache-control header value for the dashboard index
    response: ["no-store, max-age=0, must-revalidate"]. *)

val favicon_svg : string
(** Inline SVG bytes for the [/favicon.svg] response. *)

(** {1 Bonsai dashboard handlers} *)

val serve_bonsai_index :
  Httpun.Request.t -> Httpun.Reqd.t -> unit
(** Serves the Bonsai dashboard's index HTML (inline
    boot script + asset hashes). *)

val serve_bonsai_static :
  string -> Httpun.Request.t -> Httpun.Reqd.t -> unit
(** Serves a Bonsai dashboard static asset by name. *)

val bonsai_api_keepers_summary :
  Httpun.Request.t -> Httpun.Reqd.t -> unit
(** Bonsai dashboard's JSON [GET /api/bonsai/keepers]
    endpoint.  Consumes the registry through
    {!keepers_summary_from_registry}. *)

val keepers_summary_from_registry :
  base_path:string -> Masc_dashboard_api_types.Keepers.response
(** Returns the keepers-summary projection consumed by
    the Bonsai dashboard JSON endpoint and asserted on
    by [test/test_keeper_registry] via the
    [module Pages = ...] alias. *)

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
(** Returns [Ok state] when {!Server_auth.server_state}
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
