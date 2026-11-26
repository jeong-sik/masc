(** MCP HTTP Session ID management.

    MCP Spec 2025-03-26: session IDs must be visible ASCII (0x21–0x7E). *)

(** {1 Session IDs (MCP spec)} *)

val is_valid : string -> bool
(** [is_valid id] checks that [id] is non-empty, at most 128 bytes, and
    contains only URL-, header-, and cookie-safe ASCII characters
    ([A-Za-z0-9._:-]), a strict subset of MCP visible ASCII (0x21–0x7E). *)

val generate : unit -> string
(** Generate a fresh cryptographically random session ID of the form
    [mcp_<32-hex>]. The resulting string always satisfies {!is_valid}. *)

val get_or_generate : string option -> string
(** [get_or_generate hdr] returns [hdr] unchanged when it is already a valid
    session ID, otherwise generates a fresh one via {!generate}. *)
