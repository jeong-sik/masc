(** Tool_args -- Tool-convention argument extraction wrappers over Safe_ops.

    All tool_*.ml files should [open Tool_args] instead of defining local helpers.

    Signature convention: [get_TYPE args key default] (positional, args first).
    This bridges the tool-file convention to Safe_ops labeled API:
    [Safe_ops.json_TYPE ~default key args] (labeled, key first).

    {b Empty-string filtering}: [get_string_opt] treats [""] as [None],
    matching the majority tool convention ([when s <> ""] guard).

    {b Error response format} (canonical):
    Use [error_response] and [ok_response] below for all new tool handlers.

    TODO(M-2): Unify the existing error response formats across tool modules:
    1. [error_response] below — [\{"status":"error","message":...\}]
    2. Plain string returns — some tools return bare error strings
    3. [isError: true] — MCP protocol-level error flag (correct for transport)
    4. [Printf.sprintf] ad-hoc JSON — hand-built JSON strings
    5. [Yojson.Safe.to_string] inline — direct JSON construction without helper
    Preferred format: [\{"status":"error","message":"..."\}] via [error_response].
*)

let get_string args key default = Safe_ops.json_string ~default key args
let get_int args key default = Safe_ops.json_int ~default key args
let get_float args key default = Safe_ops.json_float ~default key args
let get_bool args key default = Safe_ops.json_bool ~default key args

let get_string_opt args key =
  match Safe_ops.json_string_opt key args with
  | Some "" -> None
  | other -> other

let get_int_opt args key = Safe_ops.json_int_opt key args
let get_float_opt args key = Safe_ops.json_float_opt key args
let get_bool_opt args key = Safe_ops.json_bool_opt key args
let get_string_list args key = Safe_ops.json_string_list key args

(** {1 Standard Error Codes}

    Machine-readable error codes for deterministic client-side classification.
    MCP clients can match on [error_code] to decide retry, escalation, or display.

    @since 2.163.0
    @see <docs/design/api-versioning-design.md> I4 Error Consistency *)

type error_code =
  | Validation_error      (** Missing or invalid input parameters *)
  | Not_found             (** Requested resource does not exist *)
  | Auth_required         (** Authentication needed *)
  | Permission_denied     (** Authenticated but not authorized *)
  | Conflict              (** Resource state conflict (e.g. already claimed) *)
  | Rate_limited          (** Too many requests *)
  | Timeout               (** Operation timed out *)
  | Not_implemented       (** Feature exists in schema but not in runtime *)
  | Internal_error        (** Unexpected server-side failure *)
  | Precondition_failed   (** Required precondition not met (e.g. room not joined) *)

let error_code_to_string = function
  | Validation_error -> "validation_error"
  | Not_found -> "not_found"
  | Auth_required -> "auth_required"
  | Permission_denied -> "permission_denied"
  | Conflict -> "conflict"
  | Rate_limited -> "rate_limited"
  | Timeout -> "timeout"
  | Not_implemented -> "not_implemented"
  | Internal_error -> "internal_error"
  | Precondition_failed -> "precondition_failed"

(** {1 Canonical Error/OK Response Helpers}

    New tool handlers should use these instead of defining local helpers.
    Returns [(bool * string)] matching the standard tool dispatch signature. *)

(** Build a JSON error response string: [\{"status":"error","message":"..."\}] *)
let error_response message =
  Yojson.Safe.to_string
    (`Assoc [ ("status", `String "error"); ("message", `String message) ])

(** Build a JSON error response string with machine-readable error code:
    [\{"status":"error","error_code":"validation_error","message":"..."\}]

    Preferred over [error_response] for new tool handlers. *)
let error_response_typed ~code message =
  Yojson.Safe.to_string
    (`Assoc [
      ("status", `String "error");
      ("error_code", `String (error_code_to_string code));
      ("message", `String message);
    ])

(** Build a JSON OK response string with additional fields. *)
let ok_response fields =
  Yojson.Safe.to_string (`Assoc (("status", `String "ok") :: fields))

(** Convenience: [(false, error_response msg)] *)
let error_result msg = (false, error_response msg)

(** Convenience: [(false, error_response_typed ~code msg)] *)
let error_result_typed ~code msg = (false, error_response_typed ~code msg)

(** Convenience: [(true, ok_response fields)] *)
let ok_result fields = (true, ok_response fields)

(** {1 Parse, Don't Validate — Required Field Extractors}

    Use these for required parameters instead of [get_string args key ""].
    Returns [Ok value] on success, [Error json_string] on missing/empty input.
    Combine with [let*!] for early-return chaining. *)

(** Required non-empty string. Trims whitespace. *)
let get_string_required args key =
  match Safe_ops.json_string_opt key args with
  | Some s when String.trim s <> "" -> Ok (String.trim s)
  | Some _ -> Error (error_response (Printf.sprintf "%s must not be empty" key))
  | None -> Error (error_response (Printf.sprintf "%s is required" key))

(** Required integer. *)
let get_int_required args key =
  match Safe_ops.json_int_opt key args with
  | Some i -> Ok i
  | None -> Error (error_response (Printf.sprintf "%s is required" key))

(** Monadic bind for [(ok, string) result] → [(bool * string)].
    Chains required field extractions with early error return. *)
let ( let*! ) r f = match r with Ok v -> f v | Error e -> (false, e)

(** {1 Structured Field Validation}

    Machine-readable field-path error feedback for keeper tool argument
    validation.  Callers receive which field failed, what was expected,
    and what was received, enabling deterministic self-correction.

    @since 2.170.0
    @see <https://github.com/jeong-sik/masc-mcp/issues/4963> *)

(** Validation constraint that a field must satisfy. *)
type field_constraint =
  | Required          (** field must be present *)
  | Non_empty         (** string field must not be empty after trimming *)
  | Type_string       (** value must be a JSON string *)
  | Type_int          (** value must be a JSON integer *)
  | Type_float        (** value must be a JSON number *)
  | Type_bool         (** value must be a JSON boolean *)
  | Min_int of int    (** integer must be >= min *)
  | Max_int of int    (** integer must be <= max *)
  | One_of of string list  (** string must be one of the listed values *)

let field_constraint_to_string = function
  | Required -> "required"
  | Non_empty -> "non_empty"
  | Type_string -> "type_string"
  | Type_int -> "type_int"
  | Type_float -> "type_float"
  | Type_bool -> "type_bool"
  | Min_int v -> Printf.sprintf "min_int(%d)" v
  | Max_int v -> Printf.sprintf "max_int(%d)" v
  | One_of vs -> Printf.sprintf "one_of(%s)" (String.concat "," vs)

(** A single field-level validation error. *)
type field_error = {
  field : string;
  constraint_violated : field_constraint;
  message : string;
  expected : string option;
  received : string option;
}

let field_error_to_yojson (e : field_error) : Yojson.Safe.t =
  `Assoc (
    [ ("field", `String e.field);
      ("constraint", `String (field_constraint_to_string e.constraint_violated));
      ("message", `String e.message) ]
    @ (match e.expected with Some v -> [("expected", `String v)] | None -> [])
    @ (match e.received with Some v -> [("received", `String v)] | None -> [])
  )

(** Build a structured validation error response with per-field errors.
    Produces: [\{"status":"error","error_code":"validation_error",
    "field_errors":[...],"message":"N field error(s)"\}] *)
let validation_error_response (errors : field_error list) : string =
  let field_errors = List.map field_error_to_yojson errors in
  Yojson.Safe.to_string
    (`Assoc [
      ("status", `String "error");
      ("error_code", `String "validation_error");
      ("field_errors", `List field_errors);
      ("message", `String (Printf.sprintf "%d field error(s)" (List.length errors)));
    ])

(** Convenience: [(false, validation_error_response errors)] *)
let validation_error_result errors = (false, validation_error_response errors)

(** {2 Field Validators}

    Each validator returns [Ok value] or [Error field_error].
    Use [validate_all] to collect multiple errors before returning. *)

(** Validate that a string field is present and non-empty. *)
let validate_string_required args field : (string, field_error) result =
  match Safe_ops.json_string_opt field args with
  | Some s when String.trim s <> "" -> Ok (String.trim s)
  | Some s ->
    Error { field; constraint_violated = Non_empty;
            message = Printf.sprintf "%s must not be empty" field;
            expected = Some "non-empty string";
            received = Some (Printf.sprintf "%S" s) }
  | None ->
    Error { field; constraint_violated = Required;
            message = Printf.sprintf "%s is required" field;
            expected = Some "string"; received = None }

(** Validate that an integer field is present. *)
let validate_int_required args field : (int, field_error) result =
  match Safe_ops.json_int_opt field args with
  | Some i -> Ok i
  | None ->
    Error { field; constraint_violated = Required;
            message = Printf.sprintf "%s is required" field;
            expected = Some "integer"; received = None }

(** Validate that an integer field (if present) is within [min, max]. *)
let validate_int_range args field ~min_v ~max_v ~default : (int, field_error) result =
  let v = get_int args field default in
  if v < min_v then
    Error { field; constraint_violated = Min_int min_v;
            message = Printf.sprintf "%s must be >= %d" field min_v;
            expected = Some (Printf.sprintf ">= %d" min_v);
            received = Some (string_of_int v) }
  else if v > max_v then
    Error { field; constraint_violated = Max_int max_v;
            message = Printf.sprintf "%s must be <= %d" field max_v;
            expected = Some (Printf.sprintf "<= %d" max_v);
            received = Some (string_of_int v) }
  else Ok v

(** Validate that a string field (if present) is one of allowed values. *)
let validate_one_of args field ~allowed ~default : (string, field_error) result =
  let v = get_string args field default in
  if List.mem v allowed then Ok v
  else
    Error { field; constraint_violated = One_of allowed;
            message = Printf.sprintf "%s must be one of: %s" field (String.concat ", " allowed);
            expected = Some (String.concat "|" allowed);
            received = Some v }

(** Collect all field errors from a list of validation results.
    Returns [Ok values] if all pass, [Error field_errors] otherwise. *)
let validate_all (results : (unit, field_error) result list) : (unit, field_error list) result =
  let errors = List.filter_map (function Error e -> Some e | Ok () -> None) results in
  if errors = [] then Ok ()
  else Error errors
