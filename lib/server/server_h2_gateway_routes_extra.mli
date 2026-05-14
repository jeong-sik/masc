(** Server_h2_gateway_routes_extra — board / governance / voice /
    karma / static-asset routes for the HTTP/2 gateway.

    Single dispatch entry point that the parent gateway tries
    before falling through to the catch-all 404.  Returns [true]
    when the route matched and the response was written, [false]
    otherwise. *)

val dispatch :
  h2_reqd:H2.Reqd.t ->
  httpun_request:Httpun.Request.t ->
  cors:(string * string) list ->
  path:string ->
  config:Coord.config option ->
  [ `GET | `POST | `DELETE | `OPTIONS | `PUT | `HEAD
  | `CONNECT | `TRACE | `Other of string ] ->
  bool
(** [dispatch ~h2_reqd ~httpun_request ~cors ~path ~config method_]
    handles the following routes:

    {2 Voice config}
    - [GET /api/v1/voice/config] — JSON dump from
      {!Server_voice_config.voice_config_payload}; HTTP 500 when
      the config layer reports an error.

    {2 Board}
    - [GET /api/v1/board] — paginated post listing.  Query params:
      [hearth] / [sort_by] / [exclude_system] / [exclude_automation]
      / [author] / [limit] (clamped to [1..200]) / [offset]
      (clamped to [0..5000]).  Author filter routes through
      {!Server_utils.board_actor_author_for_write} so keeper
      aliases resolve to canonical names.
    - [GET /api/v1/board/hearths] — hearth name+count list.
    - [GET /api/v1/board/flairs] — available flair list.
    - [GET /api/v1/board/curation] — latest AI curation snapshot
      ([{snapshot: null}] when no snapshot has been submitted yet).
    - [GET /api/v1/board/<post_id>] — single post with
      configurable [format] query param (defaults to [nested]).
    - [GET /api/v1/board/sub-boards] — sub-board list.
    - [POST /api/v1/board/sub-boards] — create sub-board (auth required).
      Body: [{ slug, name, description, access? }].
    - [GET /api/v1/board/sub-boards/<id_or_slug>] — single sub-board.

    {2 Karma}
    - [GET /api/v1/karma] — full karma table sorted descending by
      score.
    - [GET /api/v1/board/karma/ledger] — attributed karma ledger.
      Each record carries [recipient], [voter], [target_kind],
      [target_id], [delta], [ts], and [ts_iso].  Query params:
      [agent] (filter by recipient, case-sensitive),
      [limit] (clamped to [1..5000], default 500).  Response also
      includes a [scoring_rule] field ([up=+1,down=0]) and a
      [totals] summary identical to [GET /api/v1/karma].

    {2 Static assets}
    - [GET /static/css/middleware.css] — CSS asset (text/css).
    - [GET /static/js/middleware.js] — JavaScript asset
      (application/javascript).
    - [GET /dashboard/assets/<filename>] — dashboard SPA assets.
      Path-traversal guard via
      {!Web_dashboard.is_safe_asset_relative_path} (rejects
      filenames with [..] / leading slash / etc).  zstd
      compression negotiated for [.js] / [.css] / [.svg] when the
      client advertises [Accept-Encoding: zstd]; cache control is
      [public, max-age=31536000, immutable] (1-year immutable —
      asset filenames must include content hashes).

    {2 Failure modes}

    - Path-traversal attempts on the dashboard assets route return
      [404 Not Found] (NOT [400 Bad Request]).  The spec does not
      reveal whether the path traversal was rejected vs the
      filename was missing.  Pinned at the contract seam.
    - Missing static asset files return [404 Not Found] with the
      literal body [404 Not Found] (operator runbooks grep on this
      exact string).

    Returns [false] for any route the dispatcher does not
    recognise — the parent gateway falls through to its catch-all
    handler. *)
