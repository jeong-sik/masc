type t =
  | Stripped_raw
  | Fallback_param
  | Hardcoded_default

let to_label = function
  | Stripped_raw -> "stripped_raw"
  | Fallback_param -> "fallback_param"
  | Hardcoded_default -> "hardcoded_default"
;;
