val inference_model_bucket : provider:string -> model:string -> string

val inference_provider_bucket : provider:string -> model:string -> string

val observe_inference_telemetry :
  provider:string ->
  model:string ->
  prompt_tokens:int option ->
  completion_tokens:int option ->
  prompt_ms:float option ->
  decode_ms:float option ->
  decode_tok_s:float option ->
  unit

val observe_inference_cost :
  provider:string -> model_bucket:string -> float option -> unit
