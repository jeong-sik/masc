(** The thinking controls a runtime's model row decides for its own requests.

    A keeper turn, the readiness probe and lane sampling build their request
    from the same row through this module, so all three send the same
    [enable_thinking] and [preserve_thinking]. It reads the row alone, not the
    loaded runtime set. *)

type t =
  { thinking_enabled : bool option
  ; preserve_thinking : bool option
  }

val absent : t
(** No thinking control of the row's own. An official-client runtime gets it,
    because its client owns the reasoning control, and so does an id that names
    no loaded runtime. *)

val of_model : Runtime_schema.model_spec -> t
(** [thinking_enabled] is {!Runtime_schema.thinking_request}: [Some false]
    turns thinking off, [Some true] turns it on, [None] leaves the request's own
    value. [preserve_thinking] is the row's [preserve-thinking]. *)

val apply : t -> Llm_provider.Provider_config.t -> Llm_provider.Provider_config.t
(** A declared [thinking_enabled] replaces the config's value and an absent one
    keeps it. [preserve_thinking] is always the seed's, so an undeclared row
    sends none. *)
