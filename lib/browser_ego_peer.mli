(** One ego lite task space served as a live browser connection
    (RFC-browser-live-ego). Each command runs one fixed script with
    [ego-browser nodejs]: the task space, its pages and their labels last
    from one run to the next, a script's variables do not, and the download
    waits a script starts last as long as the ego process. The connection gives
    each page it sees a tab number, by the page's label. It reads only the
    pages the space manages; a tab the operator opened there is listed and
    refused before any read. *)

(** Why a run gave no output to read. [Exited]: it ended with a non-zero
    code; [output] is the end of what it wrote. [Signaled]: a signal ended
    it. [Timed_out]: it did not end within the runner's window and was
    stopped, so whatever it started in the browser may still be going on.
    [Output_exceeded]: it wrote more than {!output_limit_bytes} and was
    stopped. [Unobserved]: it started, and reading its output or its end
    failed. [Unstarted]: it never ran. *)
type run_failure =
  | Exited of { code : int; output : string }
  | Signaled of int
  | Timed_out
  | Output_exceeded
  | Unobserved of string
  | Unstarted of string

(** The most a runner keeps of one run's output: the one answer line of the
    largest page answer this peer accepts, and the frame around it. *)
val output_limit_bytes : int

val run_failure_message : run_failure -> string

(** Runs one script and answers within [window_s] seconds, stopping the run
    when it would not, with everything it wrote, stdout and stderr together,
    once it exited with code 0. The peer gives each command the window the
    server waits for its answer, less the time to deliver the answer. *)
type runner = window_s:float -> string -> (string, run_failure) result

(** The prefix of the one line each script writes its answer on. *)
val result_marker : string

type t

(** Where an agent page's downloads are saved: [root], a folder under the
    worker's own download folder that no one else writes. [publish path]
    hands one completed file to the worker's download broker and answers the
    marker its row carries as [artifact]. *)
type downloads = { root : string; publish : string -> (Yojson.Safe.t, string) result }

(** Opens the agent task space called [space], or resumes it when this
    space already exists, and holds it from then on by the number ego gave
    it. A space of the same name that the operator owns is refused by ego.
    [version] is ego lite's version. Screenshots are written under
    [capture_directory], which this process owns, and removed once read.
    [now] is the time in seconds; a command that runs twice gives its
    second run what is left of its window. Downloads that agent pages start
    are saved and published through [downloads]. *)
val open_space
  :  run:runner
  -> now:(unit -> float)
  -> space:string
  -> version:string
  -> capture_directory:string
  -> downloads:downloads
  -> (t, string) result

val space_id : t -> int

(** Answers one live verb the way the BiDi peer answers it. Reads fail
    before any effect. [open_tab], [goto], [back], [forward], [reload] and
    [close_tab] act only on pages an agent opened in the space, and so does
    [page.interact]. [back] and [forward] move one entry in the tab's own
    history and are refused before acting when there is none.
    [upload] sets the worker's copies of a Keeper's files on one CSS-matched
    file input of such a page; this connection holds those copies until its
    space has ended, since the page reads them later.
    [accept_dialog] and [dismiss_dialog] answer the JavaScript dialog such a
    page is blocked on; a listed row of a managed page carries the dialog
    blocking it, and while one is open, reads, moves and input on that page
    are refused before any effect. A pointer or key input that opens a
    dialog answers with it; a DOM input the dialog stopped is a
    [Partial_failure] with the dialog. A refusal the script makes before
    acting is [Before_effect], a load that failed
    after it started is a [Partial_failure] with where the tab is now, and a
    run that was stopped or failed where the script cannot say is
    [Outcome_unknown]. [page.downloads] lists the downloads an agent page
    started while this ego process watched it: each step that acts on such
    a page starts watching it, and a row says pending, completed or
    interrupted as {!Browser_downloads} does, a completed file once
    published. Input finds its target, checks the observed page and
    makes its DOM edits with the page scripts the BiDi connection runs, and
    sends mouse and keys through ego. ego shows each mouse step's label beside
    its cursor: MASC, [actor] (or "agent"), and the interaction, as the BiDi
    connection's overlay does. Snapshot target input checks the URL
    again after the native selector wait; this is not an atomic navigation
    guard. Re-read a snapshot after page changes or input and on a native
    stale/unknown ref refusal. Native drags share the observed waypoint
    contract, require zero duration and release the button in the same run.
    Unconfirmed release blocks further input on this peer; read/finish remain
    available. End this task space before opening a fresh peer. It does not
    serve explicit framePath operations. Snapshot-target click, fill, hover and
    double-click use ego's native element resolver, including iframe refs;
    expectedUrl still identifies the top-level page. Verbs this
    connection does not serve are refused before any effect; selection
    refuses them earlier ({!Browser_lane.live_transport_serves}). *)
val dispatch
  :  ?actor:string
  -> t
  -> verb:Browser_live_peer.verb
  -> Yojson.Safe.t
  -> (Yojson.Safe.t, Browser_live_peer.failure) result

(** Ends the task space. ego closes the pages it manages and keeps the tabs
    the operator opened there. Once it has, the upload copies this
    connection held are let go. *)
val finish : t -> (unit, string) result
