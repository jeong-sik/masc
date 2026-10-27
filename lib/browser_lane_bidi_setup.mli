(** The [\[browser.live.bidi\]] table of [runtime.toml]: the Firefox the MASC
    server starts at a server start, with the profile it opens and the port it
    answers BiDi on. [masc browser-lane-setup --mode bidi] writes it, beside
    the lane installation {!Browser_lane_setup} makes.

    The table belongs to the operator. A table that is there keeps its values:
    the profile it names holds the logins Keepers use, and replacing it would
    log them out. A value changes only when the operator names it. The table
    is written through {!Runtime.edit_config_text}, so comments and every
    other table stay as they were, and what is written is read back the way
    the server reads it before it is committed. *)

type request =
  { runtime_config_path : string
  ; home : string option
        (** Where the default profile goes. Without one the profile must be
            named. *)
  ; firefox : string option
        (** An absolute path. Without one, the first Firefox that answers
            [--version]: [firefox] on [PATH], then the macOS application
            bundle. *)
  ; profile : string option
        (** An absolute path. Without one, [masc-keeper-firefox-profile] in
            [home]. It is not hidden: a Firefox installed as a snap cannot
            open a hidden directory in the home directory. *)
  ; port : int option
        (** Without one the table holds none, and the server uses
            {!Browser_configuration.default_live_bidi_port}. *)
  }

type key = Firefox | Profile | Port

val key_name : key -> string

type change =
  | Created  (** There was no table. *)
  | Updated of key list  (** The table was there; these keys were named. *)
  | Unchanged  (** The table was there and nothing was named. *)

type error =
  | Configuration_missing of string
  | Configuration_unreadable of { path : string; reason : string }
  | Configuration_refused of string
      (** [runtime.toml] does not load, as it is or with the table: its
          [\[browser\]] tables, or the file as the server validates it. The
          sentence is the loader's or the validation's. *)
  | Home_unknown
  | Firefox_not_found
  | Firefox_does_not_answer of { path : string; detail : string }
  | Firefox_not_executable of string
  | Profile_not_a_directory of string
  | Profile_not_created of { path : string; reason : string }
  | Table_refused of string
      (** The text with the table would not load, or loads as another table.
          The sentence is the loader's, or says the table is written in a form
          this command cannot edit. *)
  | Configuration_changed
      (** [runtime.toml] changed after the plan was made. The table was not
          written. *)
  | Not_written of string

val error_message : error -> string

type plan

val table : plan -> Browser_configuration.live_bidi
(** The values the table holds once the plan is applied. *)

val change : plan -> change

val firefox_note : plan -> string option
(** Said when the Firefox the operator named is there and did not answer
    [--version]: it is written as named and not verified. *)

val port_answers : plan -> bool
(** Something already answers on the table's port on the loopback interface.
    Firefox's Remote Agent refuses a second one on that port. A host also
    refuses a session on a Firefox that runs another profile. *)

(** The first Firefox that answers [--version]: {!request}'s [firefox] default. *)
val installed_firefox : unit -> Browser_runtime_dependencies.check

(** Reads [runtime.toml] and decides what the table holds, and refuses what
    can be refused without writing: a [runtime.toml] that does not load, no
    Firefox to name, a profile that is a file, a table that would not load or
    would load as another one. Nothing is written and no directory is made.

    [find_firefox] is asked only when the table is not there and no Firefox is
    named: a table that is there needs none, and asking starts a program. *)
val plan
  :  find_firefox:(unit -> Browser_runtime_dependencies.check)
  -> request
  -> (plan, error) result

type applied = { profile_created : bool }

(** Makes the profile directory (mode [0700]: it keeps cookies) when it is not
    there, then commits the table under the configuration write lock. The
    directory is made first, so a failure leaves a directory and no table,
    never a table naming a profile that cannot be made. A table that is
    unchanged is not rewritten. *)
val apply : plan -> (applied, error) result
