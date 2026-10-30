(** Pure selection from a successful canonical child-result observation.
    The caller owns canonical authority, execution disposition and publication. *)

type error =
  | Result_not_object
  | Result_absent
  | Export_projection_absent
  | Export_unavailable of string
  | Export_value_absent of string

val select :
  exports:Keeper_tool_plan.export list ->
  Yojson.Safe.t -> ((string * Yojson.Safe.t) list, error) result
(** Return values in declared export order, or the first selection error.
    Every declared export requires [available = true] and a present [value];
    JSON null is a present value. An absent export projection is accepted only
    for an empty declaration. The enclosing result must still be an object.
    Extra fields are ignored. This does not validate or acquire authority to
    read, submit or replay the child. *)

val error_to_string : error -> string
