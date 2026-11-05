(** Keeper_toml_loader -- Otoml-backed parser for keeper configuration.

    Reads TOML files and produces a flat key-value document.
    TOML 1.0 syntax is owned by Otoml; keeper-specific typed accessors and the
    comment-preserving line editor remain here.

    The conversion from TOML to keeper_profile_defaults is done in
    {!Keeper_types_profile} to avoid circular dependencies. *)

include module type of struct include Keeper_toml_parser end

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

(** Pure counterpart of the staged editor, for assessing an exact migration
    before acquiring its write boundary. Preserves unrelated content. *)
val edit_keeper_fields_in_content :
  string -> (string * toml_edit) list -> (string, string) result

val edit_keeper_toml_fields_strict_staged :
  path:string ->
  (string * toml_edit) list ->
  (unit, Fs_compat.atomic_replace_failure) result

val create_keeper_toml_file_strict_staged :
  path:string ->
  (string * toml_value) list ->
  (unit, Fs_compat.atomic_replace_failure) result
