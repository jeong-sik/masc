(** Tool input validation — strict deterministic schema checking.

    Validates tool call arguments against declared [Types.tool_param] schemas
    before execution. Invalid values are reported without modifying the input.

    @since 0.100.0 *)

(** The field was absent, or it was present with the described JSON value.
    Absence is represented structurally rather than by a magic string. *)
type actual =
  | Missing
  | Received of string

(** A single field-level validation error. *)
type field_error =
  { path : string (** JSON path, e.g. ["/workspace"], ["/interval_seconds"] *)
  ; expected : string (** Expected type or constraint, e.g. ["integer"], ["required"] *)
  ; actual : actual
  }

(** Validation outcome: either the exact original input or a list of errors. *)
type validation_result =
  | Valid of Yojson.Safe.t
  | Invalid of field_error list

(** Validate [input] against the authoritative schema's root [required] and
    property [type]/[enum]/[const] constraints when [tool] carries one,
    otherwise against its parameter view. Tool input is always an object,
    including tools with no parameters. Missing required fields and exact JSON
    type mismatches return [Invalid]. Nullable type arrays keep [null] valid
    instead of being collapsed by the lossy parameter projection. A successful
    result contains the same value passed by the caller. *)
val validate : Types.tool_schema -> Yojson.Safe.t -> validation_result

(** Format field errors as a structured, LLM-readable feedback string.
    Designed for a failed [ToolResult] outcome. *)
val format_errors : tool_name:string -> field_error list -> string

(** Samchon-style inline error feedback: shows the LLM's original JSON
    alongside field-level error annotations. More surgical than [format_errors]
    because the LLM sees its own output with precise error markers.

    Suitable for returning a failed [ToolResult] to the model unchanged. *)
val format_errors_inline
  :  tool_name:string
  -> args:Yojson.Safe.t
  -> field_error list
  -> string

(** {1 Low-level helpers} *)

(** Human-readable description of a JSON value for error messages.
    E.g. [null], [integer(42)], [string("hello")].
    @since 0.120.0 *)
val describe_json_value : Yojson.Safe.t -> string

(** Check if a JSON value matches the expected param_type.
    @since 0.120.0 *)
val matches_type : Types.param_type -> Yojson.Safe.t -> bool
