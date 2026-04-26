(** MCP HTTP Session ID management.

    MCP Spec 2025-03-26: session IDs must be visible ASCII (0x21–0x7E). *)

(** {1 Session action variant}

    Variant SSOT for the [masc_mcp_session] tool action. Adding a constructor
    forces recompilation of [action_to_string] and extends
    [valid_action_strings]; the schema in [tool_schemas_inline_infra.ml] and
    the dispatcher in [tool_inline_dispatch.ml] both consume this type via
    {!action_of_string_opt}. *)

type action =
  | Get
  | Create
  | List
  | Cleanup
  | Remove

val action_to_string : action -> string

(** Case-insensitive, trimmed lookup. Returns [None] for unknown input. *)
val action_of_string_opt : string -> action option

val all_actions : action list

(** [List.map action_to_string all_actions]. Useful for schema enums. *)
val valid_action_strings : string list

(** {1 Session IDs (MCP spec)} *)

(** [is_valid id] checks that [id] is non-empty and contains only visible
    ASCII (0x21–0x7E), per the MCP spec. *)
val is_valid : string -> bool

(** Generate a fresh session ID of the form [mcp_<ts>_<pid>_<rand>] (base62
    parts). The resulting string always satisfies {!is_valid}. *)
val generate : unit -> string

(** [get_or_generate hdr] returns [hdr] unchanged when it is already a valid
    session ID, otherwise generates a fresh one via {!generate}. *)
val get_or_generate : string option -> string

(** {1 Internal building blocks (exposed for tests)}

    These identifiers are implementation details of {!generate}; they are
    exposed only so that [test/test_mcp_session_coverage.ml] can verify the
    encoding table and base-62 helper. Do not depend on them in production
    code. *)

(** The 62-character alphabet used by {!encode_base62}:
    [0-9A-Za-z]. *)
val base62_chars : string

(** [encode_base62 n] returns the base-62 representation of a non-negative
    integer using {!base62_chars} as the alphabet. *)
val encode_base62 : int -> string
