(** Keeper tool-access policy types and JSON migration helpers.

    Defines the canonical [tool_preset] and [tool_access] ADTs and
    parsers that translate persisted/legacy keeper meta JSON into them. *)

type tool_preset =
  | Minimal
  | Social
  | Messaging
  | Dispatch
  | Coding
  | Research
  | Delivery
  | Full

type tool_access =
  | Preset of
      { preset : tool_preset
      ; also_allow : string list
      }
  | Custom of string list

(** Returns true if any name in the list resolves to a [Tool_name.is_board]
    tool. Used to detect implicit board surface. *)
val tool_names_include_board : string list -> bool

(** Decide whether a [tool_access] should keep [room_signal_prompt] on:
    Minimal-with-board-also-allow → check [also_allow]; other Preset →
    true; Custom → check tool list. *)
val tool_access_default_room_signal_prompt_enabled :
  default:bool -> tool_access -> bool

(** Trim, drop blanks, dedupe (preserve first-seen order). *)
val normalize_tool_names : string list -> string list

(** Legacy [Keeper_internal] tools, with [masc_*] internals filtered
    out so legacy migrations don't silently re-expand. *)
val legacy_keeper_internal_tool_names : string list

(** Canonical legacy MASC coordination tools that historical keepers
    received before tier removal. *)
val legacy_session_min_tool_names : string list

(** Build a [Custom tool_access] from
    [legacy_keeper_internal_tool_names ++ names], normalised. *)
val migrate_legacy_restricted_tools : string list -> tool_access

val tool_preset_to_string : tool_preset -> string
val all_tool_presets : tool_preset list
val valid_tool_preset_strings : string list
val tool_preset_of_string : string -> tool_preset option

(** Sort [also_allow] / Custom lists for stable comparison and hash. *)
val normalize_tool_access : tool_access -> tool_access

val tool_access_preset : tool_access -> tool_preset option
val tool_access_custom_allowlist : tool_access -> string list option
val tool_access_also_allowlist : tool_access -> string list

(** Encode a [tool_access] as the canonical
    [{ "kind": "preset" | "custom", ... }] JSON object. *)
val tool_access_to_json : tool_access -> Yojson.Safe.t

(** True if [json] has a non-null member at [key] (top level). *)
val json_member_present : string -> Yojson.Safe.t -> bool

(** Parse a [field_name] member from [json] as a list of strings.
    [label] overrides the field name in error messages. *)
val string_list_field_result :
  ?label:string ->
  field_name:string ->
  Yojson.Safe.t ->
  (string list, string) result

(** As [string_list_field_result] but returns [Ok []] when the member
    is missing or null. *)
val string_list_field_opt_result :
  ?label:string ->
  field_name:string ->
  Yojson.Safe.t ->
  (string list, string) result

(** Read [tool_preset] field from a JSON record. Returns the preset or
    a descriptive error. *)
val parse_tool_preset_projection :
  Yojson.Safe.t -> (tool_preset, string) result

(** Default [tool_access] for missing/null fields:
    [migrate_legacy_restricted_tools legacy_session_min_tool_names]. *)
val default_tool_access_of_meta_json : unit -> tool_access

(** Project legacy fields (tool_custom_allowlist / tool_preset +
    tool_also_allow / tool_allowlist) into a [tool_access]. *)
val legacy_tool_access_projection_of_meta_json :
  Yojson.Safe.t -> (tool_access, string) result

(** Parse [tool_access] from persisted meta JSON, accepting legacy
    "restricted" / "unrestricted" / "preset" / "custom" kinds. *)
val legacy_tool_access_of_meta_json :
  Yojson.Safe.t -> (tool_access, string) result

(** Parse [tool_access] from persisted meta JSON, accepting only the
    canonical "preset" / "custom" kinds (legacy kinds rejected). *)
val tool_access_of_meta_json :
  Yojson.Safe.t -> (tool_access, string) result
