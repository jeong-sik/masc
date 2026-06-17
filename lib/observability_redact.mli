(** Observability_redact — redact sensitive data for observability fields.

    All tool input/output previews pass through this before storage.
    Sensitive patterns (API keys, URL credentials) are replaced with
    [\[REDACTED\]], and certain tool categories return [None] entirely. *)

(** Tunable parameters for the generic secret matcher.

    The defaults are conservative and based on the small measured sample in
    {!Observability_redact}. Because that sample has only a handful of points,
    callers that need a different false-positive/false-negative trade-off can
    override individual fields. *)
type redact_config =
  { generic_min_len : int
  ; generic_max_token_len : int
  ; generic_entropy_threshold : float
  ; generic_lower_entropy_threshold : float
  ; generic_longer_min_len : int
  ; generic_min_classes_for_low_entropy : int
  ; max_input_len : int
  }

val default_redact_config : redact_config
(** Default multi-signal configuration. *)

val is_denied_tool : tool_name:string -> bool
(** Returns [true] if the tool is on the deny list (auth, encryption, etc.)
    and its I/O must not be logged or previewed. *)

val redact_json_value : Yojson.Safe.t -> Yojson.Safe.t
(** Recursively redact sensitive fields (tokens, secrets, passwords, etc.)
    from a JSON value, preserving structure. *)

val redact_preview : ?max_len:int -> string -> string
(** Truncate to [max_len] (default 200) and strip known sensitive patterns.
    Result is safe for storage in proof/dashboard/metrics.

    Marker-aware: if the input is a [Tool_output] blob marker, decode
    and redact only the user-visible preview body so sha256/bytes/mime
    survive intact for downstream parsers. *)

val redact_text : ?config:redact_config -> string -> string
(** Strip known sensitive patterns. Inputs up to [config.max_input_len]
    characters are fully scanned; longer inputs are redacted only on the
    prefix and the remainder is replaced with [...(truncated)] to bound
    computation. Use this for user-visible chat/transport text where the full
    message length must be preserved for normal-sized payloads. *)

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
(** Produce a redacted preview of tool input JSON.
    Returns [None] for tools on the deny list (auth, encryption, etc.). *)

val redact_tool_output : tool_name:string -> string -> string option
(** Produce a redacted preview of tool output text.
    Returns [None] for tools on the deny list. *)

val redacted_tool_input_json : tool_name:string -> Yojson.Safe.t -> Yojson.Safe.t option
(** Produce a redacted structured copy of tool input JSON.
    Returns [None] for tools on the deny list. *)

val redacted_tool_output_json : tool_name:string -> string -> Yojson.Safe.t option
(** Produce a redacted structured copy of tool output when it is JSON,
    otherwise a redacted string. Returns [None] for tools on the deny list. *)

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
