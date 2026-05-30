(** Keeper tool-access helpers.

    A keeper's tool access is the list of tool names it may call —
    [keeper_meta.tool_access : string list].  There is no wrapper type;
    the allowlist IS the policy. *)

(** Returns true if any name in the list resolves to a [Tool_name.is_board]
    tool. Used to detect implicit board surface. *)
val tool_names_include_board : string list -> bool

(** Keep [room_signal_prompt] on when [default] is set or the allowlist
    contains any board tool. *)
val tool_access_default_room_signal_prompt_enabled :
  default:bool -> string list -> bool

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

(** Default tool allowlist for missing/null fields:
    [Keeper_internal] surface with write tools excluded. *)
val default_tool_access_of_meta_json : unit -> string list

(** Parse [tool_access] from persisted meta JSON.  Canonical form is a JSON
    array of tool names; legacy [{ "kind": "custom"/"preset", ... }] objects
    are accepted for backward compat. *)
val tool_access_of_meta_json :
  Yojson.Safe.t -> (string list, string) result

(** {1 Typed boundary helpers}

    These functions operate on [Tool_name.Keeper.t] directly, providing
    compile-time safety.  String conversion happens only at parse/serialize
    boundaries. *)

val tool_access_of_string_list : string list -> Tool_name.Keeper.t list
(** Convert string names to typed tools at the ingress boundary.
    Unknown names are silently dropped. *)

val tool_access_to_string_list : Tool_name.Keeper.t list -> string list
(** Serialize typed tools to strings for egress boundaries. *)

val tool_names_include_board_typed : Tool_name.Keeper.t list -> bool
(** Typed variant: true if any tool in the list is a board tool. *)

val tool_access_default_room_signal_prompt_enabled_typed :
  default:bool -> Tool_name.Keeper.t list -> bool
(** Typed variant of [tool_access_default_room_signal_prompt_enabled]. *)

val normalize_tool_access_typed : Tool_name.Keeper.t list -> Tool_name.Keeper.t list
(** Deduplicate a typed tool list preserving first-seen order. *)

val tool_access_to_json_typed : Tool_name.Keeper.t list -> Yojson.Safe.t
(** Encode a typed tool allowlist as JSON. *)

val default_tool_access_of_meta_json_typed : unit -> Tool_name.Keeper.t list
(** Default typed tool allowlist from [Keeper_internal] surface. *)

val tool_access_of_meta_json_typed :
  Yojson.Safe.t -> (Tool_name.Keeper.t list, string) result
(** Parse [tool_access] from JSON into typed tools. *)
