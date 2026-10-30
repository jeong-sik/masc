type t =
  | Unknown
  | Not_dispatched
  | No_visible_output
  | Response_observed
  | Tool_execution_observed

val to_string : t -> string
val of_string : string -> t option
