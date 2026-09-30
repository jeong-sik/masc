(** Server_routes_http_routes_play_guide — how an agent handed an invite link
    joins the shared DOS machine (RFC play-link-for-the-shared-machine §2.7).

    [GET /play/agent.md] ({!Play_invite.agent_guide_path}) is public and
    answers [text/markdown]: the prompt [play.agent_guide] with this server's
    public base URL ([MASC_HTTP_BASE_URL]) in front of the seat's MCP door, the
    seat, the screen and every move route, and each move's tool schema. It
    carries no token and no workspace state. Without a public base URL there
    is no address to join at: [409 {error: "not_ready"}]. A prompt that does
    not render is a 500 naming why. *)

val guide : base:string -> (string, string) result
(** The guide for a server reached at [base], or why the prompt did not
    render. *)

val add_routes : Http_server_eio.Router.t -> Http_server_eio.Router.t
