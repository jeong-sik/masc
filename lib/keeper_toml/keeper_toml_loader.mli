(** Keeper_toml_loader -- minimal TOML parser for keeper configuration.

    Reads TOML files and produces a flat key-value document.
    Supports tables, strings (with escapes), integers, floats, booleans,
    and string arrays. No external dependency required.

    The conversion from TOML to keeper_profile_defaults is done in
    {!Keeper_types_profile} to avoid circular dependencies. *)

(** A single parsed TOML value. *)
type toml_value =
  | Toml_string of string
  | Toml_int of int
  | Toml_float of float
  | Toml_bool of bool
  | Toml_string_array of string list

(** A parsed TOML document: mapping from dotted key (e.g. ["keeper.instructions"])
    to value. Tables are flattened with dot separators. *)
type toml_doc = (string * toml_value) list

(** Parse a TOML string into a flat key-value list.
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
    Preserves comments, formatting, and other fields.
    Returns [Ok new_content] or [Error reason] if the table is not found. *)
val update_field_in_content :
  table:string -> key:string -> value:string -> string -> (string, string) result

(** Update a field in a keeper TOML file on disk.
    Reads the file, modifies the field under [\[keeper\]], and writes back.
    Returns [Ok ()] on success or [Error reason] on failure. *)
val update_keeper_toml_field :
  path:string -> key:string -> value:string -> (unit, string) result
