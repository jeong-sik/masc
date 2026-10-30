(** MCP HTTP Session ID management.

    MCP Spec 2025-03-26: session IDs must be visible ASCII (0x21–0x7E). *)

(** {1 Session IDs (MCP spec)} *)

val is_valid : string -> bool
(** [is_valid id] checks that [id] is non-empty and contains only visible
    ASCII (0x21–0x7E), per the MCP spec. *)

val generate : unit -> string
(** Generate a fresh session ID of the form [mcp_<ts>_<pid>_<rand>] (base62
    parts). The resulting string always satisfies {!is_valid}. *)

val get_or_generate : string option -> string
(** [get_or_generate hdr] returns [hdr] unchanged when it is already a valid
    session ID, otherwise generates a fresh one via {!generate}. *)

(** {1 Internal building blocks (exposed for tests)}

    These identifiers are implementation details of {!generate}; they are
    exposed only so that [test/test_mcp_session_coverage.ml] can verify the
    encoding table and base-62 helper. Do not depend on them in production
    code. *)

val base62_chars : string
(** The 62-character alphabet used by {!encode_base62}:
    [0-9A-Za-z]. *)

val encode_base62 : int -> string
(** [encode_base62 n] returns the base-62 representation of a non-negative
    integer using {!base62_chars} as the alphabet. *)
