(** Server_routes_http_routes_play_page — the page an invite link opens and
    the seat it reads (RFC play-link-for-the-shared-machine §2.6).

    [GET /play] ({!Server_auth.play_page_path}) is public and self-contained:
    a CSP with a fresh CSPRNG nonce admits only its inline script and style,
    and it connects only to this server. It reads the bearer from the link's
    fragment, removes the fragment from the address bar, and keeps the bearer
    in memory. It draws [GET /api/v1/lane-addons/live?source_kind=dos_capture],
    sends keys, text and hand-offs to [POST /api/v1/dos/*], and reads the seat
    again whenever the live activity feed moves.

    [GET /api/v1/play/seat] needs [CanPlayMachine] from a bearer and answers
    [{name, machine, controller, participants}]: the bearer's name, whether a
    machine is loaded, who holds the DOS controller ([null] when free), and
    every keeper, operator and unexpired invite ({!Play_seat.participants}).
    A fleet that does not list answers [503 {error: "keepers_unreadable"}]. *)

val seat_path : string

val page : nonce:string -> string
(** The page, with [nonce] on its one script and one style tag. *)

val csp_header : string -> string
(** The content-security-policy value for [nonce]. *)

val add_routes : Http_server_eio.Router.t -> Http_server_eio.Router.t
