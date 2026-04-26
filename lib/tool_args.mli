(** Tool_args — tool-convention argument extraction wrappers over
    {!Safe_ops} plus canonical error/OK response helpers.

    All [tool_*.ml] files should [open Tool_args] instead of defining
    local helpers.

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
  | Validation_error (** Missing or invalid input parameters. *)
  | Not_found (** Requested resource does not exist. *)
  | Auth_required (** Authentication needed. *)
  | Permission_denied (** Authenticated but not authorized. *)
  | Conflict (** Resource state conflict (e.g. already claimed). *)
  | Rate_limited (** Too many requests. *)
  | Timeout (** Operation timed out. *)
  | Not_implemented (** Feature exists in schema but not in runtime. *)
  | Internal_error (** Unexpected server-side failure. *)
  | Precondition_failed (** Required precondition not met (e.g. room not joined). *)

val error_code_to_string : error_code -> string

(** {1 Canonical error / OK response helpers}

    New tool handlers should use these instead of local helpers.
    Returns either a JSON string or the [(bool * string)] pair matching
    the standard tool dispatch signature. *)

(** [{"status":"error","message":"…"}] *)
val error_response : string -> string

(** [{"status":"error","error_code":"…","message":"…"}] — preferred. *)
val error_response_typed : code:error_code -> string -> string

(** [{"status":"ok", <fields>}] *)
val ok_response : (string * Yojson.Safe.t) list -> string

val error_result : string -> bool * string
val error_result_typed : code:error_code -> string -> bool * string
val ok_result : (string * Yojson.Safe.t) list -> bool * string

(** {1 Required field extractors (Parse, Don't Validate)}

    Return [Ok value] on success, [Error json_error_string] on missing /
    empty input. Combine with {!val-(let*!)} for early-return chaining. *)

(** Trim whitespace; reject empty. *)
val get_string_required : Yojson.Safe.t -> string -> (string, string) result

val get_int_required : Yojson.Safe.t -> string -> (int, string) result

(** Monadic bind for [(value, error_json) result] → [(bool * string)].
    Chains required field extractions with early error return. *)
val ( let*! ) : ('a, string) result -> ('a -> bool * string) -> bool * string

(** {1 Structured field validation}

    Machine-readable field-path error feedback — callers receive which
    field failed, what was expected, what was received, enabling
    deterministic self-correction.

    @since 2.170.0
    @see <https://github.com/jeong-sik/masc-mcp/issues/4963> *)

type field_constraint =
  | Required (** Field must be present. *)
  | Non_empty (** String must not be empty after trimming. *)
  | Type_string (** Value must be a JSON string. *)
  | Type_int (** Value must be a JSON integer. *)
  | Type_float (** Value must be a JSON number. *)
  | Type_bool (** Value must be a JSON boolean. *)
  | Min_int of int (** Integer must be >= min. *)
  | Max_int of int (** Integer must be <= max. *)
  | One_of of string list (** String must be one of the listed values. *)

val field_constraint_to_string : field_constraint -> string

type field_error =
  { field : string
  ; constraint_violated : field_constraint
  ; message : string
  ; expected : string option
  ; received : string option
  }

val field_error_to_yojson : field_error -> Yojson.Safe.t

(** [{"status":"error","error_code":"validation_error",
    "field_errors":[…],"message":"N field error(s)"}] *)
val validation_error_response : field_error list -> string

val validation_error_result : field_error list -> bool * string

(** {1 Field validators}

    Each returns [Ok value] or [Error field_error]. Use {!validate_all}
    to collect multiple errors before returning. *)

val validate_string_required : Yojson.Safe.t -> string -> (string, field_error) result
val validate_int_required : Yojson.Safe.t -> string -> (int, field_error) result

val validate_int_range
  :  Yojson.Safe.t
  -> string
  -> min_v:int
  -> max_v:int
  -> default:int
  -> (int, field_error) result

val validate_one_of
  :  Yojson.Safe.t
  -> string
  -> allowed:string list
  -> default:string
  -> (string, field_error) result

(** Collect any [Error]s from [results]; returns [Ok ()] when all pass. *)
val validate_all : (unit, field_error) result list -> (unit, field_error list) result
