(** Otoml-backed semantic parser for keeper configuration. *)

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

type toml_doc = (string * toml_value) list

val parse_toml : string -> (toml_doc, string) result
(** Parse a TOML 1.0 document with Otoml and flatten standard tables into
    canonical key paths. Quoted key segments remain quoted, so a literal key
    containing a dot cannot collide with a dotted path. *)
