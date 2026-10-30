(** The automation lane's configuration in [runtime.toml]: the geckodriver the
    MASC server starts when it starts, and optionally the browser geckodriver
    launches. [masc browser-lane-setup --mode automation] writes it. The lane
    needs no host, no extension and no login: each session opens a fresh
    profile.

    The same rules as {!Browser_lane_bidi_setup}: a configuration that is
    already there keeps its values and a value changes only when it is named;
    comments and every other table stay as they were; what is written is read
    back the way the server reads it, and the whole file is validated, before
    it is committed.

    The loader accepts the keys in two places, [\[browser.automation\]] and
    directly in [\[browser\]]. A configuration that is there is edited where it
    is. A new one goes to [\[browser.automation\]]. *)

type request =
  { runtime_config_path : string
  ; geckodriver : string option
        (** An absolute path. Without one, the [geckodriver] [PATH] names
            first, when it answers [--version]; one that does not is an error,
            not a reason to look further. *)
  ; browser : string option
        (** The [binary] the driver launches, an absolute path. Never written
            unless named: geckodriver finds Firefox itself, and an installed
            Firefox found here would pin it. A path with a space or a tab
            before or after it is refused, since the program looked for and the
            value written would be two different names. *)
  }

type key = Geckodriver | Browser

val key_name : key -> string
(** The key as [runtime.toml] spells it. *)

type change =
  | Created  (** There was no geckodriver configured. *)
  | Updated of key list  (** One was; these keys were named and differ. *)
  | Unchanged  (** One was and nothing was named that differs. *)

type location =
  | New_table  (** [\[browser.automation\]], written by this command. *)
  | Automation_table  (** [\[browser.automation\]], as it was. *)
  | Browser_table  (** The keys directly in [\[browser\]], as they were. *)

type error =
  | Configuration_missing of string
  | Configuration_unreadable of { path : string; reason : string }
  | Configuration_refused of string
      (** runtime.toml does not load, as it is or with the change. The sentence
          is the loader's or the validation's. *)
  | Geckodriver_not_found
  | Geckodriver_does_not_answer of { path : string; detail : string }
  | Not_executable of { key : key; path : string }
  | Table_refused of string
  | Configuration_changed
      (** [runtime.toml] changed after the plan was made, or, for a plan
          made again, the automation table changed. The table was not
          written. *)
  | Not_written of string

val error_message : error -> string

type plan

val table : plan -> Browser_configuration.automation
(** The values the configuration holds once the plan is applied. *)

val change : plan -> change
val location : plan -> location

val notes : plan -> string list
(** Said when a program the operator named is there and did not answer
    [--version]: it is written as named and not verified. Also said for a value
    the configuration already holds, and keeps, that names a file that is not an
    executable one now: the value is left as it is and the note names the flag
    that changes it. The program is located and never started. *)

val installed_geckodriver : unit -> Browser_runtime_dependencies.check
(** The [geckodriver] [PATH] finds first, with whether it answers
    [--version]. *)

(** Reads [runtime.toml] and decides what it holds, and refuses what can be
    refused without writing. Nothing is written. [find_geckodriver] is asked
    only when no geckodriver is configured and none is named. *)
val plan
  :  find_geckodriver:(unit -> Browser_runtime_dependencies.check)
  -> request
  -> (plan, error) result

(** The same decisions against the file as it is now, for a plan whose file
    another write of this command has changed since (the bidi table, in the
    same run). The table, its keys and the notes are kept and nothing is looked
    for or started again; the file is read, the edit is made on it, read back
    and validated, and the revision is taken from it. An automation table that
    changed since the plan was written by someone else, and is refused as
    [Configuration_changed] rather than overwritten. *)
val replan : plan -> (plan, error) result

(** Commits the change under the configuration write lock. A configuration
    that is unchanged is not rewritten. *)
val apply : plan -> (unit, error) result
