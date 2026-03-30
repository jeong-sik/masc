(** Observability_redact — redact sensitive data for observability fields.

    All tool input/output previews pass through this before storage.
    Sensitive patterns (API keys, URL credentials) are replaced with
    [\[REDACTED\]], and certain tool categories return [None] entirely. *)

val contains_substring : sub:string -> string -> bool
(** Test helper: check if [sub] occurs in the string. *)

val redact_preview : ?max_len:int -> string -> string
(** Truncate to [max_len] (default 200) and strip known sensitive patterns.
    Result is safe for storage in proof/dashboard/metrics. *)

val redact_tool_input : tool_name:string -> Yojson.Safe.t -> string option
(** Produce a redacted preview of tool input JSON.
    Returns [None] for tools on the deny list (auth, encryption, etc.). *)

val redact_tool_output : tool_name:string -> string -> string option
(** Produce a redacted preview of tool output text.
    Returns [None] for tools on the deny list. *)

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
