(** Immutable observed input context; not authority to complete a Task or Goal. *)
type t
val keeper : t -> string
val turn_ref : t -> Ids.Turn_ref.t option
val question : t -> string
val to_yojson : t -> Yojson.Safe.t
val of_yojson : Yojson.Safe.t -> (t, string) result
val render : t -> string
type error = Invalid_context of string | Source_unavailable of string
val error_to_string : error -> string
val failure_class : error -> Tool_result.tool_failure_class
val capture : config:Workspace.config -> keeper:string -> turn_ref:Ids.Turn_ref.t option ->
  args:Yojson.Safe.t -> (t, error) result
