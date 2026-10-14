(** Host programs the browser lanes start. Availability is distinct from a lane
    connecting or a page being read: it says a program answers, not that
    runtime.toml names it or that the server has restarted since. *)

type program = Geckodriver | Firefox

val name : program -> string
(** The name the program carries in the readiness JSON and in
    [masc prerequisite-actions]. *)

val candidates : program -> string list
(** Executables tried in order. A bare name is looked up on [PATH]; a path is
    used as written. Firefox on macOS lives inside its application bundle and
    is on no [PATH], so its bundle locations are listed. A [HOME] that is not an
    absolute path contributes no bundle location. *)

type check =
  | Missing of string
      (** No candidate is an executable file. Carries the first candidate's
          name. A file without the execute bit is missing, as it is to a shell
          searching [PATH]. *)
  | Started of { command : string; path : string; output : string }
      (** The executable at [path] answered its version entry point. [path] is
          always absolute: [\[browser.automation\]] and [\[browser.live.bidi\]]
          take absolute paths only. A program found through a relative [PATH]
          entry is reported under the current working directory. *)
  | Failed of { command : string; path : string; status : Unix.process_status; detail : string }
      (** An executable exists at [path] and did not answer. *)

val probe : string -> check
(** Resolve one executable (a name on [PATH], or a path) and run its version
    entry point, bounded in time. No installation, no browser window, no
    session.

    The program runs under the scrubbed subprocess environment, the same one
    the PDF and presentation checks use, so server tokens never reach a program
    found on [PATH]. A program that needs a variable the scrub drops (such as
    [DISPLAY]) to print its version reports [Failed]. *)

val first_answer : label:string -> string list -> check
(** Walk the executables in order and stop at the first that {!probe} reports
    [Started]; a later one is never started. When none answers, the first
    [Failed], otherwise the first [Missing]. [label] names the program in
    [Missing] for an empty list. *)

val observe : program -> check
(** {!first_answer} over {!candidates}. *)

val available : check -> bool
val path : check -> string option
(** The absolute path of the program that answered, or of the executable that
    did not. *)

val to_json : program -> check -> Yojson.Safe.t
