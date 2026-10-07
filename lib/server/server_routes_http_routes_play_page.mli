(** Server_routes_http_routes_play_page — the page an invite link opens and
    the seat it reads (RFC play-link-for-the-shared-machine §2.6).

    [GET /play] ({!Server_auth.play_page_path}) is public and self-contained:
    a CSP with a fresh CSPRNG nonce admits only its inline script and style,
    and it connects only to this server. It reads the bearer from the link's
    fragment, removes the fragment from the address bar, and keeps the bearer
    in the browser tab's session storage so a reload can reconnect. Leaving
    the page through its disconnect action confirms release of any DOS
    controller it owns before clearing that entry. A refused release retains
    the credential for retry. An admitted game write records its operation in
    tab storage before dispatch; an unfinished or unconfirmed result keeps
    that marker across reload and blocks further game writes and disconnect.
    Only that operation's terminal response can clear its marker; a later
    seat read or authentication failure cannot settle it. The page directs
    the user to request revocation and open a new invitation in a new tab.
    A rejected credential clears the tab entry only when no operation remains
    unsettled. Room presence cleanup is sent with the credential before it is
    cleared, but its response cannot delay disconnect: presence has a lease
    independent of controller ownership.
    A different invitation, including a full-document navigation, retains the
    stored identity and asks the user to disconnect first. Restoring a cached
    document reloads its identity. If storage is unavailable the bearer stays
    in memory only and game writes are refused.
    One viewer switches between [dos_capture] and [msx_capture] on
    [GET /api/v1/lane-addons/live?source_kind=...]. Switching views clears the
    prior frame and prevents a late response from repainting the new view.
    DOS controls send keys, text and hand-offs to [POST /api/v1/dos/*]; MSX is
    observation only. Idle DOS seat reads use a slower cadence than frame
    polling; new activity and opening handoff targets refresh immediately.
    Departed controllers can therefore be discovered without game activity. When the
    loaded program has a masc pad layout ([GET /api/v1/play/pad]) it draws
    that pad in place of the plain keys row, and reads a physical gamepad in
    the standard mapping onto the same buttons. A pad read that fails shows the keys row and a
    status line, and the next poll reads it again. Each button press carries
    the saves name its layout was read for.

    [POST /api/v1/play/room] provides one public conversation shared by the
    workspace's MSX/DOS viewers, invited participants, operators and Keepers.
    History, chat and presence are independent of game input and controller
    ownership; a spectator can speak while another participant controls DOS.
    Room polling starts independently of the first seat read and continues
    on its own timer when a game read remains pending.
    Each page instance has its own presence client. Session storage preserves
    the chat draft and any unconfirmed message's client/message identifiers
    with its exact payload for retry after reload, bound to the invitation.
    Retrying the same message uses its original identifiers so an uncertain
    acknowledgment does not create a second message. An edited next draft
    remains separate: the next send reconciles the earlier receipt first,
    preserving the new text until it can be submitted on a later send.
    Conversation remains
    available while a game write is unsettled. A changed stored identity or
    draft stops an older document from sending or overwriting that draft.
    A current document's confirmed disconnect or settled credential rejection
    clears its saved draft along with the bearer.

    [GET /api/v1/play/seat] needs [CanPlayMachine] from a bearer and answers
    [{name, machine, controller, controller_recoverable, saves_name, participants}]: the bearer's name,
    whether a machine is loaded, who holds the DOS controller ([null] when
    free), whether the holder has authoritatively departed, the loaded
    program's saves name (the pad layout's key), and
    every keeper, operator and unexpired invite ({!Play_seat.participants}).
    Departure uses {!Keeper_dos_controller.holder_left} under the credential
    transaction. The read does not release a controller; the next actual
    move rechecks departure through {!Keeper_dos_controller.before_move}.
    A fleet that does not list answers [503 {code: "keepers_unreadable"}]. *)

val seat_path : string

val page : nonce:string -> string
(** The page, with [nonce] on its one script and one style tag. *)

val csp_header : string -> string
(** The content-security-policy value for [nonce]. *)

val add_routes : Http_server_eio.Router.t -> Http_server_eio.Router.t
