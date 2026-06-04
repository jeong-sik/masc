(** Minimal TOML parser for keeper configuration files. *)

type toml_value =
  | Toml_string of string
  | Toml_int of int
  | Toml_float of float
  | Toml_bool of bool
  | Toml_string_array of string list

type toml_doc = (string * toml_value) list

val parse_toml : string -> (toml_doc, string) result
