(** Provider-kind → API-key env-var name. See .mli for the contract. *)

let env_var_for_kind kind =
  Llm_provider.Provider_kind.default_api_key_env kind
