type error = Source_reader_unavailable

(** Checks the actually offered canonical artifact-reader schema and execution
    descriptor. Does not inject a reader or bypass a Keeper Tool group. *)
val require_reader : Agent_core.Tool.t list -> (unit, error) result
