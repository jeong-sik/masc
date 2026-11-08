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

(** The four reads as runtime.toml states them. Only {!parse} makes one, so
    a value of this type states every read. *)
type stated = private
  { context_window : int
  ; reasoning_effort_ladder : Llm_provider.Reasoning_effort.t list
        (** Never empty. *)
  ; json_mode : bool
  ; native_schema : bool
  }

val parse : Runtime_instance.t -> (stated, t * t list) result
(** What runtime.toml states for the runtime's model, or every read it leaves
    unstated, in the order of {!t}. The window is the one the runtime
    resolves, from the binding, its provider or its model. A window only the
    capability catalog answers is not stated, and neither is one the
    catalog's window clamped, since the runtime runs on the catalog's. *)

val capabilities_over
  :  base:Llm_provider.Capabilities.capabilities
  -> stated
  -> Llm_provider.Capabilities.capabilities
(** [base] with the window, the effort ladder, JSON mode and native schema
    that [stated] holds; every other capability is [base]'s. *)
