(** Server_routes_http_routes_play_screen — the shared DOS machine's frame as
    a PNG (RFC play-link-for-the-shared-machine §2.7).

    [GET /api/v1/play/screen.png] needs [CanPlayMachine] from a bearer and
    answers [image/png], not cached. No program loaded is
    [409 {code: "no_machine"}]; a capture or encode that fails is a 500
    naming which. Reading it never moves the machine. *)

val screen_path : string

val add_routes : Http_server_eio.Router.t -> Http_server_eio.Router.t
