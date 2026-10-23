(** One ego lite task space served as a live browser connection
    (RFC-browser-live-ego). Each command runs one fixed script with
    [ego-browser nodejs]: the task space, its pages and their labels last
    from one run to the next, script variables do not. The connection gives
    each page it sees a tab number, by the page's label. It reads only the
    pages the space manages; a tab the operator opened there is listed and
    refused before any read. *)

(** Why a run gave no output to read. [Exited]: it ended with a non-zero
    code; [output] is the end of what it wrote. [Timed_out]: it did not end
    within the runner's window and was stopped, so whatever it started in
    the browser may still be going on. [Unstarted]: it never ran. *)
type run_failure =
  | Exited of { code : int; output : string }
  | Timed_out
  | Unstarted of string

val run_failure_message : run_failure -> string

(** Runs one script and answers everything it wrote, stdout and stderr
    together, once it exited with code 0. *)
type runner = string -> (string, run_failure) result

(** The prefix of the one line each script writes its answer on. *)
val result_marker : string

(** ego lite's version and its Chromium's, read from what
    [ego-browser --version] printed. *)
val version_of_output : string -> (string * string, string) result

type t

(** Opens the agent task space called [space], or resumes it when this
    space already exists, and holds it from then on by the number ego gave
    it. A space of the same name that the operator owns is refused by ego.
    [version] is ego lite's version. Screenshots are written under
    [capture_directory], which this process owns, and removed once read. *)
val open_space
  :  run:runner
  -> space:string
  -> version:string
  -> capture_directory:string
  -> (t, string) result

val space_id : t -> int

(** Answers one live verb the way the BiDi peer answers it. Reads fail
    before any effect. Verbs this connection does not serve are refused
    before any effect; selection refuses them earlier
    ({!Browser_lane.live_transport_serves}). *)
val dispatch
  :  t
  -> verb:Browser_live_peer.verb
  -> Yojson.Safe.t
  -> (Yojson.Safe.t, Browser_live_peer.failure) result

(** Ends the task space. ego closes the pages it manages and keeps the tabs
    the operator opened there. *)
val finish : t -> (unit, string) result
