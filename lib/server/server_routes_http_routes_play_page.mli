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
    One viewer switches between [dos_capture] and [msx_capture] on
    [GET /api/v1/lane-addons/live?source_kind=...]. Switching views clears the
    prior frame and prevents a late response from repainting the new view.
    DOS controls send keys, text and hand-offs to [POST /api/v1/dos/*]; MSX is
    observation only. Idle DOS seat reads use a slower cadence than frame
    polling; new activity and opening handoff targets refresh immediately.
    Activity during a pending read is coalesced and observed after it completes;
    stalled seat reads are replaced at the recovery cadence. Disconnect drains
    admitted writes without waiting for projection reads.
    Participation is checked at the idle cadence even with a free controller or
    MSX selected, so another client can depart and rejoin without game activity.
    Observed participation changes suspend/resume chat independently of a local
    confirmed disconnect. Departed controllers are discovered without game activity. When the
    loaded program has a masc pad layout ([GET /api/v1/play/pad]) it draws
    that pad in place of the plain keys row, and reads a physical gamepad in
    the standard mapping onto the same buttons. A pad read that fails shows the keys row and a
    status line, and the next poll reads it again. Each button press carries
    the saves name its layout was read for. A stalled layout read is replaced
    at the slower seat recovery cadence without stopping frame polling.

    [POST /api/v1/play/room] provides one public conversation shared by the
    workspace's MSX/DOS viewers, invited participants, operators and Keepers.
    History, chat and presence are independent of game input and controller
    ownership; a spectator can speak while another participant controls DOS.
    Room polling starts independently of the first seat read and continues
    on its own timer when a game read remains pending. It
    replaces a stalled read at the seat recovery cadence without retrying a
    pending message. Every room receipt must include its authenticated [viewer]; self marks use that identity
    independently of the DOS seat response.
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
    first removes the bearer-bearing draft, then the saved invitation. Any
    removal failure keeps the local session retryable. Confirmed departure
    stops room polling and chat even when storage deletion fails. Document
    identity guards apply independently to room requests, drafts and receipts;
    an unknown game operation does not stop a current document's conversation.
    Presence leave is dispatched before forgetting the bearer, with no wait
    for its response after the atomic session departure has been acknowledged.

    [GET /api/v1/play/seat] needs [CanPlayMachine] from a bearer and answers
    [{name, connected, machine, controller, controller_recoverable, saves_name, participants}]: the bearer's name,
    its durable handoff eligibility, whether a machine is loaded, who holds the DOS controller ([null] when
    free), whether the holder has authoritatively departed, the loaded
    program's saves name (the pad layout's key), and
    every connected keeper, operator and unexpired invite ({!Play_seat.participants}).
    Departure uses {!Keeper_dos_controller.holder_left} under the credential
    transaction. The read does not release a controller; the next actual
    move rechecks departure through {!Keeper_dos_controller.before_move}.
    A fleet that does not list answers [503 {code: "keepers_unreadable"}]. *)

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
