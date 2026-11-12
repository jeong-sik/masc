(* HIGH-RISK-UNREVIEWED: these routes answer files to anyone who reaches the
   listener of the account server, before any login. A file that is answered
   here is public, and the policy of the page decides what a browser runs on
   the origin where a person signs in. *)

(** The console of a signed-in person, as the account server answers it
    (multi-account plan, C6).

    The console is built in the dashboard workspace ([dashboard/src/accounts],
    [dashboard/vite.accounts.config.ts]) and lies in the dashboard bundle
    under [accounts/]. This module answers that build and nothing else of the
    bundle: the account server does not serve the operator dashboard.

    The routes are [Always_public]. The page is the frame a browser needs
    before it can ask who is signed in, and its files hold nothing of a
    person: every JSON route the console calls authenticates the request
    itself.

    - [GET /accounts/console]: the page of the build under {!policy}, never
      stored. When the bundle cannot give the page, the answer is a 503 with a
      page in the frame of {!Account_page} that says so.
    - [GET /accounts/console/assets/<path>]: a file of the build, read and
      compressed as the single-user server does the assets of the dashboard
      ({!Server_routes_http_pages.serve_dashboard_asset}). The answer lets a
      browser keep the file for a year: the build names a file after a hash
      of its bytes, and this module does not check that a name does. The
      answer carries {!policy}, so a file a browser opens as a document runs
      under the limits of the page. A path that is no plain relative path is
      a 404, and so is a name the bundle holds no file of. A bundle read from
      a directory ([MASC_ASSETS_DIR]) answers a 503 instead when its reader
      refuses a name for another reason, such as a part of the path that is
      a file (issue #51705).
    - [GET /accounts/console/base.css]: {!Account_page.base_sheet}, which the
      page links so that it looks like the pages the server writes itself. A
      browser asks for it again on every use, with the entity tag it holds. *)

(** [/accounts/console]. *)
val page_path : string

(** The content security policy of the page: scripts and sheets of this
    origin, requests to this origin, and nothing else. It lets a browser run
    no inline script, apply no inline style and no [style] attribute, submit
    no form, and show the page in no frame. *)
val policy : string

(** Why the bundle cannot give the page now, in words for the log of the
    server; [None] when it can. *)
val unreadable : unit -> string option

(** Registers the three routes. [draw] gives the nonce of the sheet of the
    page that says the console cannot be opened; the account server passes
    the [draw] of its {!Login_routes.t}. *)
val add_routes : draw:(unit -> string) -> Http_server_eio.Router.t -> Http_server_eio.Router.t
