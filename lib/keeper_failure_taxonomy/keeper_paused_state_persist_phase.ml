type t =
  | Lifecycle_pause_persist
  | Directive

let to_label = function
  | Lifecycle_pause_persist -> "lifecycle_pause_persist"
  | Directive -> "directive"
;;
