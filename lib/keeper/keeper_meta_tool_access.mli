(** Keeper tool-access policy types and JSON helpers.

    Defines the canonical [tool_access] ADT and parsers for persisted
    keeper meta JSON.  Named presets have been removed; keepers declare
    an explicit [Custom] tool list. *)

type tool_access = Custom of Tool_name.Keeper.t list

(** Returns true if any name in the list resolves to a board tool.
    Used to detect implicit board surface. *)
val tool_names_include_board : Tool_name.Keeper.t list -> bool

(** Decide whether a [tool_access] should keep [room_signal_prompt] on:
    Custom → true when the list contains any board tool (or [default] is
    true). *)
val tool_access_default_room_signal_prompt_enabled :
  default:bool -> tool_access -> bool

(** Trim, drop blanks, dedupe (preserve first-seen order). *)
val normalize_tool_names : string list -> string list

(** Convert a raw string list into a typed [tool_access].
    Unknown tool names are silently dropped. *)
val tool_access_of_string_list : string list -> tool_access

(** Sort Custom lists for stable comparison and hash. *)
val normalize_tool_access : tool_access -> tool_access

val tool_access_custom_allowlist : tool_access -> string list

(** Encode a [tool_access] as the canonical
    [{ "kind": "custom", "tools": [...] }] JSON object. *)
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

(** Default [tool_access] for missing/null fields:
    [Keeper_internal] surface with write tools excluded. *)
val default_tool_access_of_meta_json : unit -> tool_access

(** Parse [tool_access] from persisted meta JSON, accepting "custom" kind.
    Legacy "preset" kind falls back to [default_tool_access_of_meta_json]
    with a deprecation warning. *)
val tool_access_of_meta_json :
  Yojson.Safe.t -> (tool_access, string) result
