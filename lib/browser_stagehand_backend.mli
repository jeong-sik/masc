(** The Stagehand lane's backend (RFC-browser-lane-stagehand §3.4).

    The backend owns the session: the browser, its connection and the
    Stagehand runtime live on a fiber of the backend's switch, not on the
    caller's. A caller only asks. When a caller leaves (the lane deadline),
    the page verb it asked for is cancelled, and the session treats that call
    as abandoned; opening and closing run to the end regardless, so no caller
    deadline leaves a browser half started or half stopped. The session is
    shared, so a sentence whose caller leaves does not stop it at once: only
    if the extension has still not answered once the sentence's own deadline
    has passed is the session retired, so a later open can start a fresh
    browser. Callers may run on any fiber or domain. Page verbs are
    serialized for the whole verb, including guard, input and receipt; a
    caller cancelled before its turn does not close the session. Native
    keyboard input whose release was not confirmed quarantines the session
    without closing its browser. Status and explicit close remain available;
    page work and reuse require explicit close and reopen. *)

(** Starts one session whose browser lives on [sw]: releasing [sw] stops it.
    Answers the session and the [stagehand.init] result. *)
type open_error = Not_opened of string | Cleanup_unconfirmed of string
(** A normal refusal with confirmed partial cleanup, or an opening whose
    original resources could not be confirmed settled. Unexpected exceptions
    also leave settlement unconfirmed. Cancellation must join partial resources;
    report failed cleanup to the supplied switch before re-raising it. *)
type 'session opener =
  sw:Eio.Switch.t
  -> headless:bool
  -> log:(Browser_stagehand_session.event -> unit)
  -> ('session * Yojson.Safe.t, open_error) result

type 'session t
val session_observation : 'session t -> Browser_lane.session_observation
(** Nonblocking lifecycle snapshot; never sends a browser command. *)

(** A backend serving requests on fibers of [sw] until [sw] ends. Its
    fibers are daemons: when the rest of [sw] is done, an open session is
    released and its browser stopped rather than holding [sw] open. [call]
    sends one Stagehand call on a session. [log] receives every session
    event. [shutdown] stops the original owned browser exactly once, before
    its transport switch is released. Transport resources survive parent
    cancellation during shutdown; startup work remains cancellable. The
    callback must join its original process and return unconfirmed cleanup
    as an error. It must not replay browser input. *)
val create :
  sw:Eio.Switch.t
  -> clock:_ Eio.Time.clock
  -> open_session:'session opener
  -> call:('session -> Browser_stagehand_executor.call)
  -> private_ready:('session -> bool)
  -> shutdown:('session -> (unit, string) result)
  -> pid:('session -> int)
  -> log:(Browser_stagehand_session.event -> unit)
  -> 'session t

val settlement : 'session t -> (unit, string) result
(** Read the retained terminal shutdown result after the backend lifetime has
    joined. An active lifetime is unconfirmed. A failed shutdown cannot be
    replaced by a later successful idempotent close or an automatic reopen. *)

(** What {!Browser_lane.install_stagehand_executor} takes.

    - [Session_open] starts a session unless one is open, which it reuses.
      A session that stops working (its service worker went away, its
      connection ended, or an answer to the extension could not be
      delivered) is let go at once and its browser stopped, so the next open
      starts a new one; [Session_status] says why until then.
    - [Session_close] asks the runtime to close, then stops the browser.
    - [Session_status] reports the backend's record and sends nothing.
    - Page verbs go to {!Browser_stagehand_executor.execute} on the open
      session one at a time, and are refused before effect when none is
      open. Tab ids count on across sessions: an id from a closed session
      reaches no page of a later one. *)
val execute : 'session t -> ?actor:string -> Browser_lane.verb -> Browser_lane.answer
(** The actor stays with this queued request through the serialized page verb. *)

type private_error = Private_not_started | Private_session_fenced | Private_outcome_unknown
type 'session private_session
val fence_private_session : 'session t -> session:'session private_session -> unit
(** Nonblocking owner-domain notification that the pinned companion went away.
    Fences only the original opened resource, never a successor. An active page
    verb is cancelled and its cleanup joined before its serializer slot returns.
    Every subsequent call and result publication rechecks that exact session:
    a result returned during cancellation or synchronously with the fence is
    discarded with a fixed refusal, including reads and captures. Explicit close
    remains available while cleanup joins; new pages in a reopened browser wait
    for the original verb to release its slot. *)
val capture_private_session : 'session t -> ('session private_session, private_error) result
(** Trusted host-only capture of this exact opened session. Does not open a
    browser, adopt a replacement or send a page/extension operation. The opaque
    pin is process-local and belongs to one backend's original session. *)
val execute_private : 'session t -> session:'session private_session -> tab_id:int ->
  run:('session -> page_id:string -> (Yojson.Safe.t, unit) result) ->
  (Yojson.Safe.t, private_error) result
(** Trusted companion integration, never a model tool. Runs on the backend's
    owner fiber under the same whole-verb serializer as page reads/captures.
    The original MASC tab resolves to its exact CDP page id; this is not a Chrome
    numeric tab id. The adapter must resolve the extension's tab identity.
    [private_ready] must also confirm that an abandoned public extension call
    has settled; it is checked at capture and immediately before callback entry.
    The callback receives the original owned session and may use only its
    verified transport. Its argument/result stays on this private call path.

    Every callback error/exception is an unknown effect: fixed errors contain
    no callback prose, and further page/companion work is fenced until explicit
    close and confirmed original-session retirement. Cancellation before the
    callback begins sends nothing; cancellation after entry fences before the
    page slot is released. Companion loss or confirmed termination of the original
    session also cancels the callback and joins its cleanup before releasing that slot. A
    reopened browser never inherits the callback or its late fence. The callback
    must allow cancellation and finish its cleanup without waiting for a reply
    from the terminated browser. No automatic retry or replacement-session lookup.
    A successful adapter response must mean the extension operation has settled,
    not merely that it was queued. *)
