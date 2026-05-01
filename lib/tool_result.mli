open Base

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

(** [to_legacy t] converts back to [(bool * string)] for callers that
    still expect the old interface. *)
val to_legacy : t -> bool * string
