(** Otoml-backed semantic parser for keeper configuration. *)

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

val normalize_source : string -> string
(** Normalize CRLF syntax and Otoml's basic-string escape handling. Source
    bytes used for editor revisions are not changed. *)

val normalize_editor_source : string -> (string, string) result
(** As {!normalize_source}, but reject a physical newline inside a single-line
    string so an editor cannot silently remove it. *)

val of_otoml : Otoml.t -> (toml_doc, string) result
(** Flatten an already parsed normalized document without parsing source again.
    A non-table root is refused. *)

val parse_toml : string -> (toml_doc, string) result
(** Parse a TOML 1.0 document with Otoml and flatten standard tables into
    canonical key paths. Quoted key segments remain quoted, so a literal key
    containing a dot cannot collide with a dotted path. *)
