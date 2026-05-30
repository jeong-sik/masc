(** Cascade_toml_materializer — render the cascade TOML config into
    the JSON form the cascade loader consumes.

    [<config_dir>/cascade.toml] is the sole source of truth. JSON is
    produced on demand in memory by {!render_toml_to_json_string};
    no disk artifact is written. (RFC-0058 §9 Phase 9.3.)

    Internal helpers (the OTOML→Yojson value translators
    [toml_type_name], [errorf], [json_string_list], [table_fields], [string_value],
    [trimmed_nonempty_string], [bool_value], [int_value],
    [float_value], [string_array_value], [string_matrix_value],
    [model_entry_json], [model_array_value], [api_key_env_json],
    [render_toml_to_yojson]) are hidden — callers consume the typed
    source-info / state types and the four entry-point functions
    only. *)

(** {1 Source identity} *)

(** RFC-0058 §9 Phase 9.3: cascade.toml is the sole cascade source.
    The [source_kind] variant is retained as a single arm ([Toml]) so
    external [source_kind_to_string] callers keep working. *)
type source_kind = Toml [@@deriving tla]

type source_info =
  { kind : source_kind
  ; source_path : string
  }

type source_state =
  { info : source_info
  ; source_exists : bool
  ; source_mtime : float option
  }

(** Always returns ["toml"] after RFC-0058 §9 Phase 9.3. *)
val source_kind_to_string : source_kind -> string

(** Return [config_path] as the active TOML source path. Callers must pass
    the resolved [cascade.toml] path; JSON sibling compatibility is gone. *)
val source_info : config_path:string -> source_info

(** {!source_info} plus the existence flag and mtime of the source
    file (used by the dashboard staleness banner). *)
val source_state : config_path:string -> source_state

(** {1 Rendering} *)

(** Parse [content] as TOML and render the result as a pretty-printed
    JSON string (with a trailing newline). [Error msg] when the TOML
    fails to parse or contains a value the strict whitelist rejects. *)
val render_toml_string_to_json_string : string -> (string, string) result

(** {!render_toml_string_to_json_string} applied to the contents of
    [toml_path]; surfaces filesystem errors as [Error msg]. *)
val render_toml_file_to_json_string : string -> (string, string) result

(** {1 Rendering} *)

(** Render the TOML source into a JSON string without writing to disk.
    Returns the {!source_info} and the rendered JSON string.
    [Error] when rendering fails. *)
val render_toml_to_json_string
  :  config_path:string
  -> (source_info * string, string) result
