type operation =
  | Verify
  | Ollama_probe

type t =
  { required_permission : Masc_domain.permission
  ; read_only : bool
  ; idempotent : bool
  }

val operation_id : operation -> string
val execution_policy : operation -> t
