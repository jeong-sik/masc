(** The capabilities an exact-output slot reads from its model, and which of
    them runtime.toml states for a binding (RFC-0514 §2.2).

    A model the AGENT_CORE catalog has no row for is an exact slot only when
    runtime.toml states every one. A provider preset answers for every model
    of its provider and knows nothing of this one, so its values never stand
    in for them. Keeper turns do not read this: they run on the stated values
    laid over the preset, as before. *)

type t =
  | Context_window
      (** [max-context], on the binding, its provider or its model. *)
  | Reasoning_effort_ladder
      (** [accepted-reasoning-efforts] in the model's capabilities table. The
          parser reads an empty list as unwritten. *)
  | Json_mode
      (** [supports-response-format-json] in the model's capabilities table. *)
  | Native_schema
      (** [supports-structured-output] in the model's capabilities table. *)

val key : t -> string
(** Where runtime.toml states it, relative to the model's [\[models.<id>\]]
    table. *)

val unstated : Runtime_instance.t -> t list
(** The reads runtime.toml does not state for the runtime's model, in the
    order of {!t}; empty when it states every one. A window only the
    capability catalog answers is not stated. *)
