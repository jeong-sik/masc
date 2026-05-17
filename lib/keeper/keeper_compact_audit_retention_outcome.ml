type t =
  | Parsed_ok of int
  | Unset_default of int
  | Parse_error of { raw : string; default_used : int }
  | Out_of_range of { raw : string; parsed : int; default_used : int }

let to_label = function
  | Parsed_ok _ -> "parsed_ok"
  | Unset_default _ -> "unset_default"
  | Parse_error _ -> "parse_error"
  | Out_of_range _ -> "out_of_range"
;;
