type t =
  | Toml_discovery_error
  | Materializable_check

let to_label = function
  | Toml_discovery_error -> "toml_discovery_error"
  | Materializable_check -> "materializable_check"
;;
