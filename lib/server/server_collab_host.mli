(** Server-side collab host session (RFC-0471 stack 3).

    One session shares one keeper's live chat in one relay room. Guests
    hello (sealed) and receive a unicast welcome plus a journal snapshot in
    chunks; live turn events then stream as sealed entry frames. The session
    joins the relay in-process (see {!Server_collab_route.host_join_local}),
    so no host socket exists.

    Snapshot source is the keeper's latest operation journal: the exact id
    when the publish hook has seen this keeper since boot, else the most
    recently modified journal (documented heuristic — journals carry no
    cross-file order; the live stream is authoritative afterwards). An
    unreadable or missing journal yields an empty snapshot, never a failed
    start: sharing live matters more than sharing history.

    All functions below run on Eio fibers. *)

type session

val snapshot_chunk_bytes : int
(** [524288]. Snapshot rows pack into chunks under this size; a single row
    past it is skipped with a warning (rows are small by construction —
    media bytes live in the media store, not the journal). *)

val snapshot_total_bytes : int
(** [8388608]. Journals past this size snapshot their tail window only
    (whole rows from the first line boundary in the window): a guest hello
    must never page a gigabyte of history into the host. The tail bypasses
    the locked journal reader; a torn tail row fails validation and is
    skipped like any other unparsable row. *)

val live_queue_cap : int
(** [4096]. Live events buffered per room between turn publishes and guest
    sends. Past the cap the newest events drop with a warning count: a slow
    guest must never wedge a keeper turn. *)

val max_guest_label_bytes : int
(** [64]. Hello labels past this size (or blank after trimming) are
    dropped, not truncated: the guest's prompts then carry no display
    name, only the [guest-N] speaker. *)

type start_error =
  | Room_conflict
  | Seal_key_rejected

val start
  :  sw:Eio.Switch.t
  -> base_dir:string
  -> keeper:string
  -> ?send:(room:Collab_relay.room_id -> string -> unit)
  -> ?injector:Server_collab_inject.injector
  -> unit
  -> (session, start_error) result
(** [start ~sw ~base_dir ~keeper ?send ?injector ()] mints a room, joins
    the relay as its host, registers the keeper tap, and forks the forward
    fiber under [sw]. [Room_conflict] is a 128-bit id collision (retry with
    a fresh start); [Seal_key_rejected] is defensive (a generated key is
    always well-formed). [send] defaults to the relay route and [injector]
    to the production keeper injection; tests inject a capture and a stub. *)

val stop : session -> unit
(** [stop s] broadcasts [bye], leaves the relay (guests get [room-closed]
    plus the 4001 close), unregisters the tap, and ends the forward fiber.
    Idempotent. Suspends on an Eio mutex: call from a fiber, never from a
    [Fun.protect] finally clause. *)

val stop_all : unit -> unit
(** [stop] every live session. The server shutdown hook calls this. Same
    suspension rule as {!stop}. *)

val live_for_keeper : string -> session list
(** Live sessions sharing [keeper], newest first. The HTTP trigger layer
    resumes the newest instead of minting a second room when the operator
    runs [/collab] twice. *)

val session_keeper : session -> string
val session_room_id : session -> Collab_relay.room_id
val session_room : session -> Collab_link.room
(** The room (id, key, write token) for link formatting at the trigger
    layer. *)

val notify_published
  :  keeper:string
  -> operation:string
  -> seq:int
  -> ts:float
  -> Keeper_chat_events.keeper_chat_event
  -> unit
(** Turn-bus publish hook entry, installed by the chat-stream route next to
    the journal append (journal first, then this — snapshot/drain
    correctness rests on that order). Records the keeper's latest operation
    and enqueues into every live room for [keeper]. Never suspends the
    publisher past a brief mutex hold; never raises except
    [Eio.Cancel.Cancelled]. *)

val handle_envelope : session -> string -> unit
(** [handle_envelope s bytes] handles one sealed guest envelope (sender id
    already rewritten by the relay): hello authenticates (sealed write
    token) and earns a unicast welcome plus a fresh snapshot; undecryptable
    or malformed frames drop with a debug log and never close the room.
    Prompt and abort require a control capability (anything else earns a
    unicast [error]; successes stay silent and announce on the live
    stream); transcript fetches are view-safe and always answered.

    The forwarder broadcasts from session start, so a guest MAY receive
    live entries before its welcome. Guests MUST buffer pre-welcome
    entries and join them against the snapshot by [(op, op_seq)];
    entry order per sender is room-sequence order, but welcome is not a
    barrier. Likewise entries already inside a socket write may still
    land after [bye]: guests ignore post-bye frames. *)

val peer_joined : session -> Collab_relay.peer -> unit
val peer_left : session -> Collab_relay.peer -> unit
(** Relay membership callbacks (wired to the driver's local-host record).
    [peer_left] for an unknown peer is a silent no-op. *)
