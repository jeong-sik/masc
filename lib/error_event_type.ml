type t =
  | Parsing
  | Missing_config

let to_label = function
  | Parsing -> "parsing"
  | Missing_config -> "missing_config"
;;
