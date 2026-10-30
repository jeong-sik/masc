(** Google ADC access tokens refreshed at HTTP dispatch boundaries. The gcloud
    process owns ADC/service-account refresh; tokens are never persisted here. *)
type runner = string list -> (string, unit) result
val refresh_with : run:runner -> unit ->
  (Llm_provider.Secret.t, Llm_provider.Provider_config.credential_refresh_error) result
val credential_source : unit -> Llm_provider.Provider_config.credential_source
