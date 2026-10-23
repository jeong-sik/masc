(** Host programs the browser lanes start. Availability is distinct from a lane
    connecting or a page being read: it says a program answers, not that
    runtime.toml names it or that the server has restarted since. *)

type program = Geckodriver | Firefox | Ego_browser

val name : program -> string
(** The name the program carries in the readiness JSON and in
    [masc prerequisite-actions]. *)

val candidates : program -> string list
(** Executables tried in order. A bare name is looked up on [PATH]; a path is
    used as written. Firefox on macOS lives inside its application bundle and
    is on no [PATH], so its bundle locations are listed. ego lite's onboarding
    links [ego-browser] into [~/.local/bin], which is listed after [PATH]. A
    [HOME] that is not an absolute path contributes no location. *)

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

val locate : string -> string option
(** The absolute path of the executable file [command] names, without starting
    it: a name is looked up on [PATH] and a path is used as written. [None] when
    nothing there can be executed (no file, a file without the execute bit, a
    directory). {!probe} runs what this finds. Ask this, not {!probe}, when the
    question is only whether a program is there: starting a program costs up to
    the probe's time budget and a launcher may open a window. *)

val probe : string -> check
(** Resolve one executable (a name on [PATH], or a path) and run its version
    entry point, bounded in time. No installation, no browser window, no
    session.

    The program runs under the scrubbed subprocess environment, the same one
    the PDF and presentation checks use, so server tokens never reach a program
    found on [PATH]. A program that needs a variable the scrub drops (such as
    [DISPLAY]) to print its version reports [Failed]. *)

val ego_versions : string -> (string * string, string) result
(** ego lite's version and its Chromium's, read from what
    [ego-browser --version] printed. *)

val probe_program : program -> string -> check
(** {!probe}, and what [program]'s answer must say. geckodriver and Firefox
    answer by exiting 0. An [ego-browser] must also name ego lite's and
    Chromium's versions ({!ego_versions}); one that exits 0 without them is
    [Failed], as an ego lite whose onboarding is not finished is. *)

val first_answer : label:string -> string list -> check
(** Walk the executables in order and stop at the first that {!probe} reports
    [Started]; a later one is never started. When none answers, the first
    [Failed], otherwise the first [Missing]. [label] names the program in
    [Missing] for an empty list. *)

val observe : program -> check
(** {!first_answer} over {!candidates}, with {!probe_program}'s rule for
    what counts as an answer. *)

val available : check -> bool
val path : check -> string option
(** The absolute path of the program that answered, or of the executable that
    did not. *)

val to_json : program -> check -> Yojson.Safe.t
