(** Whether a turn on a Runtime may carry MASC's tools.

    An Agent Core Runtime answers from its resolved capability record: the
    AGENT_CORE catalog row when the catalog knows the model, otherwise the
    [models.<id>.capabilities] block laid over the wire
    ({!Runtime_adapter.model_capabilities_override_of_model_spec}). The model
    row's [tools-support] reaches that answer only through the block, for a
    model the catalog has no row for. An official client has no catalog row,
    so its model row's [tools-support] is the answer. *)
val declares_tools : Runtime_instance.t -> bool
