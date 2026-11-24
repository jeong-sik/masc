(* HIGH-RISK-UNREVIEWED: these routes answer files to anyone who reaches the
   listener of the account server, before any login. A file that is answered
   here is public, and the policy of the page decides what a browser runs on
   the origin where a person signs in. *)

(** The unified dashboard SPA and legacy account console redirect served by the
    account server in multi-account mode.

    All routes registered here are [Always_public]: the HTML frame and static
    assets carry no user or workspace data. Every operational JSON and SSE
    route called by the dashboard authenticates the request itself against the
    authorization zone ({!Server_account_dashboard_bridge},
    {!Server_login_http}).

    - [GET /dashboard] and [GET /dashboard/<spa-deep-link>]: the unified
      dashboard [index.html] from the dashboard bundle under {!policy}, never
      stored. When the bundle cannot give [index.html], answers 503 with an
      {!Account_page} fallback that discloses no server paths or reasons.
    - [GET /dashboard/assets/<path>]: static files under [assets/] in the
      dashboard bundle, served via {!Server_routes_http_pages.serve_dashboard_asset}
      with {!policy} and strict relative-path traversal validation.
    - [GET /favicon.ico] and [GET /favicon.svg]: {!Server_routes_http_pages.serve_favicon}.
    - [GET /accounts/console]: redirects [303 See Other] to
      [/dashboard#account] with [cache-control: no-store] and
      [referrer-policy: same-origin], keeping bookmarked console links working.
    - [GET /accounts/console/base.css]: {!Account_page.base_sheet} with ETag
      validation.
    - [GET /accounts/console/assets/<path>]: legacy console build assets under
      [accounts/assets/] with {!policy} and strict relative-path validation. *)

(** [/accounts/console]. Kept for backwards-compatible redirects and callers. *)
val page_path : string

(** [/dashboard]. *)
val dashboard_path : string

(** [/dashboard#account], the redirect target of {!page_path}. *)
val console_redirect_target : string

(** Strict zero-inline-script content security policy applied to the unified
    dashboard page and its served assets: scripts, styles, fonts, images (plus
    [data:] URIs), and same-origin connections only, with no inline scripts,
    no inline [style] attributes, no forms, and no framing. *)
val policy : string

(** Why the bundle cannot give the dashboard page ([index.html]) now, in words
    for the log of the server; [None] when it can. *)
val unreadable : unit -> string option

(** Registers the unified dashboard SPA, asset, favicon, and [/accounts/console]
    redirect routes on [router]. *)
val add_routes : Http_server_eio.Router.t -> Http_server_eio.Router.t
