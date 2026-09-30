(** Server_routes_http_routes_play_pad — the masc pad over HTTP (RFC
    play-link-for-the-shared-machine §2.9).

    [GET /api/v1/play/pad] ([CanPlayMachine] bearer) answers the layout of the
    DOS program loaded now, [{saves_name, source, buttons}], where [source]
    is ["workspace"] for [<.masc>/dos/pads/<saves name>.toml] and ["builtin"]
    for one masc ships. No program loaded is [409 {code: "no_machine"}]; a
    program with no layout is [404 {code: "no_layout", saves_name}]; a
    workspace layout that does not parse is [500 {code: "layout_invalid"}].

    [POST /api/v1/play/pad] [{button, saves_name}] ([masc_dos_press]'s
    permission) presses the bound keys through
    {!Server_routes_http_routes_dos.press_into}. [saves_name] is the one the
    GET answered. When another program is loaded it is
    [409 {code: "program_changed", saves_name}] with the loaded one's name;
    a load that lands during the press itself is refused by the lane, a 400.
    An unknown or unbound button is a 400. None of these presses anything. *)

val pad_path : string

val add_routes : Http_server_eio.Router.t -> Http_server_eio.Router.t
