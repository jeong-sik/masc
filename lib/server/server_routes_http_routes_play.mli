(** Server_routes_http_routes_play — invites to the shared machine (RFC
    play-link-for-the-shared-machine §2.4).

    [POST], [GET] and [DELETE <name>] under {!invites_path}, each needing
    [CanAdmin] from a bearer. Issuing answers [201 {name, expires_at, link}];
    a workspace without auth, [require_token] or [MASC_HTTP_BASE_URL] answers
    [409 {error: "not_ready", missing}], a name a keeper or credential already
    has answers [409 {error: "name_taken", taken_by}]. Revoking deletes the
    [Player] credential and frees the DOS controller the name still holds,
    answering [{name, revoked, released_controller}]; a name that is another
    role's credential answers [409 {error: "not_an_invite"}] and changes
    nothing. *)

val invites_path : string

val add_routes : Http_server_eio.Router.t -> Http_server_eio.Router.t
