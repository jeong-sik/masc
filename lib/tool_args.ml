(** Tool_args -- Tool-convention argument extraction wrappers over Safe_ops.

    All tool_*.ml files should [open Tool_args] instead of defining local helpers.

    Signature convention: [get_TYPE args key default] (positional, args first).
    This bridges the tool-file convention to Safe_ops labeled API:
    [Safe_ops.json_TYPE ~default key args] (labeled, key first).

    {b Empty-string filtering}: [get_string_opt] treats [""] as [None],
    matching the majority tool convention ([when s <> ""] guard).
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
