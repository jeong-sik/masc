type operation =
  | Verify
  | Ollama_probe

type model_exposure =
  | Keeper_callable
  | Operator_diagnostic

type t =
  { required_permission : Masc_domain.permission
  ; read_only : bool
  ; idempotent : bool
  }

val operation_id : operation -> string
val model_exposure : operation -> model_exposure
val execution_policy : operation -> t
