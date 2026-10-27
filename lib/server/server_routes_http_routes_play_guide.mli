(** Server_routes_http_routes_play_guide — how an agent handed an invite link
    joins the shared DOS machine (RFC play-link-for-the-shared-machine §2.7).

    [GET /play/agent.md] ({!Play_invite.agent_guide_path}) is public and
    answers [text/markdown]: the prompt [play.agent_guide] with this server's
    public base URL ([MASC_HTTP_BASE_URL]) in front of the seat's MCP door, the
    seat, the screen and every move route, and each move's tool schema. It
    carries no token. Its game guides section lists the Skills the DOS machine
    add-on publishes ({!Server_play_skills}) with their URLs, or says why there
    are none. Without a public base URL there
    is no address to join at: [409 {code: "not_ready", error: <reason>}]. A prompt that does
    not render is a 500 naming why.

    [GET /play/skills/<name>.md] answers a guide's SKILL.md text after its
    frontmatter and [GET /play/skills/<name>/references/<file>] one of its
    reference files, as [text/markdown] with the guide's headers. Both need a
    bearer with [CanPlayMachine], as the seat does. *)

val guide : base:string -> skills:Server_play_skills.catalog -> (string, string) result
(** The guide for a server reached at [base] listing [skills], or why the
    prompt did not render. *)

val current_skills : unit -> Server_play_skills.catalog
(** The game guides of the published server state's workspace. Logs what the
    catalog leaves out ({!Server_play_skills.unreadable_details}). *)

val markdown_content_type : string

val guide_response :
  unit ->
  (string, ([ `Conflict | `Internal_server_error ] * Yojson.Safe.t)) result
(** Shared HTTP/1 and HTTP/2 response. Refusals use {!Server_refusal.json}:
    [error] is the readable reason and [code] names the refusal. *)

val skill_response :
  catalog:Server_play_skills.catalog ->
  string ->
  (string, ([ `Not_found | `Service_unavailable | `Internal_server_error ] * Yojson.Safe.t)) result
(** The answer to a request path under {!Server_play_skills.prefix}. 404 when the
    path names nothing the published catalog holds; 503 while no snapshot is
    published, the DOS machine add-on is detached, or a reference file cannot
    be read; 500 when the catalog is unreadable or a reference file is over
    the Skill resource read bound. Refusals never carry a host path. *)

val add_routes : Http_server_eio.Router.t -> Http_server_eio.Router.t
