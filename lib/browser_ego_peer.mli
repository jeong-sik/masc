(** One ego lite task space served as a live browser connection
    (RFC-browser-live-ego). Each command runs one fixed script with
    [ego-browser nodejs]: the task space, its pages and their labels last
    from one run to the next, a script's variables do not, and the download
    waits a script starts last as long as the ego process. The connection gives
    each page it sees a tab number, by the page's label. It reads only the
    pages the space manages; an unmanaged tab the operator opened there is
    listed and refused before any read, unless explicitly adopted. *)

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

(** How long a run that reads waits, opening and ending the space included. *)
val read_window_s : float

(** Who holds an ego task space, as ego names it. [Handed_to_operator] is the
    agent's space that the operator holds until the agent takes it back; a
    connection opens on it. A space the operator made is
    [Operator_owner]'s, and a connection never takes it over. *)
type space_owner = Agent_owner | Handed_to_operator | Operator_owner

(** The script that lists ego's task spaces, each with its number, name and
    owner, without opening a space: opening one by name makes it when it is
    not there. *)
val task_spaces_script : string

(** Why the spaces were not read. [Spaces_failed]: ego did not list them,
    as when it cannot reach ego lite. [Spaces_malformed]: it answered in a
    form masc does not read, such as an owner that is not a {!space_owner}. *)
type spaces_failure = Spaces_failed of string | Spaces_malformed of string

(** The spaces called [space] in what {!task_spaces_script} wrote, compared
    exactly. A row without its number, name or owner, and an owner of a space
    of that name that is not a {!space_owner}, are errors, not guesses. *)
val matching_spaces : space:Browser_configuration.ego_space -> string ->
  ((int * space_owner) list, spaces_failure) result

type t

(** Where an agent page's downloads are saved: [root], a folder under the
    worker's own download folder that no one else writes. [publish path]
    hands one completed file to the worker's download broker and answers the
    marker its row carries as [artifact]. *)
type downloads = { root : string; publish : string -> (Yojson.Safe.t, string) result }

(** Opens the agent task space called [space], or resumes it when this
    space already exists, or resumes the exact configured numeric Space ID.
    A missing ID is never retried by name or replaced with another Space.
    Holds it from then on by the number ego gave
    it. A space of the same name that the operator owns is refused by ego.
    [version] is ego lite's version. Screenshots are written under
    [capture_directory], which this process owns, and removed once read.
    [now] is the time in seconds; a command that runs twice gives its
    second run what is left of its window. Downloads that agent pages start
    are saved and published through [downloads]. [run_native] uses the same
    serial SDK process, without a cumulative reply window: SDK operations own
    their waits and explicit cancellation still stops the process. *)
val open_space
  :  run:runner
  -> run_native:(string -> (string, run_failure) result)
  -> now:(unit -> float)
  -> space:Browser_configuration.ego_space
  -> version:string
  -> capture_directory:string
  -> downloads:downloads
  -> (t, string) result

val space_id : t -> int
(** Space ID and name observed when this connection opened. The ID binds this
    peer for its lifetime. The name is an attachment-time observation, not a
    current ownership, visibility or login claim. *)
val space : t -> Browser_lane.ego_space
val input_status : t -> Browser_ego_input.status
val input_busy : t -> bool
val assert_input_reset : t -> generation:string -> (unit, string) result
(** An assertion from the worker's private operator port only; not a browser
    verb, SDK cleanup acknowledgement, takeover, or login receipt. *)

(** Answers one live verb the way the BiDi peer answers it. [hand_off] returns
    [action], [spaceId] and [spaceName], captured from the same TaskSpace before
    handing it to the operator. This identifies the space for a human request;
    it does not prove that its window is visible or that login succeeded.
    After handing off, ask the operator what is needed and await their explicit
    completion before [take_over]. The peer does not create an Ask or verify an
    operator answer itself. Reads fail
    before any effect. [open_tab], [goto], [back], [forward], [reload] and
    [close_tab] act only on pages an agent opened in the space, and so does
    [page.interact]. [back] and [forward] move one entry in the tab's own
    history and are refused before acting when there is none.
    [upload] gives the worker's copies of a Keeper's files to ego's native
    file-input resolver. Its [chosen] receipt describes the staged files handed
    to the SDK, not a subsequent observation of the page's file list; this connection holds those copies until its
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
    published. Selector and snapshot input use ego's native locator and Page methods,
    including automatic scrolling and iframe/shadow traversal. Selector strings
    follow ego's documented syntax. Scene references, document scrolling and
    direct link following retain the shared page adapter because ego has no
    MASC document/node identity or direct-link primitive. Coordinates and keys
    use ego's mouse and keyboard APIs. Native selectOption follows ego's
    programmatic selection semantics, including disabled options. ego shows each mouse step's label beside
    its cursor: MASC, [actor] (or "agent"), and the interaction, as the BiDi
    connection's overlay does. Native input checks the observed URL before calling ego; this is not an
    atomic navigation guard. Ego owns its locator/actionability waits; a method
    failure is uncertain, including a missing or stale target. Re-read a snapshot after page changes or input and on a native
    stale/unknown ref refusal. Selector drags without waypoints use native [dragAndDrop]. A native drag
    failure adds no synthetic mouse-up; a dialog or missing release proof preserves
    the same release-uncertain state as raw drag. Coordinate and
    scene drags retain the observed waypoint contract, require zero duration
    and release the button in the same run.
    Unconfirmed release blocks further input on this peer; read/finish remain
    available. The private operator controls can record an explicit human
    check/reset assertion for this pending input generation and resume the
    same peer. This remains [operator_asserted], not native release proof.
    Answering a dialog, handing off or taking over alone does not reset it.
    Frames are read
    through the snapshot. Snapshot-target click, fill, hover and double-click
    use ego's native element resolver, including iframe refs; expectedUrl still
    identifies the top-level page. Explicit input framePath is refused here
    with guidance to snapshot targets; frame-path reads are rejected by the
    live transport gate before this peer.
    [adopt_tab] explicitly gives an observed unmanaged tab to the native Page
    lifecycle, optionally with [pageLabel] as the SDK's [as] option.
    [release_tab] unmanages an unknown-origin Page without closing its tab.
    Both require this agent-controlled Space, preserve origin and tab number,
    and refuse while input release is uncertain. Reads support an adopted
    Page; current mutation paths still require agent-created Pages.
    Lost lifecycle receipts require inventory reconciliation, never replay.
    Verbs this connection does not serve are refused before any effect; selection
    refuses them earlier ({!Browser_lane.live_transport_serves}). *)
val dispatch
  :  ?command_id:string
  -> ?actor:string
  -> t
  -> verb:Browser_live_peer.verb
  -> Yojson.Safe.t
  -> (Yojson.Safe.t, Browser_live_peer.failure) result

(** Ends the task space with [keep: []]. Ego closes agent-created Pages and
    preserves unknown-origin managed Pages and unmanaged tabs. Once it has, the upload copies this
    connection held are let go. *)
val finish : t -> (unit, string) result
