(** Canonical validation and durable codec for execution tool schedules. *)

type error =
  | Negative_planned_index
  | Negative_batch_index
  | Non_positive_batch_size
  | Invalid_terminal_schedule

val error_to_string : error -> string
val validate : Tool_contract.schedule -> (unit, error) result

val validate_completion
  :  completion:Tool_contract.completion
  -> Tool_contract.schedule
  -> (unit, error) result

val validate_completion_message
  :  completion:Tool_contract.completion
  -> Tool_contract.schedule
  -> (unit, string) result

val equal : Tool_contract.schedule -> Tool_contract.schedule -> bool
val to_yojson : Tool_contract.schedule -> Yojson.Safe.t
val of_yojson : Yojson.Safe.t -> (Tool_contract.schedule, string) result
