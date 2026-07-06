val schema_cache : (string, string) Hashtbl.t
val reset_schema_cache : unit -> unit
val python_argv_for : string -> string list
val fetch_schema : ?base_path:string -> string -> (string, string) result
type toml_value =
    Tstring of string
  | Tint of int
  | Tfloat of float
  | Tbool of bool
val max_value_bytes : int
val escape_toml_string : string -> string
val render_value : toml_value -> string
val render_toml : (string * toml_value) list -> string
type declared_type = [ `Boolean | `Integer | `Number | `String ]
val parse_declared_type : Yojson.Safe.t -> declared_type option
type schema_field_types_error =
  | Schema_fetch_error of string
  | Schema_json_parse_error of { message : string; body_preview : string }
  | Schema_unexpected_error of { message : string; body_preview : string }
val schema_field_types_error_kind : schema_field_types_error -> string
val schema_field_types_error_to_string : schema_field_types_error -> string
val schema_field_types_result :
  ?base_path:string -> string -> ((string * declared_type) list, schema_field_types_error) result
val schema_field_types :
  ?base_path:string -> string -> (string * declared_type) list
val coerce_value : declared_type -> string -> (toml_value, string) result
val config_toml_path : base_path:string -> string -> string
val parse_body_pairs : string -> ((string * string) list, string) result
