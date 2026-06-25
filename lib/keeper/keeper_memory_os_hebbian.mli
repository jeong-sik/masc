(** Cross-keeper Hebbian synapse view derived from shared Memory OS facts. *)

(** Derive the dashboard-neutral Hebbian graph from current shared facts.

    The returned JSON has [synapses] and [last_consolidation] fields. Read or
    parse failures are logged and represented as an empty graph so callers can
    keep the dashboard endpoint total while preserving observability. *)
val compute : base_path:string -> now:float -> unit -> Yojson.Safe.t
