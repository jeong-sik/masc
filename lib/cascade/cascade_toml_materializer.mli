(** Cascade_toml_materializer — render the cascade TOML config into
    the JSON form the cascade loader consumes.

    When [<config_dir>/cascade.toml] exists, the [.json] sibling is
    treated as a derived artifact: the TOML is the source of truth
    and the JSON is regenerated whenever the TOML mtime advances. If
    only the JSON exists, it is returned as-is.

    Internal helpers (the OTOML→Yojson value translators
    [toml_path_of_json_path], [toml_type_name], [errorf],
    [json_string_list], [table_fields], [string_value],
    [trimmed_nonempty_string], [bool_value], [int_value],
    [float_value], [string_array_value], [string_matrix_value],
    [model_entry_json], [model_array_value], [api_key_env_json],
    [profile_field_json], [profile_table_json_fields],
    [render_toml_to_yojson]) are hidden — callers consume the typed
    source-info / state types and the four entry-point functions
    only. *)

(** {1 Source identity} *)

type source_kind =
  | Json
      (** Only [<config_dir>/cascade.json] exists; treated as the
          source of truth and editable in place. *)
  | Toml
      (** [<config_dir>/cascade.toml] exists; the JSON sibling is a
          derived artifact and not editable in place. *)

type source_info = {
  kind : source_kind;
  source_path : string;
  json_path : string;
  raw_json_editable : bool;
}

type materialize_result = {
  source : source_info;
  wrote_json : bool;
}

type source_state = {
  info : source_info;
  source_exists : bool;
  source_mtime : float option;
}

val source_kind_to_string : source_kind -> string
(** ["json"] / ["toml"]. *)

val source_info : config_path:string -> source_info
(** Probe the filesystem for [cascade.toml] alongside [config_path]
    and pick the canonical {!type-source_kind} accordingly. *)

val source_state : config_path:string -> source_state
(** {!source_info} plus the existence flag and mtime of the source
    file (used by the dashboard staleness banner). *)

(** {1 Rendering} *)

val render_toml_string_to_json_string : string -> (string, string) result
(** Parse [content] as TOML and render the result as a pretty-printed
    JSON string (with a trailing newline). [Error msg] when the TOML
    fails to parse or contains a value the strict whitelist rejects. *)

val render_toml_file_to_json_string : string -> (string, string) result
(** {!render_toml_string_to_json_string} applied to the contents of
    [toml_path]; surfaces filesystem errors as [Error msg]. *)

(** {1 Validator hook (#10259)} *)

val toml_section_names_result :
  config_path:string -> (string list, string) result
(** Best-effort enumeration of cascade names defined in the TOML
    catalog, used by the keeper-name validator as a degraded
    fallback when {!render_toml_to_yojson} rejects a key.

    Returns [Ok names] on success (meta keys starting with [_] are
    filtered), [Ok []] when the source is JSON-only (the JSON path
    has its own loader), and [Error msg] when the TOML cannot be
    parsed at all. *)

(** {1 Materialisation} *)

val ensure_materialized_json :
  config_path:string -> (materialize_result, string) result
(** Idempotent: when the source is TOML and the rendered JSON
    differs from the on-disk JSON, atomically overwrite the JSON
    sibling and return [{wrote_json = true}]. Otherwise return
    [{wrote_json = false}]. JSON-only sources always return
    [{wrote_json = false}]. *)
