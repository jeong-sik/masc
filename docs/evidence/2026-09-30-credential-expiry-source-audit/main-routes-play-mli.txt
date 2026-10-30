(** Server_routes_http_routes_play — invites to the shared machine (RFC
    play-link-for-the-shared-machine §2.4).

    [POST], [GET] and [DELETE <name>] under {!invites_path}, each needing
    [CanAdmin] from a bearer. A workspace with auth off or without
    [require_token] never reaches them: the bearer check answers 401 first.
    A refusal is a {!Server_refusal.json} body: [error] is the sentence and
    the names below are its [code].

    Issuing answers [201 {name, expires_at, link}]. Without
    [MASC_HTTP_BASE_URL] it answers [409 {code: "not_ready", missing}]; a name
    a keeper or credential already has answers
    [409 {code: "name_taken", taken_by}]. One issue or revoke runs at a time,
    so two requests for one name cannot both be issued.

    Revoking deletes the [Player] credential and frees the DOS controller the
    name still holds: [200 {name, revoked: true, released_controller}]. A name
    that is another role's credential answers [409 {code: "not_an_invite"}]
    and changes nothing. A name with no credential and no keeper that holds
    the controller -- taken back by a request sent before the delete, or kept
    by a release that failed -- is freed:
    [200 {name, revoked: false, released_controller: true}]. Otherwise it
    answers [404 {code: "no_such_invite"}]. *)

val invites_path : string

val add_routes : Http_server_eio.Router.t -> Http_server_eio.Router.t

module For_testing : sig
  val revoke_response :
    config:Workspace.config -> by:string -> raw_name:string ->
    Httpun.Status.t * Yojson.Safe.t
end
