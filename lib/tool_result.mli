
(** Structured tool result type for MASC

    Replaces the untyped [(bool * string)] return convention with a
    structured record carrying tool name, timing, and typed payload.

    Backward compatible: existing handlers keep returning [(bool * string)];
    {!wrap} converts at the dispatch boundary.

    @since 2.95.0
*)

(** Structured result from a tool invocation. *)
type t = {
  success : bool;
  data : Yojson.Safe.t;
  tool_name : string;
  duration_ms : float;
}

(** [wrap ~tool_name ~start_time raw] converts a legacy [(bool * string)]
    tuple into a structured result.

    The [data] field is built by parsing the string as JSON; if parsing
    fails, the raw string is stored as a JSON string value.

    @param tool_name The MCP tool name (e.g. ["masc_status"])
    @param start_time Wall-clock time when the handler started
    @param raw The [(success, message)] tuple from the handler *)
val structured_payload_of_message : string -> Yojson.Safe.t option

val wrap : tool_name:string -> start_time:float -> (bool * string) -> t

(** [to_json t] serializes to JSON for logging and observability. *)
val to_json : t -> Yojson.Safe.t

(** [to_legacy_compat t] converts back to [(bool * string)] for callers
    that have not yet migrated to the typed result interface.

    @deprecated Prefer consuming {!t} directly.  This shim exists only
    for the migration period; each call site should be tracked as a
    remaining migration item.  The function is intentionally named
    [to_legacy_compat] (not [to_legacy]) so that
    [rg 'to_legacy_compat'] gives a precise count of un-migrated callers. *)
val to_legacy_compat : t -> bool * string
[@@alert legacy_tuple
  "This function exists for migration only. \
   Migrate the call site to use Tool_result.t directly."]
