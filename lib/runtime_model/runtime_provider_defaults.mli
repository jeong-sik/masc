(** Runtime-boundary projection for provider constants.

    OAS owns the truncation limit. Sampling defaults are intentionally not
    projected: callers either declare an exact temperature or omit it so the
    provider applies its own default. *)

val max_error_body_length : int
