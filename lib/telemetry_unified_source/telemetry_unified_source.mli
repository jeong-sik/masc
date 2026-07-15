(** Telemetry unified source variant + total string bijection. *)

type source =
  | Keeper_metric
  | Agent_event
  | Tool_call_io
  | Trajectory_tool_call
  | Tool_usage
  | Oas_event
  | Execution_receipt
  | Tool_metric

val source_to_string : source -> string
val source_of_string : string -> source option
val all_sources : source list
