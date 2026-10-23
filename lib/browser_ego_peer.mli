(** One ego lite task space served as a live browser connection
    (RFC-browser-live-ego). Each command runs one fixed script with
    [ego-browser nodejs]: the task space, its pages and their labels last
    from one run to the next, script variables do not. The connection gives
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

(** Opens the agent task space called [space], or resumes it when this
    space already exists, and holds it from then on by the number ego gave
    it. A space of the same name that the operator owns is refused by ego.
    [version] is ego lite's version. Screenshots are written under
    [capture_directory], which this process owns, and removed once read.
    [now] is the time in seconds; a command that runs twice gives its
    second run what is left of its window. *)
val open_space
  :  run:runner
  -> now:(unit -> float)
  -> space:string
  -> version:string
  -> capture_directory:string
  -> (t, string) result

val space_id : t -> int

(** Answers one live verb the way the BiDi peer answers it. Reads fail
    before any effect. [open_tab], [goto] and [close_tab] act only on pages
    an agent opened in the space, and so does [page.interact]: a refusal
    the script makes before acting is [Before_effect], a load that failed
    after it started is a [Partial_failure] with where the tab is now, and a
    run that was stopped or failed where the script cannot say is
    [Outcome_unknown]. Input finds its target, checks the observed page and
    makes its DOM edits with the page scripts the BiDi connection runs, and
    sends mouse and keys through ego; it does not act inside frames. Verbs this
    connection does not serve are refused before any effect; selection
    refuses them earlier ({!Browser_lane.live_transport_serves}). *)
val dispatch
  :  t
  -> verb:Browser_live_peer.verb
  -> Yojson.Safe.t
  -> (Yojson.Safe.t, Browser_live_peer.failure) result

(** Ends the task space. ego closes the pages it manages and keeps the tabs
    the operator opened there. *)
val finish : t -> (unit, string) result
