(** Runtime-boundary projection for provider constants that remain owned by
    OAS. Sampling defaults are intentionally absent: an omitted temperature is
    carried as [None] so the selected provider applies its declared default. *)

let max_error_body_length =
  Llm_provider.Constants.Truncation.max_error_body_length
;;
