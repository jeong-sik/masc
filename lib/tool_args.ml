(** Tool_args -- Tool-convention argument extraction wrappers over Safe_ops.

    All tool_*.ml files should [open Tool_args] instead of defining local helpers.

    Signature convention: [get_TYPE args key default] (positional, args first).
    This bridges the tool-file convention to Safe_ops labeled API:
    [Safe_ops.json_TYPE ~default key args] (labeled, key first).

    {b Empty-string filtering}: [get_string_opt] treats [""] as [None],
    matching the majority tool convention ([when s <> ""] guard).

    {b Error response format} (canonical):
    Use [error_response] and [ok_response] below for all new tool handlers.

    TODO(M-2): Unify the 6 existing error response formats across tool modules:
    1. [error_response] below — [\{"status":"error","message":...\}]
    2. [Tool_command_plane_support.json_error] — [\{"status":"error","message":...\}]
    3. Plain string returns — some tools return bare error strings
    4. [isError: true] — MCP protocol-level error flag (correct for transport)
    5. [Printf.sprintf] ad-hoc JSON — hand-built JSON strings
    6. [Yojson.Safe.to_string] inline — direct JSON construction without helper
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
