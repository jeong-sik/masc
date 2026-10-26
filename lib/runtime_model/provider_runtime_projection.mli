(** Explicit execution model labels from operator configuration and catalog defaults. *)
module Runtime_binding = Agent_core.Provider_runtime_binding

val default_execution_model_strings : string -> string list
(** Explicit configured labels followed by concrete catalog-declared defaults.
    No supported-model first choice, derived provider environment key, synthetic
    [auto], local discovery or anonymous local fallback supplies a model.
    Incomplete explicit default configuration returns no labels. *)

val binding_auth_available : Runtime_binding.t -> bool
(** Keyless bindings qualify; keyed bindings qualify when actually available. *)
