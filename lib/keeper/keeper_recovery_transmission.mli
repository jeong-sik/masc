type error = Source_reader_unavailable

val error_to_string : error -> string

(** Checks the actually offered canonical artifact-reader schema and execution
    descriptor. Does not inject a reader or bypass a Keeper Tool group. *)
val require_reader : Agent_core.Tool.t list -> (unit, error) result
