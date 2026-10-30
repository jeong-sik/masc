(** Runtime_setting_set -- write keys of runtime.toml that the keeper runtime
    settings registry names.

    The registry ({!Keeper_runtime_setting_registry}) says which keys exist and
    what each one holds, so a key it does not name is refused and a value is
    read as the row's kind before anything is edited. The edit goes through
    {!Runtime.edit_config_text}, so the read, the edit and the commit happen
    inside one config write lock, and through {!Toml_line_editor}, so comments
    and unrelated tables survive byte-for-byte.

    Built the way {!Web_search_setup} is. What the loader checks per key (type
    and range) is checked here before the commit. What a value means to the
    reader of a row (a blank wake prompt, an address a guest cannot use) is
    not: the server refuses it when it starts.

    A changed string, integer or float line loses its own trailing comment; a
    boolean keeps it. Comments on other lines stay. A second run with the same
    arguments leaves the file as the first run wrote it. *)

type change
(** One key set to one value, read as the registry row's kind. *)

type error =
  | Unknown_key of string
      (** Not a key the registry names. The key is as the caller wrote it. *)
  | Invalid_value of
      { toml_key : string
      ; expected : string
      }
      (** The value is not the kind the row holds. [expected] says what it
          takes, in words. *)
  | Conflicting_changes of string
      (** Two changes address one key, so which one is meant is not decided
          here. Nothing was written. *)
  | Table_not_reachable of string
      (** The table is written as an inline table or as dotted keys at the top
          of the file. A line editor would open a header beside it, which TOML
          1.0 forbids. Nothing was written. *)
  | Not_valid of string
      (** The text after the change does not parse, or a changed key does not
          pass the loader's type and range check. The message is the loader's
          sentence. Nothing was written. *)
  | Not_read_back of string
      (** The edit was made and the loader still does not read the requested
          value at this key: the line editor and the loader disagree about
          where it is. Nothing was written. *)
  | Configuration_rejected of string
      (** The commit was refused. The whole file is validated on every commit,
          so an unrelated table that is already broken refuses this edit too;
          the message says which. *)

val error_message : error -> string

val parse : key:string -> value:string -> (change, error) result
(** [parse ~key ~value] resolves [key], a dotted key such as
    [autonomous.enabled], to its registry row and reads [value] as that row's
    kind. A boolean is [true] or [false]; an integer is decimal digits with an
    optional leading [-]; a float is a finite decimal number; text is taken as
    given, and may be empty. *)

val toml_key : change -> string
(** The dotted key the change writes. *)

val requires_restart : change -> bool
(** Whether a running server picks the change up only when it restarts, as the
    registry says for the row. *)

val apply : runtime_config_path:string -> change list -> (bool, error) result
(** Apply every change in order, in one commit under the config write lock. At
    most one change per key. All of them or none. [Ok true] when the file's
    bytes changed, [Ok false] when it already held exactly this. An empty list
    writes nothing. *)
