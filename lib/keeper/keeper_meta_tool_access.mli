(** Keeper tool-access helpers.

    A keeper's tool access is the list of tool names it may call —
    [keeper_meta.tool_access : string list].  There is no wrapper type;
    the allowlist IS the policy. *)

(** Returns true if any name in the list resolves to a [Tool_name.is_board]
    tool. Used to detect implicit board surface. *)
val tool_names_include_board : string list -> bool

(** Trim, drop blanks, dedupe (preserve first-seen order). *)
val normalize_tool_names : string list -> string list

(** Trim, drop blanks, dedupe a tool allowlist (alias of
    {!normalize_tool_names}, kept for call-site clarity). *)
val normalize_tool_access : string list -> string list

(** Encode a tool allowlist as a JSON array of tool names. *)
val tool_access_to_json : string list -> Yojson.Safe.t

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

(** Default string tool allowlist from the full [Keeper_internal] surface.
    Persisted meta JSON still must provide canonical [tool_access] arrays; this
    default is for explicit callers that need the runtime-wide surface. *)
val default_tool_access_of_meta_json : unit -> string list

(** Parse [tool_access] from persisted meta JSON. Canonical form is a JSON
    array of tool names. *)
val tool_access_of_meta_json :
  Yojson.Safe.t -> (string list, string) result
