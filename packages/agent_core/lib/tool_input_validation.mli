(** Tool input validation — strict deterministic schema checking.

    Validates tool call arguments against declared [Types.tool_param] schemas
    before execution. Invalid values are reported without modifying the input.

    @since 0.100.0 *)

(** The field was absent, or it was present with the described JSON value.
    Absence is represented structurally rather than by a magic string. *)
type actual =
  | Missing
  | Received of string

(** The violated constraint, kept structured until rendering so an enum or
    const violation can name the values the schema accepts. Collapsing this
    to a string at creation time rendered enum violations as
    ["wrong type — expected: string, got: string(...)"], which named nothing
    the caller could correct.
    @since 0.234.0 *)
type expected =
  | Expected_types of string list
      (** JSON Schema [type] names; [[]] renders as ["declared schema"]. *)
  | Expected_enum of
      { types : string list
      ; allowed : Yojson.Safe.t list
      } (** The property declares [enum]; [allowed] are its members. *)
  | Expected_const of Yojson.Safe.t
  | Expected_required (** A required field with no property schema. *)

(** A single field-level validation error. *)
type field_error =
  { path : string (** JSON path, e.g. ["/workspace"], ["/interval_seconds"] *)
  ; expected : expected (** The violated constraint. *)
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

(** Human-readable description of a violated constraint for error messages.
    E.g. ["integer"], ["one of: "compact", "full""], ["exactly 3"].
    @since 0.234.0 *)
val describe_expected : expected -> string

(** Check if a JSON value matches the expected param_type.
    @since 0.120.0 *)
val matches_type : Types.param_type -> Yojson.Safe.t -> bool
