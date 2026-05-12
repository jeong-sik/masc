
(** Tool_args — tool-convention argument extraction wrappers over
    {!Safe_ops} plus canonical error/OK response helpers.

    All [tool_*.ml] files must use the canonical helpers
    {!error_response} / {!ok_response} / {!error_response_typed} — either
    via [open Tool_args] (unqualified calls) or via qualified references
    (e.g. [Tool_args.ok_response]). The latter is the style used by
    {!Tool_local_runtime_core} and is equally canonical. Defining local
    [json_error] / [json_ok] wrappers is forbidden: those drift in
    error_code presence, status spelling, and field ordering.

    {b Signature convention}: [get_TYPE args key default] (positional,
    args first) — bridges tool-file convention to the labeled
    {!Safe_ops} API [Safe_ops.json_TYPE ~default key args].

    {b Empty-string filtering}: {!get_string_opt} treats [""] as [None],
    matching the majority tool convention. *)

(** {1 Permissive extractors}

    Return the [default] (or [None] for [_opt] variants) on missing or
    type-mismatched input; never raise. *)

val get_string : Yojson.Safe.t -> string -> string -> string

val get_int : Yojson.Safe.t -> string -> int -> int

val get_float : Yojson.Safe.t -> string -> float -> float

val get_bool : Yojson.Safe.t -> string -> bool -> bool

(** [None] on missing {b or} empty-string value. *)
val get_string_opt : Yojson.Safe.t -> string -> string option

val get_int_opt : Yojson.Safe.t -> string -> int option

val get_float_opt : Yojson.Safe.t -> string -> float option

val get_bool_opt : Yojson.Safe.t -> string -> bool option

val get_string_list : Yojson.Safe.t -> string -> string list

(** {1 Machine-readable error codes}

    MCP clients match on [error_code] to decide retry / escalation /
    display paths.

    @since 2.163.0 *)

type error_code =
  | Validation_error      (** Missing or invalid input parameters. *)
  | Not_found             (** Requested resource does not exist. *)
  | Auth_required         (** Authentication needed. *)
  | Permission_denied     (** Authenticated but not authorized. *)
  | Conflict              (** Resource state conflict (e.g. already claimed). *)
  | Rate_limited          (** Too many requests. *)
  | Timeout               (** Operation timed out. *)
  | Not_implemented       (** Feature exists in schema but not in runtime. *)
  | Internal_error        (** Unexpected server-side failure. *)
  | Precondition_failed   (** Required precondition not met (e.g. room not joined). *)

val error_code_to_string : error_code -> string

(** {1 Raw JSON String Builders}

    These produce plain JSON strings without [Tool_result.t] wrapping.
    Used by [get_string_required] error paths and other low-level callers. *)

(** [{"status":"error", <fields>}] as a [`Assoc] node.  Counterpart to
    {!ok_response} / {!ok_result} on the success side, but returns the
    *unserialized* [Yojson.Safe.t] for embedding in a larger response
    or returning via [(Yojson.Safe.t, _) result]. *)
val error_assoc : (string * Yojson.Safe.t) list -> Yojson.Safe.t

(** [{"status":"error","message":"…"}] as a serialized JSON string. *)
val error_response : string -> string

(** [{"status":"error", <fields>}] as a serialized JSON string with
    caller-supplied fields.  Use when the payload needs more than just
    [message] (e.g. [error]/[agent_id]/[config_path] context). *)
val error_response_with : (string * Yojson.Safe.t) list -> string

(** [{"status":"error","error_code":"…","message":"…"}] *)
val error_response_typed : code:error_code -> string -> string

(** [{"status":"ok", <fields>}] as a serialized JSON string. *)
val ok_response : (string * Yojson.Safe.t) list -> string

(** [{"status":"ok", <fields>}] as a [`Assoc] node (no serialization).
    Use when embedding the envelope in a larger composed response — HTTP
    body builders, [(Yojson.Safe.t, string) result] pipelines, etc.
    Identical field-order semantics to {!ok_response}: [status] is
    prepended to the [`Assoc] head. *)
val ok_assoc : (string * Yojson.Safe.t) list -> Yojson.Safe.t

(** {1 Tool_result.t Helpers}

    These return structured {!Tool_result.t} directly, eliminating the
    need for [wrap_result] at the dispatch boundary.  Optional
    [~tool_name] and [~start_time] are forwarded to [Tool_result]
    constructors; when absent, [quick_ok]/[quick_error] variants are
    used. *)

val error_result : ?tool_name:string -> ?start_time:float -> string -> Tool_result.t

val error_result_typed :
  ?tool_name:string -> ?start_time:float -> code:error_code -> string -> Tool_result.t

val ok_result :
  ?tool_name:string -> ?start_time:float -> (string * Yojson.Safe.t) list -> Tool_result.t

(** {1 Required field extractors (Parse, Don't Validate)}

    Return [Ok value] on success, [Error json_error_string] on missing /
    empty input. Combine with {!val-(let*!)} for early-return chaining. *)

(** Trim whitespace; reject empty. *)
val get_string_required : Yojson.Safe.t -> string -> (string, string) Result.t

val get_int_required : Yojson.Safe.t -> string -> (int, string) Result.t

(** Monadic bind for [('a, string) Result.t] → [Tool_result.t].
    Chains required field extractions with early error return. *)
val ( let*! ) :
  ('a, string) Result.t -> ('a -> Tool_result.t) -> Tool_result.t

(** {1 Structured field validation}

    Machine-readable field-path error feedback — callers receive which
    field failed, what was expected, what was received, enabling
    deterministic self-correction.

    @since 2.170.0
    @see <https://github.com/jeong-sik/masc-mcp/issues/4963> *)

type field_constraint =
  | Required           (** Field must be present. *)
  | Non_empty          (** String must not be empty after trimming. *)
  | Type_string        (** Value must be a JSON string. *)
  | Type_int           (** Value must be a JSON integer. *)
  | Type_float         (** Value must be a JSON number. *)
  | Type_bool          (** Value must be a JSON boolean. *)
  | Min_int of int     (** Integer must be >= min. *)
  | Max_int of int     (** Integer must be <= max. *)
  | One_of of string list  (** String must be one of the listed values. *)

val field_constraint_to_string : field_constraint -> string

type field_error = {
  field : string;
  constraint_violated : field_constraint;
  message : string;
  expected : string option;
  received : string option;
}

val field_error_to_yojson : field_error -> Yojson.Safe.t

(** [{"status":"error","error_code":"validation_error",
    "field_errors":[…],"message":"N field error(s)"}] *)
val validation_error_response : field_error list -> string

val validation_error_result :
  ?tool_name:string -> ?start_time:float -> field_error list -> Tool_result.t

(** {1 Field validators}

    Each returns [Ok value] or [Error field_error]. Use {!validate_all}
    to collect multiple errors before returning. *)

val validate_string_required :
  Yojson.Safe.t -> string -> (string, field_error) Result.t

val validate_int_required :
  Yojson.Safe.t -> string -> (int, field_error) Result.t

val validate_int_range :
  Yojson.Safe.t ->
  string ->
  min_v:int ->
  max_v:int ->
  default:int ->
  (int, field_error) Result.t

val validate_one_of :
  Yojson.Safe.t ->
  string ->
  allowed:string list ->
  default:string ->
  (string, field_error) Result.t

(** Collect any [Error]s from [results]; returns [Ok ()] when all pass. *)
val validate_all :
  (unit, field_error) Result.t list -> (unit, field_error list) Result.t
