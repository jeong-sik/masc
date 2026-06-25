(** Cross-keeper Hebbian synapse view derived from shared Memory OS facts. *)

(** Derive the dashboard-neutral Hebbian graph from current shared facts.

    The returned JSON always has [synapses] and [last_consolidation] fields.
    Read or parse failures are logged and returned as a degraded graph with an
    [error] object, so callers can keep dashboard endpoints total without
    confusing derivation failure with a genuinely empty graph. *)
val compute : base_path:string -> now:float -> unit -> Yojson.Safe.t
