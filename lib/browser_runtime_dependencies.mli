(** Host programs the browser lanes start. Availability is distinct from a lane
    connecting or a page being read: it says a program answers, not that
    runtime.toml names it or that the server has restarted since. *)

type program = Geckodriver | Firefox

val name : program -> string
(** The dependency name [masc prerequisite-actions] takes for the program. *)

val candidates : program -> string list
(** Executables tried in order. A bare name is looked up on [PATH]; a path is
    used as written. Firefox on macOS lives inside its application bundle and
    is on no [PATH], so its bundle locations are listed. *)

type check =
  | Missing of string
      (** No candidate exists. Carries the first candidate's name. *)
  | Started of { command : string; path : string; output : string }
      (** The executable at [path] answered its version entry point. [path] is
          absolute: [\[browser.automation\]] and [\[browser.live.bidi\]] take
          absolute paths only. *)
  | Failed of { command : string; path : string; status : Unix.process_status; detail : string }
      (** An executable exists at [path] and did not answer. *)

val probe : string -> check
(** Resolve one executable (a name on [PATH], or a path) and run its version
    entry point under the scrubbed subprocess environment, bounded in time. No
    installation, no browser window, no session. *)

val observe : program -> check
(** The first {!candidates} entry that {!probe} reports [Started]; otherwise
    the first [Failed]; otherwise [Missing]. *)

val available : check -> bool
val path : check -> string option
(** The absolute path of the program that answered. *)

val to_json : program -> check -> Yojson.Safe.t
