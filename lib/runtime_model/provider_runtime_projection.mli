(** Runtime provider projection for MASC-owned model labels. *)

module Runtime_binding = Agent_sdk.Provider_runtime_binding

type runtime_kind =
  | Local
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

val provider_profile_for_runtime_prefix : string -> provider_profile option

val default_model_candidate_for_runtime_prefix :
  ?getenv:(string -> string option) -> string -> default_model_candidate option

val default_execution_model_strings : string -> string list
val default_execution_model_strings_result : string -> (string list, 'a) result
