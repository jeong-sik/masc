(** MASC Configuration Management

    Persists mode settings to .masc/config.json *)

(** Configuration record *)
type t = {
  mode : Mode.mode;
  enabled_categories : Mode.category list;
}

val default : t
(** Default configuration - always Full mode. *)

val config_filename : string
(** Config file name ("config.json"). *)

val config_path : string -> string
(** Get config file path given a room path. *)

val to_json : t -> Yojson.Safe.t
(** Convert config to JSON. *)

val of_json : Yojson.Safe.t -> t
(** Parse config from JSON - always returns Full mode regardless of stored value. *)

val load : string -> t
(** Load config from file. Returns default on failure. *)

val save : string -> t -> unit
(** Save config to file. *)

val audit_log_path : string -> string
(** Path to the audit log for a room. *)

val json_string_option : string option -> Yojson.Safe.t
(** Convert optional string to JSON (Null for None/empty). *)

val mode_change_audit_json :
  actor:string option ->
  source:string option ->
  room_path:string ->
  previous_config:t ->
  config:t ->
  Yojson.Safe.t
(** Generate audit JSON for a mode change event. *)

val append_mode_change_audit :
  actor:string option ->
  source:string option ->
  room_path:string ->
  previous_config:t ->
  config:t ->
  unit
(** Append a mode change audit entry to the audit log. *)

val dedupe_schemas : Types.tool_schema list -> Types.tool_schema list
(** Remove duplicate tool schemas by name, keeping the first occurrence. *)

val raw_all_tool_schemas : Types.tool_schema list
(** All tool schemas before capability filtering. *)

val validate_schemas : Types.tool_schema list -> unit
(** Validate tool schemas at module initialization time.
    Logs warnings for duplicates, empty names/descriptions, non-object input_schema. *)

val all_tool_schemas : Types.tool_schema list
(** All tool schemas after capability filtering and validation. *)

val all_tool_names : unit -> string list
(** List of all tool names. *)

val is_tool_visible : string -> bool
(** Check if a tool is visible. *)

val visible_tool_schemas :
  ?include_hidden:bool ->
  ?include_deprecated:bool ->
  unit -> Types.tool_schema list
(** Get visible tool schemas. *)

val enabled_tool_schemas :
  ?include_hidden:bool ->
  ?include_deprecated:bool ->
  Mode.category list -> Types.tool_schema list
(** Get enabled tool schemas filtered by categories. *)

val switch_mode :
  ?actor:string -> ?source:string -> string -> Mode.mode -> t
(** Switch mode - no-op, always returns Full. *)

val set_categories :
  ?actor:string -> ?source:string -> string -> Mode.category list -> t
(** Set categories - no-op, always returns Full. *)

val enable_category :
  ?actor:string -> ?source:string -> string -> Mode.category -> t
(** Enable a category - no-op, always returns Full. *)

val disable_category :
  ?actor:string -> ?source:string -> string -> Mode.category -> t
(** Disable a category - no-op, always returns Full. *)

val get_config_summary : string -> Yojson.Safe.t
(** Get current config summary as JSON for tool response. *)
