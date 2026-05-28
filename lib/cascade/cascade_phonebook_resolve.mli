(** Phonebook Resolve — public interface.

    Bridge from phonebook typed data to [Llm_provider.Provider_config.t]
    for the existing OAS transport layer. *)

(** Construct a [Provider_config.t] from a phonebook model.
    Returns [None] when the model's provider is missing from the phonebook. *)
val provider_config_of_phonebook :
  ?temperature:float ->
  ?max_tokens:int ->
  Cascade_phonebook_types.cascade_phonebook ->
  Cascade_phonebook_types.cascade_phonebook_model ->
  Llm_provider.Provider_config.t option

(** Generate a "provider:model_id" string from a phonebook model. *)
val model_string_of_phonebook_model :
  Cascade_phonebook_types.cascade_phonebook_model -> string

(** Resolve all models for a task to [Provider_config.t] list.
    Filters out models whose providers lack required API keys. *)
val resolve_provider_configs_for_task :
  ?temperature:float ->
  ?max_tokens:int ->
  Cascade_phonebook_types.cascade_phonebook ->
  Cascade_routing_policy.task_use ->
  Llm_provider.Provider_config.t list

(** Resolve all models for a task to "provider:model_id" string list. *)
val resolve_model_strings_for_task :
  Cascade_phonebook_types.cascade_phonebook ->
  Cascade_routing_policy.task_use ->
  string list
