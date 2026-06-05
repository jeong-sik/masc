(** Keeper tool-access helpers.

    A keeper's [tool_access] is the persisted candidate profile list —
    [keeper_meta.tool_access : string list]. It is only one policy input:
    descriptor/registry availability, denylist filtering, per-turn OAS
    allowlists, and eval gates still constrain execution. There is no wrapper
    type. *)

(** Returns true if any name in the list resolves to a keeper board wrapper or
    legacy public [masc_board_*] surface. Used to detect implicit board
    surface. *)
val tool_names_include_board : string list -> bool

(** Trim, drop blanks, dedupe (preserve first-seen order). *)
val normalize_tool_names : string list -> string list

(** True when a normalized keeper tool candidate profile grants typed Execute
    the write-enabled policy. *)
val tool_access_allows_execute_write : string list -> bool

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

(** Default string tool candidate profile from the full [Keeper_internal] surface.
    Persisted meta JSON still must provide canonical [tool_access] arrays; this
    default is for explicit callers that need the runtime-wide surface. *)
val default_tool_access_of_meta_json : unit -> string list

(** Parse [tool_access] from persisted meta JSON. Canonical form is a JSON
    array of tool names. *)
val tool_access_of_meta_json :
  Yojson.Safe.t -> (string list, string) result
