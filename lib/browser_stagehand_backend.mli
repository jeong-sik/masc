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
    browser. Callers may run on any fiber or domain. *)

(** Starts one session whose browser lives on [sw]: releasing [sw] stops it.
    Answers the session and the [stagehand.init] result. *)
type 'session opener =
  sw:Eio.Switch.t
  -> headless:bool
  -> log:(Browser_stagehand_session.event -> unit)
  -> ('session * Yojson.Safe.t, string) result

type 'session t

(** A backend serving requests on fibers of [sw] until [sw] ends. Its
    fibers are daemons: when the rest of [sw] is done, an open session is
    released and its browser stopped rather than holding [sw] open. [call]
    sends one Stagehand call on a session. [log] receives every session
    event. *)
val create :
  sw:Eio.Switch.t
  -> clock:_ Eio.Time.clock
  -> open_session:'session opener
  -> call:('session -> Browser_stagehand_executor.call)
  -> pid:('session -> int)
  -> log:(Browser_stagehand_session.event -> unit)
  -> 'session t

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
val execute : 'session t -> Browser_lane.verb -> Browser_lane.answer
