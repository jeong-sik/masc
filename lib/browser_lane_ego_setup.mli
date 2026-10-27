(** The [\[browser.live.ego\]] table of [runtime.toml]: the ego lite task
    space the browser Add-on serves as a live connection (RFC-browser-live-ego
    §7). [masc browser-lane-setup --mode ego] writes it.

    The table belongs to the operator. A table that is there keeps its values;
    a value changes only when the operator names it. An [ego-browser] this
    writes must answer [--version] with ego lite's and Chromium's versions: a
    configured ego that cannot start fails the browser Add-on worker's start,
    and with it the other connections that worker serves. The table is written
    through {!Runtime_table_edit}, so comments and every other table stay as
    they were, and what is written is read back the way the server reads it
    before it is committed. *)

type request =
  { runtime_config_path : string
  ; command : string option
        (** An absolute path. Without one, the first [ego-browser] that
            answers [--version]
            ({!Browser_runtime_dependencies.candidates}). *)
  ; space : string option
        (** A name when provided. Without one, keep the existing name or
            numeric ID; a new table uses {!default_space}. *)
  }

(** The task space a new table names. *)
val default_space : string

type key = Command | Space

val key_name : key -> string

type change =
  | Created  (** There was no table. *)
  | Updated of key list  (** The table was there; these keys were named. *)
  | Unchanged  (** The table was there and nothing was named. *)

type error =
  | Configuration_missing of string
  | Configuration_unreadable of { path : string; reason : string }
  | Configuration_refused of string
      (** [runtime.toml] does not load, as it is or with the table. The
          sentence is the loader's or the validation's. *)
  | Ego_not_found
  | Ego_not_executable of string
  | Ego_unusable of { path : string; detail : string }
      (** It did not answer [--version], or answered without ego lite's and
          Chromium's versions, as an ego lite whose onboarding is not
          finished does. *)
  | Ego_unstartable of { path : string; detail : string }
      (** The table's [ego-browser] could not be started to list the spaces,
          as one that is gone; [detail] is why. *)
  | Table_refused of string
      (** The text with the table would not load, or loads as another table.
          The sentence is the loader's, or says the table is written in a form
          this command cannot edit. *)
  | Space_held_by_operator of { space : Browser_configuration.ego_space; space_id : int }
      (** A task space of the name the table would write is the
          operator's: ego would refuse the worker that opens it by that
          name, and masc does not take it over. *)
  | Spaces_unanswered of { path : string; space : Browser_configuration.ego_space; detail : string }
      (** The ego-browser at [path] did not list ego's task spaces, so
          whether the operator holds [space] is unknown. *)
  | Spaces_unreadable of { path : string; space : Browser_configuration.ego_space; detail : string }
      (** It listed them in a form masc does not read. *)
  | Configuration_changed
      (** [runtime.toml] changed after the plan was made, or, for a plan
          made again, this table changed. The table was not written. *)
  | Not_written of string

val error_message : error -> string

type plan

val table : plan -> Browser_configuration.live_ego
(** The values the table holds once the plan is applied. *)

val change : plan -> change

val versions : plan -> (string * string) option
(** ego lite's and Chromium's versions, when the plan started the
    [ego-browser] it writes. A table that keeps its command does not start
    it for them. *)

(** The first [ego-browser] that answers [--version]: {!request}'s [command]
    default. *)
val installed_ego : unit -> Browser_runtime_dependencies.check

(** Reads [runtime.toml] and decides what the table holds, and refuses what
    can be refused without writing: a [runtime.toml] that does not load, no
    [ego-browser] to name, one that does not name its versions, a table that
    would not load or would load as another one, a space the table would
    hold that the operator holds, and a space that cannot be checked.
    Nothing is written.

    The space the table holds once the plan is applied, written or kept, is
    looked up in ego's task spaces with the [ego-browser] the table names,
    which reads the list without opening a space.

    [find_ego] is asked only when the table is not there and no command is
    named: a table that is there needs none, and asking starts a program. *)
val plan
  :  find_ego:(unit -> Browser_runtime_dependencies.check)
  -> request
  -> (plan, error) result

(** The same plan against the file as it is now, for when another table was
    written to it since. Nothing is looked for or started again; the edit is
    made on the file, read back and validated, and the revision is taken from
    it. A [\[browser.live.ego\]] that changed since the plan was written by
    someone else, and is refused as [Configuration_changed] rather than
    overwritten. *)
val replan : plan -> (plan, error) result

(** Commits the table under the configuration write lock. A table that is
    unchanged is not rewritten. *)
val apply : plan -> (unit, error) result
