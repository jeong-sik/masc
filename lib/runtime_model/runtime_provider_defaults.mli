(** Runtime-boundary projection for provider inference defaults.

    OAS owns the concrete default inference profiles and truncation limits.
    MASC callers use this module so keeper/server/worker code does not read
    {!Llm_provider.Constants} directly. *)

val agent_default_temperature : float

val worker_default_temperature : float

val deterministic_temperature : float

val max_error_body_length : int
