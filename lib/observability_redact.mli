(** Observability_redact — redact sensitive data for observability fields.

    All tool input/output previews pass through this before storage.
    Sensitive patterns (API keys, URL credentials) are replaced with
    [\[REDACTED\]], and certain tool categories return [None] entirely. *)

(** Test helper: check if [sub] occurs in the string. *)
val contains_substring : sub:string -> string -> bool

(** Returns [true] if the tool is on the deny list (auth, encryption, etc.)
    and its I/O must not be logged or previewed. *)
val is_denied_tool : tool_name:string -> bool

(** Recursively redact sensitive fields (tokens, secrets, passwords, etc.)
    from a JSON value, preserving structure. *)
val redact_json_value : Yojson.Safe.t -> Yojson.Safe.t

(** Truncate to [max_len] (default 200) and strip known sensitive patterns.
    Result is safe for storage in proof/dashboard/metrics.

    Sentinel-aware: if the input is a [Tool_output] blob marker, decode
    and redact only the user-visible preview body so sha256/bytes/mime
    survive intact for downstream parsers. *)
val redact_preview : ?max_len:int -> string -> string

(** Recursively apply [redact_preview] to every string leaf, preserving
    JSON structure. Use this instead of [Yojson.Safe.to_string |>
    String.sub] when the JSON may contain a [masc:blob ...] sentinel in
    a string field — blind byte truncation chops through sha256 and
    strands the marker. *)
val preview_json_strings : ?max_len:int -> Yojson.Safe.t -> Yojson.Safe.t

(** Produce a redacted preview of tool input JSON.
    Returns [None] for tools on the deny list (auth, encryption, etc.). *)
val redact_tool_input : tool_name:string -> Yojson.Safe.t -> string option

(** Produce a redacted preview of tool output text.
    Returns [None] for tools on the deny list. *)
val redact_tool_output : tool_name:string -> string -> string option

(** Build a redacted observability-safe tool trace row. *)
val build_tool_call_trace_json
  :  ?tool_use_id:string
  -> tool_name:string
  -> input:Yojson.Safe.t
  -> output:string option
  -> is_error:bool option
  -> unit
  -> Yojson.Safe.t

(** Returns [(tool_input_preview, tool_args_preview, tool_output_preview)]. *)
val summarize_tool_call_traces
  :  Yojson.Safe.t list
  -> string option * string option * string option
