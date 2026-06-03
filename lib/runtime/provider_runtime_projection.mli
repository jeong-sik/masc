(** Runtime provider projection for MASC-owned model labels. *)

module Runtime_binding = Agent_sdk.Provider_runtime_binding

type runtime_kind =
  | Local
  | Cli_agent
  | Direct_api

type default_model_source =
  | Env_var of string
  | Binding_default

type default_model_candidate =
  { model_id : string
  ; source : default_model_source
  }

type provider_profile =
  { id : string
  ; aliases : string list
  ; kind : Runtime_binding.provider_kind
  ; base_url : string
  ; runtime_kind : runtime_kind
  ; runtime_prefix : string
  ; supported_models : string list
  }

val normalize_label : string -> string
val all_profiles : unit -> provider_profile list
val find_profile_by_alias : string -> provider_profile option
val find_profile_by_runtime_prefix : string -> provider_profile option
val runtime_prefix_of_provider_label : string -> string option
val provider_profile_for_runtime_prefix : string -> provider_profile option

val default_model_candidate_for_runtime_prefix :
  ?getenv:(string -> string option) -> string -> default_model_candidate option

val configured_default_model_label_result : unit -> (string, string) result
val local_runtime_provider_id : unit -> string option
val default_local_fallback_label : unit -> string
val preferred_execution_model_labels : unit -> string list
val default_execution_model_strings : string -> string list
val default_execution_model_strings_result : string -> (string list, 'a) result
