include module type of struct include Keeper_types_profile_toml_parser end

type keeper_toml_error_kind =
  | Read_error
  | Parse_error
  | Profile_error
  | Invalid_name
  | Declaration_not_found of string
      (** The keeper name that has no [keepers/<name>.toml]. *)
  | Unknown_deny_tool of string list
      (** [keeper.tools.deny] entries no descriptor offers the model. *)

type keeper_toml_load_error =
  { keeper_path : string
  ; failing_path : string
  ; kind : keeper_toml_error_kind
  ; detail : string
  }

val keeper_toml_error_kind_to_string : keeper_toml_error_kind -> string

val unknown_deny_tools : string list -> string list
(** The subset of a [keeper.tools.deny] list that names no model-visible
    descriptor. Loading refuses a profile for which this is non-empty; a
    later reader may assert on it, never warn. *)
val keeper_toml_load_error_to_string : keeper_toml_load_error -> string
val read_keeper_toml_content : string -> (string, keeper_toml_load_error) result
(** Capture the declaration bytes once, without parsing. *)
val inspect_keeper_toml :
  string -> (string * keeper_profile_defaults, keeper_toml_load_error) result
val inspect_keeper_toml_content :
  path:string ->
  string ->
  (string * keeper_profile_defaults, keeper_toml_load_error) result
(** Inspect only the supplied bytes, without reopening [path]. Successful
    parses share the existing per-file cache only when both path and complete
    content match. Parse/validation errors are not cached. *)
val load_keeper_toml :
  string -> (string * keeper_profile_defaults, keeper_toml_load_error) result

type keeper_toml_discovery =
  | Loaded of
      { keeper_name : string
      ; defaults : keeper_profile_defaults
      }
  | Invalid of
      { keeper_name : string
      ; error : keeper_toml_load_error
      }

val keeper_toml_discovery_name : keeper_toml_discovery -> string

(** The [*.toml] paths directly under a keepers directory, sorted by file
    name. A missing directory, or a path that is not a directory, lists
    nothing and warns once per process. *)
val keeper_toml_paths : string -> string list

(** Parse one listed declaration. A file that fails to read, parse, or
    validate is [Invalid] under its file stem. *)
val discover_keeper_toml_path : string -> keeper_toml_discovery
val discover_keeper_toml_read :
  path:string -> (string, keeper_toml_load_error) result -> keeper_toml_discovery
(** Discover from already captured bytes or their read error. Does not reopen
    the path; errors keep the same discovery naming and logging policy. *)

val discover_keepers_toml_with_paths : string -> (string * keeper_toml_discovery) list
val discover_keepers_toml : string -> keeper_toml_discovery list
