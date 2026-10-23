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
  ; space : string option  (** Without one, {!default_space}. *)
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
  | Table_refused of string
      (** The text with the table would not load, or loads as another table.
          The sentence is the loader's, or says the table is written in a form
          this command cannot edit. *)
  | Configuration_changed
      (** [runtime.toml] changed after the plan was made. Nothing was
          written. *)
  | Not_written of string

val error_message : error -> string

type plan

val table : plan -> Browser_configuration.live_ego
(** The values the table holds once the plan is applied. *)

val change : plan -> change

val lane_enabled : plan -> bool
(** [\[browser.live\] enabled] is not false. While it is, the connection
    takes no command. The table is written either way. *)

val versions : plan -> (string * string) option
(** ego lite's and Chromium's versions, when the plan started the
    [ego-browser] it writes. A table that keeps its command starts none. *)

(** The first [ego-browser] that answers [--version]: {!request}'s [command]
    default. *)
val installed_ego : unit -> Browser_runtime_dependencies.check

(** Reads [runtime.toml] and decides what the table holds, and refuses what
    can be refused without writing: a [runtime.toml] that does not load, no
    [ego-browser] to name, one that does not name its versions, a table that
    would not load or would load as another one. Nothing is written.

    [find_ego] is asked only when the table is not there and no command is
    named: a table that is there needs none, and asking starts a program. *)
val plan
  :  find_ego:(unit -> Browser_runtime_dependencies.check)
  -> request
  -> (plan, error) result

(** The same plan against the file as it is now, for when another table was
    written to it since. Nothing is looked for or started again; the edit is
    made on the file, read back and validated, and the revision is taken from
    it. *)
val replan : plan -> (plan, error) result

(** Commits the table under the configuration write lock. A table that is
    unchanged is not rewritten. *)
val apply : plan -> (unit, error) result
