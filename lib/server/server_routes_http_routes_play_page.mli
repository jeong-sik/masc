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
    An authenticated fetch stream on [GET /api/v1/play/events] carries only
    public Play invalidations. Its subscription precedes the initial read;
    every reconnect resynchronizes frame, seat, pad and room without a replay
    cursor. The bearer is sent only in the Authorization header. View switches
    cancel the old stream and its reads. There is no status-polling fallback.
    DOS writes keep their exact authority/operation receipts. A pending seat
    disables moves. Repeated seat/roster invalidations preserve a healthy read
    and retain one fresh follow-up; the older seat cannot re-enable moves.
    Keeper lifecycle hints carry their public roster identity; unrelated fleet
    activity does not retire an otherwise current holder observation.
    Machine identity changes and transport replacement cancel obsolete reads. Unknown
    writes remain unsettled; observation cannot acknowledge or replay them.
    Pad failures are retried by observation/reconnection, with the original
    saves-name binding. User-focused handoff selection refreshes its roster.

    [POST /api/v1/play/room] provides one public conversation shared by the
    workspace's MSX/DOS viewers, invited participants, operators and Keepers.
    History, chat and presence are independent of game input and controller
    ownership; a spectator can speak while another participant controls DOS.
    Room invalidations refresh history independently of frame/seat reads.
    The stream owns the exact authenticated presence lease and renews it on
    transport keepalive. Departure, revocation, expiry and stream cancellation
    release that lease; ordinary reads and speech never renew it.
    Every room receipt includes its authenticated [viewer]; self marks use it.
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
    stops room observation and chat even when storage deletion fails. Document
    identity guards apply independently to room requests, drafts and receipts;
    an unknown game operation does not stop a current document's conversation.
    Presence leave is dispatched before forgetting the bearer, with no wait
    for its response after the atomic session departure has been acknowledged.

    [GET /api/v1/play/seat] needs [CanPlayMachine] from a bearer and answers
    [{name, connected, machine, controller, controller_recoverable, saves_name}]: the bearer's name,
    its durable handoff eligibility, whether a machine is loaded, who holds the DOS controller ([null] when
    free), whether the holder has authoritatively departed, and the loaded
    program's saves name (the pad layout's key).
    The attached shared DOS Add-on is asked before the credential
    transaction, so a slow worker never holds the workspace credential lock;
    inside the transaction the seat reads the caller's participation and
    judges the observed holder's departure with
    {!Keeper_machine_controller_authority.holder_left}. The read does not
    release a controller; the next actual move rechecks departure through
    its own host admission. A missing or unreadable worker answers
    [503 {code: "machine_unavailable"}]; a worker with no loaded machine
    reports [machine=false]. A fleet that does not list answers
    [503 {code: "keepers_unreadable"}]. *)

val seat_path : string

val participants_path : string
(** [GET /api/v1/play/participants] needs [CanPlayMachine] from a bearer and
    answers [{participants}]: every connected keeper, operator and unexpired
    invite ({!Play_seat.hand_to}), the names [pass] accepts. It reads every
    credential and each one's participation, so it is not part of the seat
    poll; the page reads it when it opens and when a player opens the handoff
    selector. A fleet that does not list answers
    [503 {code: "keepers_unreadable"}]. *)

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
