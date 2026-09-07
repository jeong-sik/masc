(** Keeper_toml_loader -- Otoml-backed parser for keeper configuration.

    Reads TOML files and produces a flat key-value document.
    TOML 1.0 syntax is owned by Otoml; keeper-specific typed accessors and the
    comment-preserving line editor remain here.

    The conversion from TOML to keeper_profile_defaults is done in
    {!Keeper_types_profile} to avoid circular dependencies. *)

(** A single parsed TOML value. *)
type toml_value =
  | Toml_string of string
  | Toml_int of int
  | Toml_float of float
  | Toml_bool of bool
  | Toml_string_array of string list
  | Toml_array of toml_value list
  | Toml_table of (string * toml_value) list
  | Toml_inline_table of (string * toml_value) list
  | Toml_table_array of toml_value list
  | Toml_offset_datetime of string
  | Toml_local_datetime of string
  | Toml_local_date of string
  | Toml_local_time of string

(** A parsed TOML document: mapping from dotted key (e.g. ["keeper.instructions"])
    to value. Tables are flattened with dot separators. *)
type toml_doc = (string * toml_value) list

(** Parse a TOML 1.0 string with Otoml into a flat canonical key-value list.
    Returns [Error msg] on syntax errors. *)
val parse_toml : string -> (toml_doc, string) result

(** {1 Accessor helpers} *)

val toml_string_opt : toml_doc -> string -> string option
val toml_int_opt : toml_doc -> string -> int option
val toml_float_opt : toml_doc -> string -> float option
val toml_bool_opt : toml_doc -> string -> bool option
val toml_string_list : toml_doc -> string -> string list

(** {1 TOML writer} *)

(** Update or insert a key under a [\[table\]] in a TOML string.
    Dotted keys follow their parsed TOML path, so an existing nested table is
    edited in place instead of creating a second definition in its parent.
    Preserves comments, formatting, and other fields.
    Returns [Ok new_content] or [Error reason] if the table is not found. *)
val update_field_in_content :
  table:string -> key:string -> value:string -> string -> (string, string) result

type toml_edit =
  | Set of toml_value
  | Remove

val edit_keeper_toml_fields_strict_staged :
  path:string ->
  (string * toml_edit) list ->
  (unit, Fs_compat.atomic_replace_failure) result

val create_keeper_toml_file_strict_staged :
  path:string ->
  (string * toml_value) list ->
  (unit, Fs_compat.atomic_replace_failure) result
