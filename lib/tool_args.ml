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
    1. [Tool_goals.error_result_json] — [\{"status":"error","message":...\}]
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

(** {1 Canonical Error/OK Response Helpers}

    New tool handlers should use these instead of defining local helpers.
    Returns [(bool * string)] matching the standard tool dispatch signature. *)

(** Build a JSON error response string: [\{"status":"error","message":"..."\}] *)
let error_response message =
  Yojson.Safe.to_string
    (`Assoc [ ("status", `String "error"); ("message", `String message) ])

(** Build a JSON OK response string with additional fields. *)
let ok_response fields =
  Yojson.Safe.to_string (`Assoc (("status", `String "ok") :: fields))

(** Convenience: [(false, error_response msg)] *)
let error_result msg = (false, error_response msg)

(** Convenience: [(true, ok_response fields)] *)
let ok_result fields = (true, ok_response fields)
