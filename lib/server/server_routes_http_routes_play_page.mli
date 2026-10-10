(** Server_routes_http_routes_play_page — the page an invite link opens and
    the seat it reads (RFC play-link-for-the-shared-machine §2.6).

    [GET /play] ({!Server_auth.play_page_path}) is public and self-contained:
    a CSP with a fresh CSPRNG nonce admits only its inline script and style,
    and it connects only to this server. It reads the bearer from the link's
    fragment, removes the fragment from the address bar, and keeps the bearer
    in the browser tab's session storage so a reload can reconnect. Leaving
    the page through its disconnect action atomically excludes this credential
    generation from future handoffs and releases its controller before clearing
    the local credential. Storage deletion failure retains a retryable session
    with game input disabled. An unknown write retains its operation marker and
    credential; polling cannot acknowledge it or reconnect a departed session.
    The original valid link can explicitly reconnect on a new document's first
    successful seat read, without taking control. A superseded document cannot
    reconnect or clear a newer document's identity or pending operation.
    A different invitation opened while connected asks the user to disconnect
    first. If tab storage is unavailable, the original fragment permits only
    observation: game writes and explicit disconnect are refused. Reload then
    requires the original link. Partial DOS text receipts retain the unpressed
    suffix; unknown byte counts or an edited draft retain the full draft.
    It draws [GET /api/v1/lane-addons/live?source_kind=dos_capture],
    sends keys, text and hand-offs to [POST /api/v1/dos/*], and reads the seat
    again immediately whenever the live activity feed moves. Unchanged-activity
    participation reads continue every five seconds even with a free controller;
    refused reconnect retries retain their own five-second cadence.
    Disconnect drains admitted writes, without waiting for their projection reads.
    When the loaded program has
    a masc pad layout ([GET /api/v1/play/pad]) it draws that pad in place of
    the plain keys row, and reads a physical gamepad in the standard mapping
    onto the same buttons. A pad read that fails shows the keys row and a
    status line, and the next poll reads it again. Each button press carries
    the saves name its layout was read for.

    [GET /api/v1/play/seat] needs [CanPlayMachine] from a bearer and answers
    [{name, connected, machine, controller, controller_recoverable, saves_name, participants}]: the bearer's name,
    its durable handoff eligibility, whether a machine is loaded, who holds the DOS controller ([null] when
    free), whether the holder has authoritatively departed, the loaded
    program's saves name (the pad layout's key), and
    every connected keeper, operator and unexpired invite ({!Play_seat.participants}).
    Seat and controller state are read from the attached shared DOS Add-on
    under one credential transaction, and departure is judged with
    {!Keeper_machine_controller_authority.holder_left}. The read does not
    release a controller; the next actual move rechecks departure through
    its own host admission. A missing or unreadable worker answers
    [503 {code: "machine_unavailable"}]; a worker with no loaded machine
    reports [machine=false]. A fleet that does not list answers
    [503 {code: "keepers_unreadable"}]. *)

val seat_path : string
val session_path : string
(** [POST /api/v1/play/session] with exactly [{connected: boolean}]. False
    durably excludes this credential generation from handoff targets and
    releases its controller under one Auth transaction; true explicitly
    reconnects the still-valid invitation without claiming control. *)

val page : nonce:string -> string
(** The page, with [nonce] on its one script and one style tag. *)

val csp_header : string -> string
(** The content-security-policy value for [nonce]. *)

val add_routes : Http_server_eio.Router.t -> Http_server_eio.Router.t
