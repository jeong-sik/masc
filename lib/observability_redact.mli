(** Observability_redact — redact sensitive data for observability fields.

    All tool input/output previews pass through this before storage.
    Sensitive structures are replaced with [\[REDACTED\]] without hiding
    the existence of any tool call. *)

val redact_json_value : Yojson.Safe.t -> Yojson.Safe.t
(** Recursively redact sensitive fields (tokens, secrets, passwords, etc.)
    from a JSON value, preserving structure. *)

val redact_preview : ?max_len:int -> string -> string
(** Truncate to [max_len] (default 200) and strip known sensitive patterns.
    Result is safe for storage in proof/dashboard/metrics.

    Marker-aware: if the input is a [Tool_output] blob marker, decode
    and redact only the user-visible preview body so sha256/bytes/mime
    survive intact for downstream parsers. *)

val redact_text : string -> string
(** Strip known sensitive patterns without truncating or trimming the
    input. Use this for user-visible chat/transport text where the full
    message length must be preserved. *)

val redact_json_strings : Yojson.Safe.t -> Yojson.Safe.t
(** Recursively apply {!redact_text} to string leaves and replace
    sensitive-key fields with [\[REDACTED\]], preserving structure and
    without truncation. *)

val preview_json_strings : ?max_len:int -> Yojson.Safe.t -> Yojson.Safe.t
(** Recursively apply [redact_preview] to every string leaf, preserving
    JSON structure. Use this instead of [Yojson.Safe.to_string |>
    String.sub] when the JSON may contain a [masc:blob ...] marker in
    a string field — blind byte truncation chops through sha256 and
    strands the marker. *)

val redact_tool_input : tool_name:string -> Yojson.Safe.t -> string option
(** Produce a redacted preview of tool input JSON. *)

val redact_tool_output : tool_name:string -> string -> string option
(** Produce a redacted preview of tool output text. *)

val redacted_tool_input_json : tool_name:string -> Yojson.Safe.t -> Yojson.Safe.t option
(** Produce a redacted structured copy of tool input JSON. *)

val redacted_tool_output_json : tool_name:string -> string -> Yojson.Safe.t option
(** Produce a redacted structured copy of tool output when it is JSON,
    otherwise a redacted string. *)

val build_tool_call_trace_json :
  ?tool_use_id:string ->
  tool_name:string ->
  input:Yojson.Safe.t ->
  output:string option ->
  is_error:bool option ->
  unit ->
  Yojson.Safe.t
(** Build a redacted observability-safe tool trace row. *)

val summarize_tool_call_traces :
  Yojson.Safe.t list -> string option * string option * string option
(** Returns [(tool_input_preview, tool_args_preview, tool_output_preview)]. *)
